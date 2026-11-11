package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"

const hongguoOverseaAppBaseURL = "https://api5-normal-sinfonlinea.fqnovel.com"

// hongguoAccountAppBaseURL：账号接口（收藏/历史/预约/进度）走的域名，与对照仓一致。
const hongguoAccountAppBaseURL = "https://api5-normal-sinfonlinea.fqnovel.com"

type hongguoBaseURLOverrideKey struct{}

// hongguoAccountOverrideKey：ctx 里携带的账号会话（登录态），账号接口调用时
// 用账号设备号签名、用账号 Cookie 发请求；未携带时走设备身份。
type hongguoAccountOverrideKey struct{}

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

type hongguoRouteHealth struct {
	lastSuccess time.Time
	coolUntil   time.Time
	empty       bool
}

type hongguoUpcomingModel struct {
	model   map[string]any
	expires time.Time
}

type hongguoAccountSession struct {
	Cookie    string
	DeviceID  string
	InstallID string
	AccountID string
	// UserName：账号信息接口回的用户名；App 短信路拿不到时为空。
	UserName string
	// ExpiresAt：登录 Cookie 的过期时间；服务端没给 Expires/Max-Age 时为零值（未知）。
	ExpiresAt time.Time
	// Source：Cookie 来源，"web" 站内 passport / "app" App 形态 passport；空表示未知。
	Source string
}

// hongguoAccountCookieWebSource / hongguoAccountCookieAppSource：会话 Cookie 的
// 两个来源；恢复时按来源把 Cookie 种回对应域名的 Cookie 罐，
// 让冷启动后调 hongguoAccountInfo 刷新身份也能走通。
const hongguoAccountCookieWebSource = "web"

const hongguoAccountCookieAppSource = "app"

// hongguoAccountCookieHost：会话来源对应的 Cookie 域名。
func hongguoAccountCookieHost(source string) string {
	switch source {
	case hongguoAccountCookieWebSource:
		return "hongguoduanju.com"
	case hongguoAccountCookieAppSource:
		return "security.snssdk.com"
	default:
		return ""
	}
}

// hongguoAccountSessionCookieNames：判定登录态的 Cookie 名。
var hongguoAccountSessionCookieNames = []string{"sessionid", "sessionid_ss"}

func (session hongguoAccountSession) loggedIn() bool {
	return strings.TrimSpace(session.Cookie) != ""
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
	// routes：按路由（方法+域名+路径）记成功时间与空响应冷却；失败重试时先跳过冷却中的。
	routes map[string]*hongguoRouteHealth
	// cookies：最小 Cookie 会话，按域名记 name=value；收注册与播放接口的 Set-Cookie，
	// 后续同域请求带上。不引入重型 cookie 罐。
	cookies map[string]map[string]string
	// cookieExpires：Set-Cookie 带的过期时间（Expires 或 Max-Age 换算），按域名+名记；
	// 会话 Cookie（sessionid）没给过期时间时这里没条目，过期时间即未知。
	cookieExpires map[string]map[string]time.Time
	// upcoming：批量多取的后续集模型缓存，60 秒有效、领取即删，上限 6 条。
	upcoming map[string]hongguoUpcomingModel
	// account：账号会话槽，Dart 侧登录成功后经 setter 交进来；账号接口调用时带上。
	account hongguoAccountSession
	// qrToken：扫码登录当前二维码的轮询 token；appTicket/appMobile：App 短信登录的会话；
	// webSent/webMobile：站内短信登录的发码状态。
	qrToken   string
	appTicket string
	appMobile string
	webSent   bool
	webMobile string
}

func (downloader *Downloader) hongguoClient() *hongguoAppClient {
	downloader.hongguoOnce.Do(func() {
		downloader.hongguo = &hongguoAppClient{
			baseURL: hongguoAppBaseURL,
			state:   hongguoCatalogState{Version: 1, DeviceID: newHongguoDeviceID(), InstallID: newHongguoDeviceID(), Feeds: map[string]hongguoCatalogCursor{}},
			details: map[string]hongguoDetailEntry{}, pending: map[string]*hongguoDetailCall{},
			searches: map[string]hongguoSearchEntry{}, searchPending: map[string]*hongguoSearchCall{},
			suggestions: map[string]hongguoSuggestionEntry{}, suggestPending: map[string]*hongguoSuggestionCall{},
			routes: map[string]*hongguoRouteHealth{}, cookies: map[string]map[string]string{},
			cookieExpires: map[string]map[string]time.Time{},
			upcoming: map[string]hongguoUpcomingModel{},
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

// errHongguoDeviceRejected：播放接口回业务码 10001/10002/110001，含义是播放接口
// 拒绝当前设备，处理是作废设备重注册再试，不是重试同一请求。
var errHongguoDeviceRejected = errors.New("红果播放接口拒绝当前设备")

func hongguoIsDeviceRejectedCode(code string) bool {
	return code == "10001" || code == "10002" || code == "110001"
}

func hongguoRouteKey(method, base, path string) string {
	return method + "|" + strings.TrimRight(base, "/") + path
}

func (client *hongguoAppClient) hongguoRouteHealth(key string) *hongguoRouteHealth {
	if client.routes == nil {
		client.routes = map[string]*hongguoRouteHealth{}
	}
	health, ok := client.routes[key]
	if !ok {
		health = &hongguoRouteHealth{}
		client.routes[key] = health
	}
	return health
}

// hongguoRouteCooling：该路由是否在空响应/失败冷却期内。
func (downloader *Downloader) hongguoRouteCooling(key string) bool {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	health, ok := client.routes[key]
	return ok && time.Now().Before(health.coolUntil)
}

// hongguoRouteLastSuccess：该路由最近一次成功时间（零值表示从未成功）。
func (downloader *Downloader) hongguoRouteLastSuccess(key string) time.Time {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if health, ok := client.routes[key]; ok {
		return health.lastSuccess
	}
	return time.Time{}
}

func (client *hongguoAppClient) hongguoNoteRouteSuccess(key string) {
	client.mu.Lock()
	defer client.mu.Unlock()
	health := client.hongguoRouteHealth(key)
	health.lastSuccess = time.Now()
	health.coolUntil = time.Time{}
	health.empty = false
}

func (client *hongguoAppClient) hongguoNoteRouteFailure(key string, empty bool) {
	client.mu.Lock()
	defer client.mu.Unlock()
	health := client.hongguoRouteHealth(key)
	cool := 5 * time.Second
	if empty {
		cool = 30 * time.Second
	}
	health.coolUntil = time.Now().Add(cool)
	health.empty = empty
}

// hongguoStoreCookies：收响应里的 Set-Cookie，按域名记 name=value；
// 带 Expires/Max-Age 的同时记过期时间。调用方须已持有 client.mu。
func (client *hongguoAppClient) hongguoStoreCookies(host string, response *http.Response) {
	if host == "" || response == nil {
		return
	}
	cookies := response.Cookies()
	if len(cookies) == 0 {
		return
	}
	jar, ok := client.cookies[host]
	if !ok {
		jar = map[string]string{}
		client.cookies[host] = jar
	}
	if client.cookieExpires == nil {
		client.cookieExpires = map[string]map[string]time.Time{}
	}
	expires, ok := client.cookieExpires[host]
	if !ok {
		expires = map[string]time.Time{}
		client.cookieExpires[host] = expires
	}
	for _, cookie := range cookies {
		if cookie.Name != "" && cookie.Value != "" {
			jar[cookie.Name] = cookie.Value
		}
		if cookie.Name == "" {
			continue
		}
		expiry := cookie.Expires
		if expiry.IsZero() && cookie.MaxAge > 0 {
			expiry = time.Now().Add(time.Duration(cookie.MaxAge) * time.Second)
		}
		if !expiry.IsZero() {
			expires[cookie.Name] = expiry
		}
	}
}

// hongguoCookieExpiryLocked：该域会话 Cookie（sessionid/sessionid_ss）中最早的
// 过期时间；都没给时返回零值（未知）。调用方须已持有 client.mu。
func (client *hongguoAppClient) hongguoCookieExpiryLocked(host string) time.Time {
	var earliest time.Time
	for _, name := range hongguoAccountSessionCookieNames {
		expiry := client.cookieExpires[host][name]
		if expiry.IsZero() {
			continue
		}
		if earliest.IsZero() || expiry.Before(earliest) {
			earliest = expiry
		}
	}
	return earliest
}

// hongguoSeedCookieJarLocked：把 "name=value; ..." 形式的 Cookie 串种回指定域名的
// Cookie 罐（冷启动恢复用；不知道来源域名时不种）。调用方须已持有 client.mu。
func (client *hongguoAppClient) hongguoSeedCookieJarLocked(host, cookie string) {
	if host == "" || strings.TrimSpace(cookie) == "" {
		return
	}
	if client.cookies == nil {
		client.cookies = map[string]map[string]string{}
	}
	jar, ok := client.cookies[host]
	if !ok {
		jar = map[string]string{}
		client.cookies[host] = jar
	}
	for _, part := range strings.Split(cookie, ";") {
		part = strings.TrimSpace(part)
		name, value, found := strings.Cut(part, "=")
		if !found || strings.TrimSpace(name) == "" || strings.TrimSpace(value) == "" {
			continue
		}
		jar[strings.TrimSpace(name)] = strings.TrimSpace(value)
	}
}

// hongguoClearLoginCookiesLocked：清掉两个登录域名的会话 Cookie（登出用；
// csrf token 等其他 Cookie 不动）。调用方须已持有 client.mu。
func (client *hongguoAppClient) hongguoClearLoginCookiesLocked() {
	for _, host := range []string{"hongguoduanju.com", "security.snssdk.com"} {
		for _, name := range hongguoAccountSessionCookieNames {
			delete(client.cookies[host], name)
			delete(client.cookieExpires[host], name)
		}
	}
}

// hongguoCookieHeader：该域已存的 Cookie 拼成请求头值；没有返回空串。
func (client *hongguoAppClient) hongguoCookieHeader(host string) string {
	jar := client.cookies[host]
	if len(jar) == 0 {
		return ""
	}
	names := make([]string, 0, len(jar))
	for name := range jar {
		names = append(names, name)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, name+"="+jar[name])
	}
	return strings.Join(parts, "; ")
}

// hongguoOfferUpcomingModel：批量多取的后续集模型进缓存，60 秒有效、上限 6 条。
func (downloader *Downloader) hongguoOfferUpcomingModel(videoID string, model map[string]any) {
	if videoID == "" || len(model) == 0 {
		return
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.upcoming == nil {
		client.upcoming = map[string]hongguoUpcomingModel{}
	}
	now := time.Now()
	for id, entry := range client.upcoming {
		if now.After(entry.expires) {
			delete(client.upcoming, id)
		}
	}
	if len(client.upcoming) >= 6 {
		for id := range client.upcoming {
			delete(client.upcoming, id)
			break
		}
	}
	client.upcoming[videoID] = hongguoUpcomingModel{model: model, expires: now.Add(60 * time.Second)}
}

// hongguoTakeUpcomingModel：领取预取模型，领取即删；过期返回未命中。
func (downloader *Downloader) hongguoTakeUpcomingModel(videoID string) (map[string]any, bool) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	entry, ok := client.upcoming[videoID]
	if !ok {
		return nil, false
	}
	delete(client.upcoming, videoID)
	if time.Now().After(entry.expires) {
		return nil, false
	}
	return entry.model, true
}

// hongguoAccountSessionSnapshot：当前账号会话快照（不含 Cookie 全文的输出在别处）。
func (downloader *Downloader) hongguoAccountSessionSnapshot() hongguoAccountSession {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.account
}

// setHongguoAccountSession：把账号会话交进 Go 核；空 Cookie 即清掉登录态。
// 恢复（冷启动）时按 Source 把 Cookie 种回对应域名的 Cookie 罐，
// 这样恢复后调 hongguoAccountInfo 刷新身份也能走通；登出时连罐里的
// 会话 Cookie 一起清掉。Cookie 值只存不记日志。
func (downloader *Downloader) setHongguoAccountSession(session hongguoAccountSession) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	session.Cookie = strings.TrimSpace(session.Cookie)
	session.DeviceID = strings.TrimSpace(session.DeviceID)
	session.InstallID = strings.TrimSpace(session.InstallID)
	session.AccountID = strings.TrimSpace(session.AccountID)
	session.UserName = strings.TrimSpace(session.UserName)
	session.Source = strings.TrimSpace(session.Source)
	client.account = session
	if session.Cookie == "" {
		client.hongguoClearLoginCookiesLocked()
		return
	}
	client.hongguoSeedCookieJarLocked(hongguoAccountCookieHost(session.Source), session.Cookie)
}

// hongguoAccountStatus：账号会话状态（不含 Cookie 值，供桥接回给 Dart）。
// expiresAtMs 为 0 表示服务端没给过期时间（未知），不是已过期。
func (downloader *Downloader) hongguoAccountStatus() map[string]any {
	session := downloader.hongguoAccountSessionSnapshot()
	expiresMs := int64(0)
	if !session.ExpiresAt.IsZero() {
		expiresMs = session.ExpiresAt.UnixMilli()
	}
	return map[string]any{
		"loggedIn":    session.loggedIn(),
		"accountId":   session.AccountID,
		"userName":    session.UserName,
		"expiresAtMs": expiresMs,
		"hasDevice":   session.DeviceID != "",
	}
}

// hongguoAccountExportSession：把当前账号会话导出成 JSON，给 Dart 侧持久化、
// 冷启动后经 hongguoAccountSetSession 交回来恢复。只导出，不打印 Cookie 值
// 到任何日志（调用方日志里也只写“有/无”、长度）。
func (downloader *Downloader) hongguoAccountExportSession() map[string]any {
	session := downloader.hongguoAccountSessionSnapshot()
	expiresMs := int64(0)
	if !session.ExpiresAt.IsZero() {
		expiresMs = session.ExpiresAt.UnixMilli()
	}
	return map[string]any{
		"loggedIn":      session.loggedIn(),
		"accountCookie": session.Cookie,
		"deviceId":      session.DeviceID,
		"installId":     session.InstallID,
		"accountId":     session.AccountID,
		"userName":      session.UserName,
		"expiresAtMs":   expiresMs,
		"cookieSource":  session.Source,
	}
}

func (downloader *Downloader) hongguoAppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return downloader.hongguoAppRequestInternal(ctx, method, path, extra, payload, false)
}

// hongguoAppRequestInternal：suppressSuspend 为真时，玩家端点空 body 只返回
// errHongguoAppEmptyBody，不开启负缓存窗口；供取流链先轮换设备重试，轮换耗尽
// 后再由调用方统一挂起。成功响应无论 suppress 与否都会清除窗口。
func (downloader *Downloader) hongguoAppRequestInternal(ctx context.Context, method, path string, extra url.Values, payload any, suppressSuspend bool) (map[string]any, error) {
	return downloader.hongguoAppRequestInternalOpts(ctx, method, path, extra, payload, suppressSuspend, false)
}

// hongguoAppRequestInternalOpts：gzipBody 为真时请求体先 gzip 再签名（预约写接口用）。
func (downloader *Downloader) hongguoAppRequestInternalOpts(ctx context.Context, method, path string, extra url.Values, payload any, suppressSuspend, gzipBody bool) (map[string]any, error) {
	client := downloader.hongguoClient()
	comment, _ := ctx.Value(hongguoCommentKey{}).(bool)
	account, _ := ctx.Value(hongguoAccountOverrideKey{}).(hongguoAccountSession)
	client.mu.Lock()
	base, deviceID, installID := client.baseURL, client.state.DeviceID, client.state.InstallID
	registered := client.state.Registered
	client.mu.Unlock()
	if override, ok := ctx.Value(hongguoBaseURLOverrideKey{}).(string); ok && override != "" {
		base = override
	}
	// 账号接口：用账号设备号签名、用账号 Cookie 发请求。
	accountCookie := ""
	if account.loggedIn() {
		if account.DeviceID != "" {
			deviceID = account.DeviceID
		}
		if account.InstallID != "" {
			installID = account.InstallID
		}
		accountCookie = account.Cookie
	}
	form := hongguoSignNone
	if !comment {
		form = hongguoSignFormForPath(path, registered)
		if account.loggedIn() && form == hongguoSignNone {
			form = hongguoSignPlayback
		}
	}
	routeKey := hongguoRouteKey(method, base, path)
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
		if gzipBody {
			var gzipped bytes.Buffer
			writer := gzip.NewWriter(&gzipped)
			if _, err := writer.Write(body); err != nil {
				return nil, err
			}
			if err := writer.Close(); err != nil {
				return nil, err
			}
			body = gzipped.Bytes()
		}
	}
	attempts := downloader.cfg.Retries
	if attempts < 1 {
		attempts = 1
	}
	if attempts > 3 {
		attempts = 3
	}
	if _, single := ctx.Value(hongguoSingleAttemptKey{}).(bool); single {
		// 写接口单次尝试，不自动重试。
		attempts = 1
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
		if accountCookie != "" {
			request.Header.Set("Cookie", accountCookie)
		} else if cookie := func() string {
			client.mu.Lock()
			defer client.mu.Unlock()
			return client.hongguoCookieHeader(request.URL.Host)
		}(); cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
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
			if gzipBody {
				request.Header.Set("Content-Encoding", "gzip")
			}
		}
		response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
			now := time.Now()
			if comment {
				query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
				prepared.URL.RawQuery = query.Encode()
				signHongguoCommentRequest(prepared, commentNonce, now)
			} else if form != hongguoSignNone {
				hongguoPrepareSignedRequest(prepared, query, body, now, form == hongguoSignPlayback, "")
			} else {
				query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
				prepared.URL.RawQuery = query.Encode()
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
		client.mu.Lock()
		client.hongguoStoreCookies(request.URL.Host, response)
		client.mu.Unlock()
		content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			client.hongguoNoteRouteFailure(routeKey, false)
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			client.hongguoNoteRouteFailure(routeKey, false)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		if len(content) == 0 {
			lastErr = errHongguoAppEmptyBody
			client.hongguoNoteRouteFailure(routeKey, true)
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
			client.hongguoNoteRouteFailure(routeKey, false)
			return nil, errors.New("红果 App 接口未返回有效数据")
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			client.hongguoNoteRouteFailure(routeKey, false)
			return nil, errors.New("红果 App 接口返回格式异常")
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			client.hongguoNoteRouteFailure(routeKey, false)
			if hongguoIsDeviceRejectedCode(code) {
				return nil, fmt.Errorf("%w（业务码 %s）", errHongguoDeviceRejected, code)
			}
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
		}
		client.hongguoNoteRouteSuccess(routeKey)
		// 玩家 App 接口恢复正常，清除负缓存窗口，后续详情/取流重新走 App 档。
		if strings.Contains(path, "/player/") {
			downloader.clearHongguoPlayerSuspended()
		}
		return result, nil
	}
	return nil, lastErr
}

// hongguoSignForm：签名形态分工——播放类走播放器形态，一般接口走通用形态，
// 推荐在无播放身份时免签、有身份时走播放器形态；评论签名不动（调用方另行处理）。
type hongguoSignForm int

const (
	hongguoSignNone hongguoSignForm = iota
	hongguoSignPlayback
	hongguoSignGeneric
)

const hongguoBookmallCellChangePath = "/reading/bookapi/bookmall/cell/change/v1/"

func hongguoSignFormForPath(path string, registered bool) hongguoSignForm {
	if strings.Contains(path, "/player/") || strings.Contains(path, "/video_tab/") {
		return hongguoSignPlayback
	}
	if path == hongguoBookmallTabPath || path == hongguoBookmallCellChangePath {
		if registered {
			return hongguoSignPlayback
		}
		return hongguoSignNone
	}
	return hongguoSignGeneric
}
