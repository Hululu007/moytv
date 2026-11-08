package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const parseAPIRequestTimeout = 15 * time.Second

const parseAPIResponseLimit = 4 << 20

func applyParseTemplate(template, rawURL string) string {
	if strings.Contains(template, "{url}") {
		return strings.ReplaceAll(template, "{url}", parseURLEncode(rawURL))
	}
	if strings.Contains(template, "$url") {
		return strings.ReplaceAll(template, "$url", parseURLEncode(rawURL))
	}
	if strings.Contains(template, "%s") {
		return strings.ReplaceAll(template, "%s", parseURLEncode(rawURL))
	}
	return template + rawURL
}

var parseMediaURLPattern = regexp.MustCompile(`https?://[^\s"'<>\\]+?\.(?:m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(?:\?[^\s"'<>\\]*)?`)

func parseMediaURLFromText(text string) string {
	for _, found := range parseMediaURLPattern.FindAllString(text, -1) {
		if isProviderHTTPMediaURL(found) {
			return found
		}
	}
	return ""
}

func parseBase64MediaURL(text string) string {
	trimmed := strings.TrimSpace(text)
	if len(trimmed) < 20 || len(trimmed)%4 != 0 {
		return ""
	}
	decoded, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(trimmed)
		if err != nil {
			return ""
		}
	}
	if found := parseMediaURLFromText(string(decoded)); found != "" {
		return found
	}
	if isProviderHTTPMediaURL(strings.TrimSpace(string(decoded))) {
		return strings.TrimSpace(string(decoded))
	}
	return ""
}

var parseURLKeys = []string{
	"url", "playUrl", "play_url", "playurl", "video_url", "videoUrl",
	"stream_url", "streamUrl", "media_url", "mediaUrl", "file", "source",
	"m3u8", "hls", "dash", "mpd", "address", "link", "real_url", "realUrl",
}

func parseCandidateURL(value any) string {
	switch v := value.(type) {
	case string:
		trimmed := strings.TrimSpace(v)
		if isProviderHTTPMediaURL(trimmed) {
			return trimmed
		}
		if found := parseMediaURLFromText(trimmed); found != "" {
			return found
		}
		return parseBase64MediaURL(trimmed)
	case []any:
		for _, item := range v {
			if found := parseCandidateURL(item); found != "" {
				return found
			}
		}
	}
	return ""
}

func parseURLFromJSONRecursive(node any, headers map[string]string) (string, bool) {
	switch v := node.(type) {
	case map[string]interface{}:
		for k, val := range v {
			if k == "header" || k == "headers" {
				if h, ok := val.(map[string]interface{}); ok {
					for hk, hv := range h {
						if s, ok := hv.(string); ok && strings.TrimSpace(s) != "" {
							if headers == nil {
								headers = map[string]string{}
							}
							if _, exists := headers[hk]; !exists {
								headers[hk] = s
							}
						}
					}
				}
			}
		}
		for _, key := range parseURLKeys {
			if val, ok := v[key]; ok {
				if found := parseCandidateURL(val); found != "" {
					return found, true
				}
			}
		}
		for _, key := range []string{"data", "result", "play", "video", "item", "list", "streams", "sources"} {
			if val, ok := v[key]; ok {
				if found, ok := parseURLFromJSONRecursive(val, headers); ok {
					return found, true
				}
			}
		}
		for _, val := range v {
			if found, ok := parseURLFromJSONRecursive(val, headers); ok {
				return found, true
			}
		}
	case []any:
		for _, item := range v {
			if found, ok := parseURLFromJSONRecursive(item, headers); ok {
				return found, true
			}
		}
	case string:
		if found := parseCandidateURL(v); found != "" {
			return found, true
		}
	}
	return "", false
}

func parseURLEncode(raw string) string {
	return strings.ReplaceAll(url.QueryEscape(raw), "+", "%20")
}

func parseFlagFromMap(m map[string]interface{}) bool {
	for _, key := range []string{"parse", "jx"} {
		switch v := m[key].(type) {
		case bool:
			if v {
				return true
			}
		case float64:
			if v == 1 {
				return true
			}
		case int:
			if v == 1 {
				return true
			}
		case json.Number:
			if v.String() == "1" {
				return true
			}
		case string:
			if strings.TrimSpace(v) == "1" {
				return true
			}
		}
	}
	return false
}

func jsonStringField(m map[string]interface{}, key string) string {
	if value, ok := m[key].(string); ok {
		return strings.TrimSpace(value)
	}
	return ""
}

func parsedHeadersFromJSON(m map[string]interface{}) map[string]string {
	for _, key := range []string{"header", "headers"} {
		if node, ok := m[key].(map[string]interface{}); ok {
			out := map[string]string{}
			for k, v := range node {
				if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
					out[k] = s
				}
			}
			if len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

func parsedURLFromJSON(decoded map[string]interface{}) (string, map[string]string, bool) {
	headers := parsedHeadersFromJSON(decoded)
	if headers == nil {
		headers = map[string]string{}
	}
	if found, ok := parseURLFromJSONRecursive(decoded, headers); ok {
		if len(headers) == 0 {
			headers = nil
		}
		return found, headers, true
	}
	return "", nil, false
}

func isParseMediaContentType(contentType string) bool {
	mediaType := strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0]))
	if mediaType == "application/vnd.apple.mpegurl" || mediaType == "application/x-mpegurl" {
		return true
	}
	return strings.HasPrefix(mediaType, "video/") || strings.HasPrefix(mediaType, "audio/")
}

func extractParsedURL(body []byte, contentType, finalURL string) (string, map[string]string, bool) {
	trimmed := strings.TrimSpace(string(body))
	if trimmed != "" {
		jsonText := trimmed
		if !strings.HasPrefix(jsonText, "{") && !strings.HasPrefix(jsonText, "[") {
			if open := strings.Index(jsonText, "("); open >= 0 && strings.HasSuffix(jsonText, ")") {
				jsonText = strings.TrimSpace(jsonText[open+1 : len(jsonText)-1])
			}
		}
		if strings.HasPrefix(jsonText, "{") || strings.HasPrefix(jsonText, "[") {
			var decoded any
			if err := json.Unmarshal([]byte(jsonText), &decoded); err == nil {
				if m, ok := decoded.(map[string]interface{}); ok {
					if found, headers, ok := parsedURLFromJSON(m); ok {
						return found, headers, true
					}
				} else if found, ok := parseURLFromJSONRecursive(decoded, nil); ok {
					return found, nil, true
				}
			}
		}
		if found := parseMediaURLFromText(trimmed); found != "" {
			return found, nil, true
		}
		if isProviderHTTPMediaURL(trimmed) && !strings.ContainsAny(trimmed, " \n\r\t") {
			return trimmed, nil, true
		}
		if found := parseBase64MediaURL(trimmed); found != "" {
			return found, nil, true
		}
		if base, err := url.Parse(finalURL); err == nil {
			srcPattern := regexp.MustCompile(`(?i)(?:src|data-src|href)\s*=\s*["']([^"']+)["']`)
			for _, match := range srcPattern.FindAllStringSubmatch(trimmed, -1) {
				candidate := strings.TrimSpace(match[1])
				if strings.HasPrefix(candidate, "/") || strings.HasPrefix(candidate, "./") {
					if resolved := base.ResolveReference(&url.URL{Path: candidate}); resolved != nil {
						candidate = resolved.String()
					}
				}
				if found := parseMediaURLFromText(candidate); found != "" {
					return found, nil, true
				}
			}
		}
	}
	if isParseMediaContentType(contentType) && isProviderHTTPMediaURL(finalURL) {
		return finalURL, nil, true
	}
	return "", nil, false
}

func resolveViaParseAPIs(ctx context.Context, rawURL, referer string, apis []string) (string, map[string]string, error) {
	if len(apis) == 0 {
		return "", nil, errors.New("需要解析但未配置解析接口")
	}
	client := &http.Client{Timeout: parseAPIRequestTimeout}
	var lastErr error
	for _, template := range apis {
		template = strings.TrimSpace(template)
		if template == "" {
			continue
		}
		requestURL := applyParseTemplate(template, rawURL)
		if !isProviderHTTPMediaURL(requestURL) {
			lastErr = errors.New("解析接口地址无效")
			continue
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("User-Agent", userAgent)
		if referer != "" {
			req.Header.Set("Referer", referer)
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, parseAPIResponseLimit))
		finalURL := resp.Request.URL.String()
		contentType := resp.Header.Get("Content-Type")
		status := resp.StatusCode
		resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if status != http.StatusOK {
			lastErr = fmt.Errorf("解析接口返回 %d", status)
			continue
		}
		if found, headers, ok := extractParsedURL(body, contentType, finalURL); ok {
			return found, headers, nil
		}
		lastErr = errors.New("解析接口未返回可用播放地址")
	}
	if lastErr == nil {
		lastErr = errors.New("解析接口全部失败")
	}
	return "", nil, fmt.Errorf("解析接口全部失败：%w", lastErr)
}

func (engine *nativeEngine) nativeResolveParse(ctx context.Context, input nativeInput) (nativePlan, error) {
	if !isProviderHTTPMediaURL(input.URL) {
		return nativePlan{}, errors.New("待解析地址无效")
	}
	referer := ""
	if input.Headers != nil {
		referer = firstNonEmpty(input.Headers["Referer"], input.Headers["referer"])
	}
	real, parsedHeaders, err := resolveViaParseAPIs(ctx, input.URL, referer, input.ParseAPIs)
	if err != nil {
		return nativePlan{}, err
	}
	if h := parsedHeaders["Referer"]; h != "" {
		referer = h
	} else if h := parsedHeaders["referer"]; h != "" {
		referer = h
	}
	media := providerMedia{URL: real, Referer: referer}
	choice := nativePlaybackChoices(media, 0)
	choice.adBlock = input.AdBlock == nil || *input.AdBlock
	choice.index = nativePreferredRoute(input.Route, len(choice.media))
	if choice.index < 0 || choice.index >= len(choice.media) {
		return nativePlan{}, errors.New("解析结果没有可用播放地址")
	}
	plan, err := engine.nativeOpenPlayback(ctx, choice)
	if err != nil {
		return nativePlan{}, err
	}
	plan.OriginalURL = input.URL
	return plan, nil
}
