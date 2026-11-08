package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

const hongguoWebSessionTTL = 25 * time.Minute
const hongguoWebMediaCacheTTL = 50 * time.Minute
const hongguoWebMediaCacheMax = 300
const hongguoWebPublicMinBytes = 65536

var hongguoWebFallbackDefinitions = []string{"720p", "480p", "360p", "720p"}
var hongguoWebPublicDefinitions = []string{"720p", "480p", "360p"}

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
	for attempt, definition := range hongguoWebFallbackDefinitions {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		session, err := downloader.hongguoWebSession(ctx, attempt > 0)
		if err != nil {
			lastErr = err
			break
		}
		mediaURL, err := downloader.hongguoWebFallbackPost(ctx, seriesID, videoID, definition, session)
		if err == nil && mediaURL != "" {
			downloader.hongguoWebCacheMedia(key, mediaURL)
			return providerMedia{URL: mediaURL, Referer: hongguoBaseURL + "/"}, nil
		}
		if err != nil {
			lastErr = err
			if errors.Is(err, errHongguoWebFallbackUnavailable) {
				sawUnavailable = true
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

func (downloader *Downloader) hongguoWebFallbackPost(ctx context.Context, seriesID, videoID, definition, session string) (string, error) {
	payload, err := json.Marshal(map[string]string{"series_id": seriesID, "item_id": videoID, "definition": definition})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoBaseURL+"/api/video/protected/fallback-play-info", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", hongguoBaseURL+"/")
	request.Header.Set("Origin", hongguoBaseURL)
	request.Header.Set("Content-Type", "application/json")
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
		if response.StatusCode == http.StatusForbidden {
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
