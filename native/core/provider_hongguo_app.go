package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"

const hongguoOverseaAppBaseURL = "https://api5-normal-sinfonlinea.fqnovel.com"

type hongguoBaseURLOverrideKey struct{}

const hongguoAppUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

type hongguoCatalogCursor struct {
	Offset        int       `json:"offset"`
	SessionID     string    `json:"sessionId,omitempty"`
	LastID        string    `json:"lastId,omitempty"`
	PageSignature string    `json:"pageSignature,omitempty"`
	Initialized   bool      `json:"initialized"`
	Exhausted     bool      `json:"exhausted"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type hongguoCatalogState struct {
	Version    int                             `json:"version"`
	DeviceID   string                          `json:"deviceId"`
	InstallID  string                          `json:"installId"`
	Registered bool                            `json:"registered,omitempty"`
	Feeds      map[string]hongguoCatalogCursor `json:"feeds"`
}

type hongguoAppClient struct {
	mu                  sync.Mutex
	catalogMu           sync.Mutex
	deviceMu            sync.Mutex
	registerPausedUntil time.Time
	deviceLimited       bool
	// appSuspendedUntil：玩家 App 接口（video_detail / video_model）当前「空 body 未下发
	// 数据」时的短负缓存窗口。窗口内详情/取流直接跳过这条 3 次重试+退避的慢链、改走网页，
	// 提速详情与播放页；窗口过后自动重试，App 恢复即可无缝切回。只由 /player/ 端点空 body 触发。
	appSuspendedUntil time.Time
	baseURL           string
	state             hongguoCatalogState
	details           map[string]hongguoDetailEntry
	pending           map[string]*hongguoDetailCall
	searches          map[string]hongguoSearchEntry
	searchPending     map[string]*hongguoSearchCall
	suggestions       map[string]hongguoSuggestionEntry
	suggestPending    map[string]*hongguoSuggestionCall
	danmaku           map[string]hongguoDanmakuCacheEntry
	danmakuPending    map[string]*hongguoDanmakuCall
	webFallback       hongguoWebFallbackState
}

func (downloader *Downloader) hongguoClient() *hongguoAppClient {
	downloader.hongguoOnce.Do(func() {
		downloader.hongguo = &hongguoAppClient{
			baseURL: hongguoAppBaseURL,
			state:   hongguoCatalogState{Version: 1, DeviceID: newHongguoDeviceID(), InstallID: newHongguoDeviceID(), Feeds: map[string]hongguoCatalogCursor{}},
			details: map[string]hongguoDetailEntry{}, pending: map[string]*hongguoDetailCall{},
			searches: map[string]hongguoSearchEntry{}, searchPending: map[string]*hongguoSearchCall{},
			suggestions: map[string]hongguoSuggestionEntry{}, suggestPending: map[string]*hongguoSuggestionCall{},
		}
	})
	return downloader.hongguo
}

func cloneHongguoCatalogState(state *hongguoCatalogState) *hongguoCatalogState {
	if state == nil {
		return nil
	}
	cloned := *state
	cloned.Feeds = make(map[string]hongguoCatalogCursor, len(state.Feeds))
	for name, cursor := range state.Feeds {
		cloned.Feeds[name] = cursor
	}
	return &cloned
}

func (downloader *Downloader) restoreHongguoCatalog(state *hongguoCatalogState) {
	if state == nil || state.Version != 1 || !hongguoNumericID.MatchString(state.DeviceID) || !hongguoNumericID.MatchString(state.InstallID) {
		return
	}
	cloned := cloneHongguoCatalogState(state)
	for name, cursor := range cloned.Feeds {
		known := false
		for _, genre := range hongguoAppGenres {
			known = known || name == genre.key || name == "category:"+genre.key
		}
		if !known || !cursor.Initialized || cursor.Offset < 0 || cursor.Offset > 1_000_000 || len(cursor.SessionID) > 4096 || len(cursor.LastID) > 256 || len(cursor.PageSignature) > 64 {
			delete(cloned.Feeds, name)
		}
	}
	client := downloader.hongguoClient()
	client.catalogMu.Lock()
	defer client.catalogMu.Unlock()
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.state.Feeds) == 0 {
		client.state = *cloned
	}
}

func (downloader *Downloader) hongguoCatalogSnapshot() *hongguoCatalogState {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return cloneHongguoCatalogState(&client.state)
}

func hongguoCatalogInitialized(state *hongguoCatalogState) bool {
	if state != nil && state.Version == 1 {
		for _, cursor := range state.Feeds {
			if cursor.Initialized {
				return true
			}
		}
	}
	return false
}

func hongguoCatalogHasMore(state *hongguoCatalogState) bool {
	for _, genre := range hongguoAppGenres {
		if state == nil || !state.Feeds[genre.key].Exhausted {
			return true
		}
	}
	return false
}

func hongguoAppQuery(deviceID, installID string) url.Values {
	return url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
		"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"}, "device_id": {deviceID}, "iid": {installID},
	}
}

// clearHongguoPlayerSuspended 重置玩家 App 接口的负缓存窗口（App 恢复可用时调用）。
func (downloader *Downloader) clearHongguoPlayerSuspended() {
	client := downloader.hongguoClient()
	client.mu.Lock()
	client.appSuspendedUntil = time.Time{}
	client.mu.Unlock()
}

// markHongguoPlayerSuspended 开启一个 60s 负缓存窗口：窗口内详情/取流跳过玩家 App
// 档（3 次重试+退避的慢链）、直走网页。仅在玩家端点空 body 时由 hongguoAppRequest 触发。
func (downloader *Downloader) markHongguoPlayerSuspended() {
	client := downloader.hongguoClient()
	client.mu.Lock()
	client.appSuspendedUntil = time.Now().Add(hongguoPlayerSuspendWindow)
	client.mu.Unlock()
}

// hongguoPlayerSuspended 判断玩家 App 档是否处于「暂不可用」负缓存窗口内，
// 供详情/取流链决定是否跳过 App 档改走网页。
func (downloader *Downloader) hongguoPlayerSuspended() bool {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return time.Now().Before(client.appSuspendedUntil)
}

// 玩家 App 接口（video_detail / video_model）空 body 时跳过该档的负缓存窗口时长。
// 窗口内详情/播放页直接走更快的网页取流；过后自动重试，App 恢复即无缝切回。
const hongguoPlayerSuspendWindow = 60 * time.Second

// errHongguoAppEmptyBody：玩家 App 端点回 HTTP 200 空 body。空 body 既是“未注册
// 设备号”的信号，也是“设备对被限流”的信号；文案与旧版保持一致，调用方用
// errors.Is 区分空 body 与其他失败。
var errHongguoAppEmptyBody = errors.New("红果 App 接口未返回有效数据")

func (downloader *Downloader) hongguoAppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return downloader.hongguoAppRequestInternal(ctx, method, path, extra, payload, false)
}

// hongguoAppRequestInternal：suppressSuspend 为真时，玩家端点空 body 只返回
// errHongguoAppEmptyBody，不开启负缓存窗口；供取流链先轮换设备重试，轮换耗尽
// 后再由调用方统一挂起。成功响应无论 suppress 与否都会清除窗口。
func (downloader *Downloader) hongguoAppRequestInternal(ctx context.Context, method, path string, extra url.Values, payload any, suppressSuspend bool) (map[string]any, error) {
	client := downloader.hongguoClient()
	comment, _ := ctx.Value(hongguoCommentKey{}).(bool)
	signed := !comment && path != hongguoBookmallTabPath
	client.mu.Lock()
	base, deviceID, installID := client.baseURL, client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	if override, ok := ctx.Value(hongguoBaseURLOverrideKey{}).(string); ok && override != "" {
		base = override
	}
	query := hongguoAppQuery(deviceID, installID)
	for key, values := range extra {
		query[key] = append([]string(nil), values...)
	}
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}
	attempts := downloader.cfg.Retries
	if attempts < 1 {
		attempts = 1
	}
	if attempts > 3 {
		attempts = 3
	}
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		request.Header.Set("Accept", "application/json")
		request.Header.Set("X-XS-From-Web", "0")
		request.Header.Set("Sdk-Version", "2")
		var commentNonce hongguoCommentNonce
		if comment {
			commentNonce, err = newHongguoCommentNonce()
			if err != nil {
				return nil, errors.New("无法准备红果文字请求")
			}
			request.Header.Set("Comment-Source", "601")
			request.Header.Set("Server-Channel", "1000")
		}
		if payload != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
			now := time.Now()
			query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
			prepared.URL.RawQuery = query.Encode()
			if comment {
				signHongguoCommentRequest(prepared, commentNonce, now)
			} else if signed {
				signHongguoPlayerRequest(prepared, body, now)
			}
		})
		if err != nil {
			lastErr = err
			var backoff *requestBackoff
			if errors.As(err, &backoff) || ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		if len(content) == 0 {
			lastErr = errHongguoAppEmptyBody
			// 玩家 App 端点（video_detail / video_model）空 body 时开启短负缓存窗口，
			// 让紧随其后的详情/取流跳过这条「3 次重试 + 退避」的慢链、改走网页；
			// 首页 catalog 端点（landpage）不含 /player/，不受影响。
			if strings.Contains(path, "/player/") {
				if suppressSuspend {
					// 轮换优先于负缓存：取流链先换设备对重试，耗尽后再统一挂起。
					return nil, errHongguoAppEmptyBody
				}
				downloader.markHongguoPlayerSuspended()
				// 玩家端点有网页取流兜底 + 60s 负缓存：空 body 说明 App 档当前不供数，
				// 重复请求只会拿到同样的空结果、叠加退避等待，对「首次打开」徒增耗时。
				// 直接结束本档，交给网页/备用取流；App 恢复后靠负缓存过期自动切回。
				break
			}
			continue
		}
		if len(content) > providerMaxBodyBytes {
			return nil, errors.New("红果 App 接口未返回有效数据")
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			return nil, errors.New("红果 App 接口返回格式异常")
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
		}
		// 玩家 App 接口恢复正常，清除负缓存窗口，后续详情/取流重新走 App 档。
		if strings.Contains(path, "/player/") {
			downloader.clearHongguoPlayerSuspended()
		}
		return result, nil
	}
	return nil, lastErr
}
