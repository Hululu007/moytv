package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const shieldUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

var shieldBinaryExts = []string{".ts", ".m3u8", ".mp4", ".m4s", ".key", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".zip", ".so", ".bin", ".ico", ".mpd", ".aac", ".flv"}

func shieldIsBinaryURL(rawurl string) bool {
	lower := strings.ToLower(rawurl)
	if q := strings.Index(lower, "?"); q >= 0 {
		lower = lower[:q]
	}
	for _, ext := range shieldBinaryExts {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}

func isShieldChallengeResponse(response *http.Response, body []byte) bool {
	if response != nil && strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge") {
		return true
	}
	if response != nil && response.StatusCode != http.StatusUnauthorized && response.StatusCode != http.StatusForbidden && response.StatusCode != http.StatusServiceUnavailable {
		return false
	}
	return isShieldChallengeText(string(body))
}

func isShieldChallengeText(text string) bool {
	if len(text) > 64*1024 {
		text = text[:64*1024]
	}
	page := strings.ToLower(text)
	if !strings.Contains(page, "cloudflare") && !strings.Contains(page, "_cf_chl") {
		return false
	}
	return strings.Contains(page, "_cf_chl_opt") ||
		strings.Contains(page, "just a moment") ||
		strings.Contains(page, "sorry, you have been blocked") ||
		strings.Contains(page, "you are unable to access") ||
		strings.Contains(page, "checking your browser") ||
		strings.Contains(page, "attention required")
}

var shieldJinaNegMu sync.Mutex
var shieldJinaNegCache = map[string]time.Time{}

func shieldJinaNegativelyCached(host string) bool {
	shieldJinaNegMu.Lock()
	defer shieldJinaNegMu.Unlock()
	t, ok := shieldJinaNegCache[host]
	return ok && time.Since(t) < 60*time.Second
}

func shieldJinaMarkFailed(host string) {
	shieldJinaNegMu.Lock()
	shieldJinaNegCache[host] = time.Now()
	shieldJinaNegMu.Unlock()
}

func (d *Downloader) jinaFetchText(ctx context.Context, rawurl string) (string, error) {
	if strings.Contains(rawurl, "r.jina.ai") {
		return "", errors.New("目标已是 jina 代抓地址")
	}
	if shieldIsBinaryURL(rawurl) {
		return "", errors.New("媒体或二进制地址不走 jina 代抓")
	}
	parsed, err := url.Parse(rawurl)
	if err != nil || parsed.Host == "" {
		return "", errors.New("jina 代抓目标地址无效")
	}
	host := strings.ToLower(parsed.Host)
	if shieldJinaNegativelyCached(host) {
		return "", errors.New("jina 代抓近期失败，负缓存中")
	}
	timed, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(timed, http.MethodGet, "https://r.jina.ai/"+rawurl, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", shieldUserAgent)
	req.Header.Set("x-respond-with", "html")
	resp, err := d.client.Do(req)
	if err != nil {
		shieldJinaMarkFailed(host)
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
	if err != nil {
		shieldJinaMarkFailed(host)
		return "", err
	}
	if resp.StatusCode != http.StatusOK || len(body) == 0 || len(body) > providerMaxBodyBytes || isShieldChallengeText(string(body)) {
		shieldJinaMarkFailed(host)
		return "", fmt.Errorf("jina 代抓未取得有效正文：HTTP %d", resp.StatusCode)
	}
	return string(body), nil
}

func shieldFallbackEligible(rawurl string, err error) bool {
	if err == nil || shieldIsBinaryURL(rawurl) {
		return false
	}
	if isCFChallengeError(err) {
		return true
	}
	return !strings.Contains(err.Error(), " HTTP ")
}

func (d *Downloader) shieldTLSFetchText(ctx context.Context, rawurl, referer string) (string, error) {
	if d.browserTransport == nil {
		return "", errors.New("浏览器指纹传输未就绪")
	}
	if shieldIsBinaryURL(rawurl) {
		return "", errors.New("媒体或二进制地址不走指纹传输")
	}
	timed, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(timed, http.MethodGet, rawurl, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", shieldUserAgent)
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	resp, err := d.browserTransport.browserRoundTrip(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || len(body) > providerMaxBodyBytes || isShieldChallengeResponse(resp, body) {
		return "", fmt.Errorf("指纹传输未取得有效正文：HTTP %d", resp.StatusCode)
	}
	return string(body), nil
}

func (d *Downloader) shieldFallbackText(ctx context.Context, rawurl, referer string, cause error) (string, error) {
	if !shieldFallbackEligible(rawurl, cause) {
		return "", cause
	}
	if isCFChallengeError(cause) {
		if text, err := d.shieldTLSFetchText(ctx, rawurl, referer); err == nil {
			return text, nil
		}
	}
	if text, err := d.jinaFetchText(ctx, rawurl); err == nil {
		return text, nil
	}
	return "", cause
}
