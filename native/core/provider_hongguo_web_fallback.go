package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const hongguoWebSessionTTL = 25 * time.Minute
const hongguoWebMediaCacheTTL = 50 * time.Minute
const hongguoWebMediaCacheMax = 300
const hongguoWebPublicMinBytes = 65536

// hongguoWebFallbackWaitBudget：一次兜底里等待限流倒计时的总预算；
// 倒计时超出预算即如实报未开放，不再无限等。var 供测试收紧预算。
var hongguoWebFallbackWaitBudget = 120 * time.Second

var hongguoWebPublicDefinitions = []string{"720p", "480p", "360p"}

// 备用接口重试次数：每次失败换一个游客会话（ttwid）再试，与
// 修仙版 playSource 同款（播放页取不到地址后走 fallback-play-info）。
const hongguoWebFallbackAttempts = 4

var errHongguoWebSessionUnavailable = errors.New("红果网页游客会话不可用")
var errHongguoWebFallbackUnavailable = errors.New("红果网页兜底未对该集开放")

type hongguoWebSession struct {
	cookie    string
	fetchedAt time.Time
}

type hongguoWebCachedMedia struct {
	url       string
	expiresAt time.Time
}

type hongguoWebFallbackState struct {
	mu      sync.Mutex
	session hongguoWebSession
	media   map[string]hongguoWebCachedMedia
}

func (downloader *Downloader) hongguoWebFallbackState() *hongguoWebFallbackState {
	return &downloader.hongguoClient().webFallback
}

func (downloader *Downloader) resolveHongguoWebFallback(ctx context.Context, seriesID, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(seriesID) || !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果网页兜底缺少有效的剧集 ID")
	}
	key := seriesID + "|" + videoID
	state := downloader.hongguoWebFallbackState()
	state.mu.Lock()
	cached, ok := state.media[key]
	state.mu.Unlock()
	if ok && time.Now().Before(cached.expiresAt) {
		return providerMedia{URL: cached.url, Referer: hongguoBaseURL + "/"}, nil
	}
	var lastErr error
	sawUnavailable := false
	// 尝试次数按“发出的兜底 POST”计；限流等待不占尝试次数、只耗等待预算，
	// 等完倒计时换新游客会话再试。预算耗尽即停，不再烧请求。
	waitBudget := hongguoWebFallbackWaitBudget
	posts := 0
	for posts < hongguoWebFallbackAttempts {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		session, err := downloader.hongguoWebSession(ctx, posts > 0)
		if err != nil {
			if hongguoWebWaitForBackoff(ctx, err, &waitBudget) {
				downloader.hongguoWebDiscardSession()
				continue
			}
			lastErr = err
			break
		}
		mediaURL, err := downloader.hongguoWebFallbackPost(ctx, videoID, session)
		posts++
		if err == nil && mediaURL != "" {
			downloader.hongguoWebCacheMedia(key, mediaURL)
			return providerMedia{URL: mediaURL, Referer: hongguoBaseURL + "/"}, nil
		}
		if err != nil {
			lastErr = err
			if errors.Is(err, errHongguoWebFallbackUnavailable) {
				sawUnavailable = true
			}
			if hongguoWebWaitForBackoff(ctx, err, &waitBudget) {
				downloader.hongguoWebDiscardSession()
				continue
			}
			// 退避错但预算不足：等不起就停，不再烧掉剩余尝试。
			var backoff *requestBackoff
			if errors.As(err, &backoff) {
				break
			}
		}
		downloader.hongguoWebDiscardSession()
	}
	for _, definition := range hongguoWebPublicDefinitions {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		publicURL := hongguoBaseURL + "/video/public/" + videoID + "/" + definition + ".mp4"
		available, err := downloader.hongguoWebPublicAvailable(ctx, publicURL)
		if err == nil && available {
			downloader.hongguoWebCacheMedia(key, publicURL)
			return providerMedia{URL: publicURL, Referer: hongguoBaseURL + "/"}, nil
		}
		if err != nil {
			lastErr = err
		}
	}
	if sawUnavailable {
		return providerMedia{}, fmt.Errorf("%w：游客会话额度用尽或该集未对未登录访客开放：%v", errHongguoWebFallbackUnavailable, publicError(lastErr))
	}
	if lastErr != nil {
		return providerMedia{}, fmt.Errorf("红果网页兜底未返回该集播放地址：%w", lastErr)
	}
	return providerMedia{}, errors.New("红果网页兜底未返回该集播放地址")
}

// hongguoHostBackoff：取限流器里该域名的现行退避（403/429 响应后由
// observe 按 Retry-After 或默认 60 秒记下），供兜底链按倒计时等待。
// 无现行退避返回 nil。返回的是副本，调用方可安全持有。
func (downloader *Downloader) hongguoHostBackoff(host string) *requestBackoff {
	limiter := downloader.limiter
	if limiter == nil {
		return nil
	}
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	backoff := limiter.backoffs[strings.ToLower(host)]
	if backoff == nil || !time.Now().Before(backoff.until) {
		return nil
	}
	copied := *backoff
	return &copied
}

// hongguoWebWaitForBackoff：err 是限流退避错时等待到退避结束（受总预算
// 约束），返回是否已等待、可换新会话重试。非退避错、预算不足、ctx 取消
// 时返回 false。已过期的退避直接返回 true，不扣预算。
func hongguoWebWaitForBackoff(ctx context.Context, err error, budget *time.Duration) bool {
	var backoff *requestBackoff
	if !errors.As(err, &backoff) || backoff == nil {
		return false
	}
	wait := time.Until(backoff.until)
	if wait <= 0 {
		return true
	}
	if budget == nil || wait > *budget {
		return false
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		*budget -= wait
		return true
	case <-ctx.Done():
		return false
	}
}

func (downloader *Downloader) hongguoWebSession(ctx context.Context, forceRefresh bool) (string, error) {
	state := downloader.hongguoWebFallbackState()
	if !forceRefresh {
		state.mu.Lock()
		session := state.session
		state.mu.Unlock()
		if session.cookie != "" && time.Since(session.fetchedAt) < hongguoWebSessionTTL {
			return session.cookie, nil
		}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, hongguoBaseURL+"/", nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept", "text/html,application/xhtml+xml,application/json,*/*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", hongguoBaseURL+"/")
	response, err := downloader.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if _, err := io.Copy(io.Discard, io.LimitReader(response.Body, providerMaxBodyBytes+1)); err != nil {
		return "", err
	}
	if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
		// 首页也被限流：把限流器记下的退避错交回调用方按倒计时等待，
		// 而不是当成“无会话”直接放弃。
		if backoff := downloader.hongguoHostBackoff(request.URL.Hostname()); backoff != nil {
			return "", backoff
		}
		return "", errHongguoWebSessionUnavailable
	}
	cookie := ""
	for _, item := range response.Cookies() {
		if item.Name == "ttwid" && item.Value != "" {
			cookie = "ttwid=" + item.Value
			break
		}
	}
	if cookie == "" {
		return "", errHongguoWebSessionUnavailable
	}
	state.mu.Lock()
	state.session = hongguoWebSession{cookie: cookie, fetchedAt: time.Now()}
	state.mu.Unlock()
	return cookie, nil
}

// hongguoWebFallbackPost：备用播放接口（修仙版 playSource 同款修法）。
// 播放页 video_player_info 为空时调 POST
// /api/video/protected/fallback-play-info?aid=8662 取 main_url 作主
// 地址；体只带 item_id、Referer 指播放页、桌面 Chrome UA——与树内
// 镜像站 fetchHGTVMirrorFallbackURL 同一配方。备用接口失败才退 360p。
func (downloader *Downloader) hongguoWebFallbackPost(ctx context.Context, videoID, session string) (string, error) {
	payload, err := json.Marshal(map[string]string{"item_id": videoID})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoBaseURL+"/api/video/protected/fallback-play-info?aid=8662", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", hongguoWebUserAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", hongguoBaseURL+"/player")
	request.Header.Set("Origin", hongguoBaseURL)
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	if session != "" {
		request.Header.Set("Cookie", session)
	}
	response, err := downloader.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return "", err
	}
	if response.StatusCode != http.StatusOK {
		if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
			// 403/429 是限流不是“该集未开放”：把退避错与未开放哨兵双包，
			// 调用方既能按倒计时等待、换新会话重试，预算耗尽时也能如实报未开放。
			if backoff := downloader.hongguoHostBackoff(request.URL.Hostname()); backoff != nil {
				return "", fmt.Errorf("%w：%w", errHongguoWebFallbackUnavailable, backoff)
			}
			return "", errHongguoWebFallbackUnavailable
		}
		return "", fmt.Errorf("红果网页兜底 HTTP %d", response.StatusCode)
	}
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return "", errors.New("红果网页兜底返回格式异常")
	}
	if mapString(result, "error") == "public_fallback_unavailable" {
		return "", errHongguoWebFallbackUnavailable
	}
	if address := mapString(result, "main_url"); address != "" && isProviderHTTPMediaURL(address) {
		return address, nil
	}
	if nested := nestedMap(result, "data"); len(nested) > 0 {
		if address := mapString(nested, "main_url"); address != "" && isProviderHTTPMediaURL(address) {
			return address, nil
		}
	}
	return "", errHongguoWebFallbackUnavailable
}

func (downloader *Downloader) hongguoWebPublicAvailable(ctx context.Context, rawURL string) (bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return false, err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", hongguoBaseURL+"/")
	response, err := downloader.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false, nil
	}
	return response.ContentLength > hongguoWebPublicMinBytes, nil
}

func (downloader *Downloader) hongguoWebCacheMedia(key, mediaURL string) {
	state := downloader.hongguoWebFallbackState()
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.media == nil {
		state.media = map[string]hongguoWebCachedMedia{}
	}
	if len(state.media) >= hongguoWebMediaCacheMax {
		state.media = map[string]hongguoWebCachedMedia{}
	}
	state.media[key] = hongguoWebCachedMedia{url: mediaURL, expiresAt: time.Now().Add(hongguoWebMediaCacheTTL)}
}

func (downloader *Downloader) hongguoWebDiscardSession() {
	state := downloader.hongguoWebFallbackState()
	state.mu.Lock()
	state.session = hongguoWebSession{}
	state.mu.Unlock()
}
