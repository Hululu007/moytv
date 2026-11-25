// WebHome 接口面对照补宿主（point1）：host.res / host.pan.check /
// host.history.list / host.site / host.config / host.device。
//
// 接口形态按 notes/point1_webhome.md 的「建议补宿主清单」对齐
// easytv WebHome 的 fm.* 公开文档形态，实现全部本树自写，不抄
// easytv（GPL-3.0）实现。纪律：
//   - 全部只新增，不改 app_js_idj.go 既有方法行为；新方法沿用现有
//     白名单（idjCheckURL）/禁发头/权限声明框架。
//   - host.pan.check 与 host.history.list 的后端能力不在 Go 核内
//     （网盘分享验活全树未实现，Dart 桥 fm.pan.check 亦如实报
//     unsupported；观看记录在 Dart 壳侧 store.history，Go 核读不到）。
//     两者都留了包级接线点（idjPanChecker / idjHistoryProvider）：
//     未注入时明确 reject E_UNSUPPORTED，绝不假实现充数；注入后
//     方法面无需再改。
//   - host.device 只给形态类字段，绝不下发 uuid/MAC/序列号；
//     host.config 只给开关类非敏感字段，secret 绝不下发（与
//     host.settings 恒空的现有红线一致）。
package core

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

// ---------------------------------------------------------------------------
// 宿主上下文（第 5 项）：装配运行时即应注入的静态值。当前没有 Dart
// 侧接线给 Go 核传这些值，默认保持诚实：driveCheck=false（与 Dart
// 桥 fm.config 的现状一致，壳里没有这个开关）、设备形态 mobile /
// android。接线时由宿主在引擎初始化处写 idjContext 即可。
// ---------------------------------------------------------------------------

type idjRuntimeContext struct {
	ConfigID        string
	ConfigDesc      string
	DriveCheck      bool
	DeviceForm      string // "tv" | "mobile"
	DeviceLeanback  bool
	DeviceOS        string
	DeviceOSVersion string
}

var idjContext = idjRuntimeContext{
	DeviceForm: "mobile",
	DeviceOS:   "android",
}

// idjSiteKey 是本站身份键：Dart 侧 _idjCall 传的 pluginId 就是
// manifest.id，两者一致；manifest 没写 id 时回退到 pluginId。
func (s *idjCallState) idjSiteKey() string {
	if s.manifest != nil && s.manifest.id != "" {
		return s.manifest.id
	}
	return s.pluginID
}

func (s *idjCallState) hostSiteFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(goja.FunctionCall) goja.Value {
		obj := rt.NewObject()
		_ = obj.Set("key", s.idjSiteKey())
		name := ""
		typ := ""
		if s.manifest != nil {
			name = s.manifest.name
			typ = s.manifest.typ
		}
		_ = obj.Set("name", name)
		_ = obj.Set("type", typ)
		return obj
	}
}

func (s *idjCallState) hostConfigFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(goja.FunctionCall) goja.Value {
		obj := rt.NewObject()
		_ = obj.Set("id", idjContext.ConfigID)
		_ = obj.Set("desc", idjContext.ConfigDesc)
		_ = obj.Set("driveCheck", idjContext.DriveCheck)
		return obj
	}
}

func (s *idjCallState) hostDeviceFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(goja.FunctionCall) goja.Value {
		form := idjContext.DeviceForm
		if form != "tv" {
			form = "mobile"
		}
		osName := idjContext.DeviceOS
		if osName == "" {
			osName = "android"
		}
		obj := rt.NewObject()
		_ = obj.Set("form", form)
		_ = obj.Set("leanback", idjContext.DeviceLeanback)
		_ = obj.Set("os", osName)
		_ = obj.Set("osVersion", idjContext.DeviceOSVersion)
		return obj
	}
}

// ---------------------------------------------------------------------------
// host.res（第 1 项）：同步返回本地资源代理 URL。
//
// 魔蚁既有本地服务盘点：Go 核 app_stream.go 的 nativeStreamServer
// 是会话制的播放专用代理（token 绑播放会话、资产表由 nativeOpen
// 管理），Dart 侧 lib/html_host/html_gateway.dart 的 /__res 网关
// 只服务 WebHome 页且端口只在 Dart 侧可见——两者都接不到 idj
// 插件这条线。故在此自写一个 idj 专用资源代理：进程内懒启动、
// 绑 127.0.0.1 随机端口，host.res 登记一条带令牌的条目并返回
// http://127.0.0.1:<port>/idjres/<token>。端点侧按条目里存的
// 请求头取源、透传 Range、补默认 UA；目标在登记时已过
// idjCheckURL（插件白名单 + 本机/内网拦截），跳转每跳复查。
// credentials:"include" 时把本插件 Cookie 罐里对该地址的 Cookie
// 快照进条目（罐在调用结束才落盘，代理请求发生在调用之后，
// 快照是唯一可靠的传递方式）。
// ---------------------------------------------------------------------------

const (
	idjResTTL        = 30 * time.Minute
	idjResMaxEntries = 512
)

type idjResEntry struct {
	target   string
	headers  map[string]string
	cookies  []*http.Cookie
	manifest *idjManifest
	created  time.Time
}

var (
	idjResMu      sync.Mutex
	idjResEntries = map[string]*idjResEntry{}
	idjResOnce    sync.Once
	idjResAddr    string
	idjResErr     error
)

func idjResBaseURL() (string, error) {
	idjResOnce.Do(func() {
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			idjResErr = err
			return
		}
		idjResAddr = "http://" + listener.Addr().String()
		server := &http.Server{Handler: http.HandlerFunc(idjResServe), ReadHeaderTimeout: 5 * time.Second}
		go func() { _ = server.Serve(listener) }()
	})
	if idjResErr != nil {
		return "", idjResErr
	}
	return idjResAddr, nil
}

func idjResRegister(entry *idjResEntry) (string, error) {
	tokenBytes := make([]byte, 16)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", err
	}
	token := hex.EncodeToString(tokenBytes)
	now := time.Now()
	idjResMu.Lock()
	defer idjResMu.Unlock()
	for key, old := range idjResEntries {
		if now.Sub(old.created) > idjResTTL {
			delete(idjResEntries, key)
		}
	}
	if len(idjResEntries) >= idjResMaxEntries {
		oldest, oldestAt := "", time.Time{}
		for key, old := range idjResEntries {
			if oldest == "" || old.created.Before(oldestAt) {
				oldest, oldestAt = key, old.created
			}
		}
		delete(idjResEntries, oldest)
	}
	idjResEntries[token] = entry
	return token, nil
}

func (s *idjCallState) hostResFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			idjThrow(rt, "E_PERMISSION", "地址无效")
		}
		rawURL := jsValueString(call.Arguments[0])
		u, err := idjCheckURL(s.manifest, rawURL)
		if err != nil {
			var coded *idjError
			if errors.As(err, &coded) {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_PERMISSION", err.Error())
		}
		opts := idjExportMap(call, 1)
		headers := map[string]string{}
		if opts != nil {
			if h, ok := opts["headers"].(map[string]interface{}); ok {
				for k, v := range h {
					if idjForbiddenHeaders[strings.ToLower(strings.TrimSpace(k))] {
						continue
					}
					headers[k] = fmt.Sprint(v)
				}
			}
		}
		entry := &idjResEntry{target: u.String(), headers: headers, manifest: s.manifest, created: time.Now()}
		if opts != nil {
			if cred, _ := opts["credentials"].(string); cred == "include" {
				entry.cookies = s.jar.Cookies(u)
			}
		}
		base, err := idjResBaseURL()
		if err != nil {
			idjThrow(rt, "E_INTERNAL", "本地资源代理启动失败："+err.Error())
		}
		token, err := idjResRegister(entry)
		if err != nil {
			idjThrow(rt, "E_INTERNAL", "本地资源代理登记失败："+err.Error())
		}
		return rt.ToValue(base + "/idjres/" + token)
	}
}

var idjResForwardHeaders = []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Cache-Control"}

func idjResServe(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Access-Control-Allow-Origin", "*")
	if request.Method == http.MethodOptions {
		writer.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		writer.Header().Set("Access-Control-Allow-Headers", "*")
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	token := strings.TrimPrefix(request.URL.Path, "/idjres/")
	if token == "" || strings.Contains(token, "/") {
		http.NotFound(writer, request)
		return
	}
	idjResMu.Lock()
	entry, ok := idjResEntries[token]
	if ok && time.Since(entry.created) > idjResTTL {
		delete(idjResEntries, token)
		ok = false
	}
	idjResMu.Unlock()
	if !ok {
		http.Error(writer, "资源代理条目已过期", http.StatusGone)
		return
	}
	upstream, err := http.NewRequestWithContext(request.Context(), request.Method, entry.target, nil)
	if err != nil {
		http.Error(writer, "资源地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", idjHTTPDefaultUA)
	for k, v := range entry.headers {
		upstream.Header.Set(k, v)
	}
	if len(entry.cookies) > 0 {
		parts := make([]string, 0, len(entry.cookies))
		for _, c := range entry.cookies {
			parts = append(parts, c.Name+"="+c.Value)
		}
		upstream.Header.Set("Cookie", strings.Join(parts, "; "))
	}
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	client := jsSpiderHTTPClient()
	client.Jar = nil
	client.Timeout = 0
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return idjErr("E_INTERNAL", "重定向次数过多")
		}
		_, err := idjCheckURL(entry.manifest, req.URL.String())
		return err
	}
	resp, err := client.Do(upstream)
	if err != nil {
		http.Error(writer, "读取资源失败", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for _, name := range idjResForwardHeaders {
		if value := resp.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(resp.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, resp.Body)
	}
}

// ---------------------------------------------------------------------------
// host.pan.check（第 3 项）：网盘分享验活入口。
//
// 后端盘点结论：全树没有分享验活能力——Go 核与 Dart 侧的网盘引擎
// 只有登录态浏览（凭据 + 目录 + 直链），Dart 桥 fm.pan.check 已如实
// 报 unsupported（逐家匿名分享接口未接，含迅雷 captcha 与移动加解密），
// 且壳里没有 driveCheck 开关（host.config().driveCheck 恒 false 与之
// 一致）。故此处只立方法面 + 参数归一化 + 权限门：检测器经
// idjPanChecker 注入后即通，未注入时明确 reject E_UNSUPPORTED。
// ---------------------------------------------------------------------------

const idjPanMaxItems = 20

type idjPanItem struct {
	Type     string `json:"type"`
	URL      string `json:"url"`
	Password string `json:"password,omitempty"`
}

// idjPanChecker 是网盘验活的接线点：宿主接入逐家分享验活后注入。
// 返回的每条结果形态对齐 fm.pan.check：{type, url, normalized_url,
// state, cache_hit, checked_at, expires_at, summary}。
var idjPanChecker func(items []idjPanItem) ([]map[string]interface{}, error)

var idjPanTypeAliases = map[string]string{
	"aliyun": "aliyun", "alipan": "aliyun", "aliyundrive": "aliyun",
	"quark": "quark",
	"uc":    "uc",
	"baidu": "baidu", "bd": "baidu", "baidupan": "baidu",
	"tianyi": "tianyi", "189": "tianyi", "cloud189": "tianyi", "ecloud": "tianyi",
	"123": "123", "123pan": "123",
	"xunlei": "xunlei", "thunder": "xunlei",
	"115":    "115",
	"mobile": "mobile", "cmcc": "mobile", "139": "mobile", "yun139": "mobile",
}

func idjPanNormalizeType(raw string) string {
	return idjPanTypeAliases[strings.ToLower(strings.TrimSpace(raw))]
}

// idjPanParseItems 把插件传入的数组归一成 []idjPanItem 并做形态
// 校验：条数 1..20、每条 url 必须是 http/https、type 归一后必须
// 是已知网盘（未知类型如实报 E_ARGS，不猜）。
func idjPanParseItems(raw interface{}) ([]idjPanItem, error) {
	list, ok := raw.([]interface{})
	if !ok || len(list) == 0 {
		return nil, idjErr("E_ARGS", "pan.check 需要非空的 items 数组")
	}
	if len(list) > idjPanMaxItems {
		return nil, idjErrf("E_ARGS", "pan.check 单次最多 %d 条", idjPanMaxItems)
	}
	items := make([]idjPanItem, 0, len(list))
	for _, one := range list {
		m, ok := one.(map[string]interface{})
		if !ok {
			return nil, idjErr("E_ARGS", "pan.check 的每条 item 必须是对象")
		}
		rawType, _ := m["type"].(string)
		typ := idjPanNormalizeType(rawType)
		if typ == "" {
			return nil, idjErr("E_ARGS", "不支持的网盘类型："+rawType)
		}
		rawURL, _ := m["url"].(string)
		rawURL = strings.TrimSpace(rawURL)
		parsed, err := url.Parse(rawURL)
		if err != nil || parsed == nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return nil, idjErr("E_ARGS", "pan.check 的 url 无效："+truncate(rawURL, 80))
		}
		password, _ := m["password"].(string)
		items = append(items, idjPanItem{Type: typ, URL: rawURL, Password: password})
	}
	return items, nil
}

func (s *idjCallState) hostPanObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("check", func(call goja.FunctionCall) goja.Value {
		promise, resolve, reject := rt.NewPromise()
		rejectWith := func(err error) goja.Value {
			var coded *idjError
			if errors.As(err, &coded) {
				_ = reject(idjErrorObject(rt, coded.code, coded.message))
			} else {
				_ = reject(idjErrorObject(rt, "E_INTERNAL", err.Error()))
			}
			return rt.ToValue(promise)
		}
		if !s.manifest.permissions.pan {
			return rejectWith(idjErr("E_PERMISSION", "插件没有声明 pan 权限"))
		}
		if len(call.Arguments) == 0 {
			return rejectWith(idjErr("E_ARGS", "pan.check 需要 items 数组"))
		}
		items, err := idjPanParseItems(call.Arguments[0].Export())
		if err != nil {
			return rejectWith(err)
		}
		if idjPanChecker == nil {
			return rejectWith(idjErr("E_UNSUPPORTED", "网盘分享验活后端未接线：逐家分享接口未接入且壳侧网盘检测开关未下发（idjPanChecker 未注入）"))
		}
		results, err := idjPanChecker(items)
		if err != nil {
			return rejectWith(err)
		}
		out := rt.NewObject()
		_ = out.Set("results", rt.ToValue(results))
		_ = resolve(out)
		return rt.ToValue(promise)
	})
	return obj
}

// ---------------------------------------------------------------------------
// host.history.list（第 4 项）：只读、按本站 siteKey 过滤的最近观看。
//
// 后端盘点结论：观看记录不在 Go 核——Dart 壳侧 store.history 持有
// （fm.history 即读它），且 idjCall 的入参信封没有历史字段，Go 核
// 无从读起。故此处立方法面 + 接线点 idjHistoryProvider：宿主接线
// 时注入一个按 siteKey 查壳侧记录的实现（例如新增 nativeInput
// 字段随调用下发快照，或 Go 核自建记录表），未注入时明确 reject
// E_UNSUPPORTED。过滤责任在注入方：provider 只会收到本站 siteKey。
// ---------------------------------------------------------------------------

// idjHistoryProvider 是观看记录的接线点：按 siteKey 返回该站最近
// 观看，字段形态对齐 fm.history 的子集：{vodId, vodName, vodPic,
// vodFlag, vodRemarks, episodeUrl, position, duration, opening,
// ending, speed, createTime}。
var idjHistoryProvider func(siteKey string, limit int) ([]map[string]interface{}, error)

const (
	idjHistoryDefaultLimit = 20
	idjHistoryMaxLimit     = 50
)

func (s *idjCallState) hostHistoryObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("list", func(call goja.FunctionCall) goja.Value {
		promise, resolve, reject := rt.NewPromise()
		limit := idjHistoryDefaultLimit
		if opts := idjExportMap(call, 0); opts != nil {
			if n := idjTimeoutToMS(opts["limit"]); n > 0 {
				limit = n
			}
		}
		if limit > idjHistoryMaxLimit {
			limit = idjHistoryMaxLimit
		}
		if idjHistoryProvider == nil {
			_ = reject(idjErrorObject(rt, "E_UNSUPPORTED", "观看记录在壳侧存储，Go 核尚未接线（idjHistoryProvider 未注入）"))
			return rt.ToValue(promise)
		}
		rows, err := idjHistoryProvider(s.idjSiteKey(), limit)
		if err != nil {
			_ = reject(idjErrorObject(rt, "E_INTERNAL", "读取观看记录失败："+err.Error()))
			return rt.ToValue(promise)
		}
		if rows == nil {
			rows = []map[string]interface{}{}
		}
		_ = resolve(rt.ToValue(rows))
		return rt.ToValue(promise)
	})
	return obj
}
