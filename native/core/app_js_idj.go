// iDuanJu idj1 插件兼容层（Go 核宿主）。
//
// 只按接口规范自己写，不抄 iDuanJu 源码（GPL-3.0）：接口依据是设计文档
// docs/idjplugin-system-design.md §2、RE 报告 §8–§9 与
// plugin_js_analysis.md 的观测结论；host.* 的函数名与参数形态按
// idj1 规范（SPEC_ZH.md §3/§5）对齐，prelude 与各回调均为本树新写。
//
// 落点：新 action "idjCall"，每次调用新建 goja runtime；脚本与 manifest
// 由 Dart 侧从包文件读出随请求传进来（action 入参：content=main.js 源码，
// manifest=manifest JSON，pluginId/fn/args 另见 nativeInput）。
// app_js_spider.go 与 app_js_spider_compat.go 只复用，不改。
package core

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"crypto"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"hash"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

// host.version 固定值：1.5.2 是所实现的 idj1 宿主规格水平（不是 App 版本
// 号）。4 个插件的 minAppVersion 都是 1.5，用 Go 核版本 0.2.19 会判
// 0.2.19 < 1.5 而拒装全部 4 个，故按设计 §9 第 1 项的建议值写死。
const (
	idjVersionApp  = "1.5.2"
	idjVersionSpec = "idj1"
)

const (
	// idjMaxRequestsPerCall 单次插件调用最多发多少个请求（iDuanJu 值）。
	idjMaxRequestsPerCall = 60
	// idjMaxRequestsPerMinute 每插件每分钟最多发多少个请求（滑动窗口）。
	idjMaxRequestsPerMinute = 120
	// idjMaxBodyBytes host.http.request 的响应体上限（iDuanJu 值 20MB；
	// jsDoFetch 的 8MB 不适用于 idj 路径）。
	idjMaxBodyBytes = 20 << 20
	// idjMaxStorageBytes 每插件 storage.json 上限（iDuanJu 值 1MB）。
	idjMaxStorageBytes = 1 << 20
	// idjMaxHTMLNodes 单次调用里 host.html.parse 累计的节点上限。
	idjMaxHTMLNodes = 300000
	// idjDefaultRequestTimeoutMS host.http.request 无 timeout 时的默认值。
	idjDefaultRequestTimeoutMS = 25000
)

// 超时预算（iDuanJu 值，RE §8.4）。包级变量只为测试能收紧预算，生产
// 不改：初始化 15 秒、has 5 秒、普通调用 30 秒；播放（player/play）
// 单独 90 秒——play 要串行发两个请求（播放页 + 换链），弱网下 30 秒
// 会被打爆（AI短剧AV 实证）。Dart 层总兜底：普通调用 70 秒、播放
// 路径 100 秒（大于 Go 侧预算，让 E_TIMEOUT 先在 Go 侧触发）。
var (
	idjInitTimeout = 15 * time.Second
	idjHasTimeout  = 5 * time.Second
	idjCallTimeout = 30 * time.Second
	idjPlayTimeout = 90 * time.Second
)

// 仅测试用的开关与可调限额（生产保持默认值）：
//   - idjAllowLoopback：httptest 服务器跑在 127.0.0.1 上，本机/内网拦截
//     与白名单会把它拦掉；测试把它置 true 才放行回环地址，生产恒 false。
//   - idjTestMaxBodyBytes / idjTestMaxStorageBytes：测试把 20MB/1MB 上限
//     收小后验证“超限拒绝”，避免测试里真的发 20MB/写 1MB。
var (
	idjAllowLoopback       = false
	idjTestMaxBodyBytes    = 0
	idjTestMaxStorageBytes = 0
)

func idjBodyLimit() int {
	if idjTestMaxBodyBytes > 0 {
		return idjTestMaxBodyBytes
	}
	return idjMaxBodyBytes
}

func idjStorageLimit() int {
	if idjTestMaxStorageBytes > 0 {
		return idjTestMaxStorageBytes
	}
	return idjMaxStorageBytes
}

// idjError 是带规范码的错误。Error() 的形态与 iDuanJu
// PluginError.describe 的默认分支一致："<message> (<code>)"，
// 插件自用的规范外码（E_NET/E_AUTH/E_EMPTY 等）也原样透传、不改写。
type idjError struct {
	code    string
	message string
}

func (e *idjError) Error() string {
	if e.code == "" {
		return e.message
	}
	return e.message + " (" + e.code + ")"
}

func idjErr(code, message string) *idjError { return &idjError{code: code, message: message} }

func idjErrf(code, format string, args ...interface{}) *idjError {
	return &idjError{code: code, message: fmt.Sprintf(format, args...)}
}

// idjErrorObject 造一个带 .code 的 JS Error 形态对象（plain object，
// 两个属性都可枚举，jsExportValue 能读到；探针已验证此形态）。
func idjErrorObject(rt *goja.Runtime, code, message string) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("code", code)
	_ = obj.Set("message", message)
	return obj
}

// idjThrow 在 Go 回调里把带码错误抛给 JS：panic 一个 goja 值，
// goja 会把它转成 JS 侧的 throw（插件的 try/catch 能接住，
// async 函数里则变成 rejected Promise）。
func idjThrow(rt *goja.Runtime, code, message string) {
	panic(idjErrorObject(rt, code, message))
}

// idjErrorFromValue 把插件抛出的值（rejected Promise 的 Result，
// 或 *goja.Exception 的 Value）还原成带码的 Go 错误。
func idjErrorFromValue(rt *goja.Runtime, v goja.Value) error {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return idjErr("E_INTERNAL", "插件抛出了空错误")
	}
	if decoded, err := jsExportValue(rt, v); err == nil {
		if m, ok := decoded.(map[string]interface{}); ok {
			code, _ := m["code"].(string)
			msg, _ := m["message"].(string)
			if code != "" {
				if msg == "" {
					msg = code
				}
				return idjErr(code, msg)
			}
			if msg != "" {
				return idjErr("E_INTERNAL", msg)
			}
		}
		if text, ok := decoded.(string); ok && text != "" {
			return idjErr("E_INTERNAL", text)
		}
	}
	text := jsValueString(v)
	if text == "" {
		text = fmt.Sprintf("%v", v.Export())
	}
	return idjErr("E_INTERNAL", text)
}

// idjErrorFromGoErr 把 fn() 直接返回的 Go 错误还原：JS 抛出的走
// idjErrorFromValue，其余按 E_INTERNAL 包起来。
func idjErrorFromGoErr(rt *goja.Runtime, err error) error {
	var ex *goja.Exception
	if errors.As(err, &ex) {
		return idjErrorFromValue(rt, ex.Value())
	}
	return idjErr("E_INTERNAL", err.Error())
}

// ---------------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------------

type idjPermissions struct {
	http       []string
	media      []string
	cloudflare bool
	storage    bool
	login      bool
	pan        bool // WebHome 对照补宿主：permissions.pan（host.pan.check 的审计声明）
	present    bool // manifest 里到底有没有 permissions 一节
}

type idjManifest struct {
	id             string
	name           string
	version        string
	entry          string
	typ            string
	capabilities   []string
	permissions    idjPermissions
	integrity      string // 去掉 sha256- 前缀后的 base64 值；空表示未声明
	integrityEntry string // 对象形态时 integrity.files 里对应的入口名
}

func idjParseManifest(raw string) (*idjManifest, error) {
	m := &idjManifest{entry: "main.js"}
	if strings.TrimSpace(raw) == "" {
		return m, nil
	}
	var doc struct {
		ID           string   `json:"id"`
		Name         string   `json:"name"`
		Version      string   `json:"version"`
		Entry        string   `json:"entry"`
		Type         string   `json:"type"`
		Capabilities []string `json:"capabilities"`
		Permissions  *struct {
			HTTP         []string `json:"http"`
			HTTPDomains  []string `json:"httpDomains"`
			Media        []string `json:"media"`
			MediaDomains []string `json:"mediaDomains"`
			Cloudflare   bool     `json:"cloudflare"`
			Storage      bool     `json:"storage"`
			Login        bool     `json:"login"`
			Pan          bool     `json:"pan"`
		} `json:"permissions"`
		Integrity json.RawMessage `json:"integrity"`
	}
	if err := json.Unmarshal([]byte(raw), &doc); err != nil {
		return nil, idjErr("E_INTERNAL", "插件 manifest 不是合法 JSON："+err.Error())
	}
	m.id, m.name, m.version, m.typ = doc.ID, doc.Name, doc.Version, doc.Type
	if doc.Entry != "" {
		m.entry = doc.Entry
	}
	m.capabilities = doc.Capabilities
	if doc.Permissions != nil {
		p := &m.permissions
		p.present = true
		p.http = append(append([]string{}, doc.Permissions.HTTP...), doc.Permissions.HTTPDomains...)
		p.media = append(append([]string{}, doc.Permissions.Media...), doc.Permissions.MediaDomains...)
		p.cloudflare, p.storage, p.login = doc.Permissions.Cloudflare, doc.Permissions.Storage, doc.Permissions.Login
		p.pan = doc.Permissions.Pan
	}
	// integrity 两种形态都接受（Android 宽松口径）：扁平字符串
	// "sha256-…" 或对象 {"files": {"main.js": "sha256-…"}}。
	if len(doc.Integrity) > 0 {
		var flat string
		if err := json.Unmarshal(doc.Integrity, &flat); err == nil {
			m.integrity = strings.TrimPrefix(flat, "sha256-")
			m.integrityEntry = m.entry
		} else {
			var obj struct {
				Files map[string]string `json:"files"`
			}
			if err := json.Unmarshal(doc.Integrity, &obj); err == nil {
				if v, ok := obj.Files[m.entry]; ok {
					m.integrity = strings.TrimPrefix(v, "sha256-")
					m.integrityEntry = m.entry
				}
			}
		}
	}
	return m, nil
}

// idjVerifyIntegrity 运行期加载前重算一次文件哈希：manifest 声明了
// integrity 才核对；值不对就拒绝加载（安装时同一规则，见设计 §1.4）。
func idjVerifyIntegrity(script string, m *idjManifest) error {
	if m.integrity == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(script))
	if base64.StdEncoding.EncodeToString(sum[:]) != m.integrity {
		return idjErr("E_INTERNAL", "文件哈希与 manifest 不一致，已拒绝加载")
	}
	return nil
}

// storageAllowed：permissions 一节缺失时放行（合成测试 manifest 常不写
// permissions）；写了 permissions 的按 storage 字段执行。
func (m *idjManifest) storageAllowed() bool {
	if !m.permissions.present {
		return true
	}
	return m.permissions.storage
}

// ---------------------------------------------------------------------------
// 域名白名单与本机/内网拦截
// ---------------------------------------------------------------------------

// idjDomainMatches 是 DomainPolicy 的语义（repo 源码 DomainRule）：
// 精确域名全等，或 "*.example.com" 匹配本域与任意层级的子域。
func idjDomainMatches(rule, host string) bool {
	rule = strings.ToLower(strings.TrimSpace(rule))
	host = strings.ToLower(strings.TrimSpace(host))
	if strings.HasPrefix(rule, "*.") {
		suffix := rule[2:]
		if host == suffix {
			return true
		}
		return strings.HasSuffix(host, "."+suffix)
	}
	return host == rule
}

func idjHostAllowed(host string, domains []string) bool {
	for _, rule := range domains {
		if idjDomainMatches(rule, host) {
			return true
		}
	}
	return false
}

// idjIsBlockedHost 本机/内网字面量判定（只看字面量，不做 DNS 解析，
// 与 iDuanJu 的 resolvesToBlocked 差一层：DNS 解析到内网地址的域名
// 本版不拦截，见回报里的缺口说明）。
func idjIsBlockedHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return true
	}
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return true
	}
	return false
}

// idjCheckURL 校验一次请求地址：只许 http/https、无 userinfo、
// 非本机/内网/IP 字面量、落在 manifest.permissions.http 白名单内。
// 跳转落点每跳都调它。白名单外返回 E_PERMISSION（绝不静默回空串）。
func idjCheckURL(m *idjManifest, rawURL string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u == nil || u.Host == "" {
		return nil, idjErr("E_PERMISSION", "地址无效")
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil, idjErr("E_PERMISSION", "只允许 http/https："+truncate(rawURL, 80))
	}
	if u.User != nil {
		return nil, idjErr("E_PERMISSION", "网址不可携带凭证")
	}
	host := strings.ToLower(u.Hostname())
	if idjAllowLoopback && isLoopbackHost(host) {
		return u, nil
	}
	if idjIsBlockedHost(host) {
		return nil, idjErr("E_PERMISSION", "不允许访问本机/内网地址："+host)
	}
	if !idjHostAllowed(host, m.permissions.http) {
		return nil, idjErr("E_PERMISSION", "域名未授权："+host)
	}
	return u, nil
}

func isLoopbackHost(host string) bool {
	if host == "localhost" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

// ---------------------------------------------------------------------------
// 限额：单次调用 60 次、每分钟 120 次滑动窗口（每插件）
// ---------------------------------------------------------------------------

var (
	idjRateMu      sync.Mutex
	idjRateWindows = map[string][]time.Time{}
)

func idjRateCheck(pluginID, pluginName string, callCount *int) error {
	*callCount++
	if *callCount > idjMaxRequestsPerCall {
		return idjErrf("E_RATE_LIMIT", "插件 %s 本次调用已发 %d 次请求，超过 60 次上限", pluginName, *callCount)
	}
	now := time.Now()
	idjRateMu.Lock()
	defer idjRateMu.Unlock()
	window := idjRateWindows[pluginID]
	kept := window[:0]
	for _, t := range window {
		if now.Sub(t) < time.Minute {
			kept = append(kept, t)
		}
	}
	if len(kept) >= idjMaxRequestsPerMinute {
		idjRateWindows[pluginID] = kept
		return idjErrf("E_RATE_LIMIT", "插件 %s 一分钟内已发 %d 次请求，超过 120 次上限", pluginName, len(kept))
	}
	idjRateWindows[pluginID] = append(kept, now)
	return nil
}

// ---------------------------------------------------------------------------
// 每插件文件锁：storage.json / cookies.json 的读写按 pluginID 加锁
// ---------------------------------------------------------------------------

var (
	idjFileMu    sync.Mutex
	idjFileLocks = map[string]*sync.Mutex{}
)

func idjFileLock(pluginID string) *sync.Mutex {
	idjFileMu.Lock()
	defer idjFileMu.Unlock()
	mu, ok := idjFileLocks[pluginID]
	if !ok {
		mu = &sync.Mutex{}
		idjFileLocks[pluginID] = mu
	}
	return mu
}

// idjPluginDir 拼运行态目录 engine.directory/idj/<pluginID>。
// pluginID 只许反向域名形态的字符，防 "../" 逃出 idj 目录。
func idjPluginDir(engineDir, pluginID string) (string, error) {
	if pluginID == "" {
		return "", idjErr("E_INTERNAL", "插件 id 为空")
	}
	for _, r := range pluginID {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '-' || r == '_') {
			return "", idjErr("E_INTERNAL", "插件 id 不合法："+pluginID)
		}
	}
	if pluginID == "." || pluginID == ".." || strings.Contains(pluginID, "..") {
		return "", idjErr("E_INTERNAL", "插件 id 不合法："+pluginID)
	}
	return filepath.Join(engineDir, "idj", pluginID), nil
}

// ---------------------------------------------------------------------------
// storage.json：整包 map[string]string，set 即写盘，1MB 上限写入前算字节
// ---------------------------------------------------------------------------

func idjStoragePath(dir string) string { return filepath.Join(dir, "storage.json") }

func idjLoadStorage(dir string) map[string]string {
	data, err := os.ReadFile(idjStoragePath(dir))
	if err != nil || len(data) == 0 {
		return map[string]string{}
	}
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil || m == nil {
		return map[string]string{}
	}
	return m
}

// idjSaveStorage 写入前算字节，超 1MB 拒绝并回滚（原文件不动）。
func idjSaveStorage(dir string, m map[string]string) error {
	data, err := json.Marshal(m)
	if err != nil {
		return idjErr("E_INTERNAL", "插件存储序列化失败："+err.Error())
	}
	if len(data) > idjStorageLimit() {
		return idjErr("E_STORAGE_FULL", "插件存储超过 1MB")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return idjErr("E_INTERNAL", "插件存储目录创建失败："+err.Error())
	}
	tmp := idjStoragePath(dir) + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return idjErr("E_INTERNAL", "插件存储写入失败："+err.Error())
	}
	if err := os.Rename(tmp, idjStoragePath(dir)); err != nil {
		_ = os.Remove(tmp)
		return idjErr("E_INTERNAL", "插件存储写入失败："+err.Error())
	}
	return nil
}

// ---------------------------------------------------------------------------
// cookies.json：[{name,value,domain,path,expires,secure,httpOnly}]
// ---------------------------------------------------------------------------

type idjCookieRecord struct {
	Name     string `json:"name"`
	Value    string `json:"value"`
	Domain   string `json:"domain"`
	Path     string `json:"path"`
	Expires  string `json:"expires,omitempty"`
	Secure   bool   `json:"secure,omitempty"`
	HTTPOnly bool   `json:"httpOnly,omitempty"`
}

func idjCookiesPath(dir string) string { return filepath.Join(dir, "cookies.json") }

func idjLoadCookies(dir string) []idjCookieRecord {
	data, err := os.ReadFile(idjCookiesPath(dir))
	if err != nil || len(data) == 0 {
		return nil
	}
	var list []idjCookieRecord
	if err := json.Unmarshal(data, &list); err != nil {
		return nil
	}
	now := time.Now()
	kept := list[:0]
	for _, c := range list {
		if c.Name == "" || c.Domain == "" {
			continue
		}
		if c.Expires != "" {
			if exp, err := time.Parse(time.RFC3339, c.Expires); err == nil && !exp.IsZero() && exp.Before(now) {
				continue
			}
		}
		kept = append(kept, c)
	}
	return kept
}

func idjCookieKey(c idjCookieRecord) string {
	return c.Name + "|" + strings.ToLower(c.Domain) + "|" + c.Path
}

// ---------------------------------------------------------------------------
// 单次调用状态
// ---------------------------------------------------------------------------

// idjCallState 是一次 idjCall 的全部宿主状态：manifest、HTTP client +
// 每插件独立 Cookie 罐、html 会话、请求计数。runtime 每次调用新建，
// 状态不跨调用复用；跨调用的只有落盘的 storage.json 与 cookies.json。
type idjCallState struct {
	pluginID   string
	pluginName string
	manifest   *idjManifest
	dir        string
	rt         *goja.Runtime
	client     *http.Client
	jar        *cookiejar.Jar
	callCount  int
	visited    map[string]bool // 本次调用实际请求过的 host（Cookie 回存用）
	htmlDocs   map[int]*html.Node
	htmlNodes  int
	htmlNextID int
}

func idjPluginDisplayName(m *idjManifest, pluginID string) string {
	if m.name != "" {
		return m.name
	}
	return pluginID
}

func newIdjCallState(engineDir, pluginID string, m *idjManifest) (*idjCallState, error) {
	dir, err := idjPluginDir(engineDir, pluginID)
	if err != nil {
		return nil, err
	}
	jar, _ := cookiejar.New(nil)
	s := &idjCallState{
		pluginID:   pluginID,
		pluginName: idjPluginDisplayName(m, pluginID),
		manifest:   m,
		dir:        dir,
		jar:        jar,
		visited:    map[string]bool{},
		htmlDocs:   map[int]*html.Node{},
	}
	// 恢复 Cookie 罐：按域名逐个 SetCookies（cookiejar 没有内置序列化）。
	for _, rec := range idjLoadCookies(dir) {
		cookie := &http.Cookie{
			Name: rec.Name, Value: rec.Value, Domain: rec.Domain, Path: rec.Path,
			Secure: rec.Secure, HttpOnly: rec.HTTPOnly,
		}
		if cookie.Path == "" {
			cookie.Path = "/"
		}
		if rec.Expires != "" {
			if exp, err := time.Parse(time.RFC3339, rec.Expires); err == nil {
				cookie.Expires = exp
			}
		}
		scheme := "https"
		u := &url.URL{Scheme: scheme, Host: strings.TrimPrefix(rec.Domain, ".")}
		jar.SetCookies(u, []*http.Cookie{cookie})
	}
	client := jsSpiderHTTPClient()
	client.Timeout = 0 // 单请求超时改走每次请求的 context，不用 client 级超时
	client.Jar = jar
	client.CheckRedirect = s.checkRedirect
	s.client = client
	return s, nil
}

// checkRedirect：跳转落点每跳都查白名单与本机拦截；超 10 跳停下。
func (s *idjCallState) checkRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return idjErr("E_INTERNAL", "重定向次数过多")
	}
	if _, err := idjCheckURL(s.manifest, req.URL.String()); err != nil {
		return err
	}
	return nil
}

// saveCookies 调用结束时回存 Cookie 罐：对 manifest 各域名 + 本次实际
// 到访的 host 取 cookie，与盘上已存的按 (name, domain, path) 合并
// （罐里为准），过期丢弃、超 300 条截断。
func (s *idjCallState) saveCookies() {
	hosts := map[string]bool{}
	for _, d := range append(append([]string{}, s.manifest.permissions.http...), s.manifest.permissions.media...) {
		hosts[strings.TrimPrefix(strings.ToLower(strings.TrimSpace(d)), "*.")] = true
	}
	for h := range s.visited {
		hosts[h] = true
	}
	merged := map[string]idjCookieRecord{}
	for _, rec := range idjLoadCookies(s.dir) {
		merged[idjCookieKey(rec)] = rec
	}
	for host := range hosts {
		if host == "" {
			continue
		}
		u := &url.URL{Scheme: "https", Host: host}
		for _, c := range s.jar.Cookies(u) {
			rec := idjCookieRecord{Name: c.Name, Value: c.Value, Domain: c.Domain, Path: c.Path, Secure: c.Secure, HTTPOnly: c.HttpOnly}
			if rec.Domain == "" {
				rec.Domain = host
			}
			if rec.Path == "" {
				rec.Path = "/"
			}
			if !c.Expires.IsZero() {
				rec.Expires = c.Expires.UTC().Format(time.RFC3339)
			}
			merged[idjCookieKey(rec)] = rec
		}
	}
	list := make([]idjCookieRecord, 0, len(merged))
	now := time.Now()
	for _, rec := range merged {
		if rec.Expires != "" {
			if exp, err := time.Parse(time.RFC3339, rec.Expires); err == nil && !exp.IsZero() && exp.Before(now) {
				continue
			}
		}
		list = append(list, rec)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Domain != list[j].Domain {
			return list[i].Domain < list[j].Domain
		}
		if list[i].Name != list[j].Name {
			return list[i].Name < list[j].Name
		}
		return list[i].Path < list[j].Path
	})
	if len(list) > 300 {
		list = list[:300]
	}
	data, err := json.Marshal(list)
	if err != nil {
		return
	}
	mu := idjFileLock(s.pluginID)
	mu.Lock()
	defer mu.Unlock()
	_ = os.MkdirAll(s.dir, 0700)
	tmp := idjCookiesPath(s.dir) + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return
	}
	if err := os.Rename(tmp, idjCookiesPath(s.dir)); err != nil {
		_ = os.Remove(tmp)
	}
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

// idjCall 是 Dart 侧 _idjCall 调用的 Go 入口（经 nativeDispatch 的
// "idjCall" action）。目录取自已初始化的引擎；未初始化时报核心未就绪。
func idjCall(pluginID, script, manifestJSON, fn, argJSON string) (map[string]interface{}, error) {
	nativeState.Lock()
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil {
		return nil, idjErr("E_INTERNAL", "应用核心尚未就绪，请重新打开应用")
	}
	return idjCallWithDirectory(engine.directory, pluginID, script, manifestJSON, fn, argJSON)
}

// idjCallWithDirectory 是 idjCall 的可测形态：目录由调用方传入，
// 测试直接传 t.TempDir()，不碰全局引擎。
func idjCallWithDirectory(directory, pluginID, script, manifestJSON, fn, argJSON string) (map[string]interface{}, error) {
	if strings.TrimSpace(pluginID) == "" {
		return nil, idjErr("E_INTERNAL", "插件 id 为空")
	}
	if strings.TrimSpace(script) == "" {
		return nil, idjErr("E_INTERNAL", "插件脚本为空")
	}
	manifest, err := idjParseManifest(manifestJSON)
	if err != nil {
		return nil, err
	}
	if err := idjVerifyIntegrity(script, manifest); err != nil {
		return nil, err
	}
	budget := idjCallTimeout
	switch fn {
	case "__probe":
		budget = idjInitTimeout
	case "__has":
		budget = idjHasTimeout
	case "player", "play":
		budget = idjPlayTimeout
	}
	state, err := newIdjCallState(directory, pluginID, manifest)
	if err != nil {
		return nil, err
	}
	// 超时模型（iDuanJu 同款）：goja 没有中断钩子，超时即废弃整个
	// runtime（每次调用新建，已天然满足），在途请求靠单请求超时自行结束。
	// JS 调用跑在独立 goroutine 里，外层只等结果或预算到期。
	type idjResult struct {
		out map[string]interface{}
		err error
	}
	done := make(chan idjResult, 1)
	go func() {
		out, err := idjRun(state, script, fn, argJSON)
		done <- idjResult{out: out, err: err}
	}()
	var res idjResult
	select {
	case res = <-done:
	case <-time.After(budget):
		res = idjResult{err: idjErrf("E_TIMEOUT", "插件 %s 调用 %s 超时（%d 秒）", state.pluginName, fn, int(budget.Seconds()))}
	}
	// 每次调用结束都回存 Cookie 罐（成功、插件报错、超时都存；
	// cookiejar 自带锁，超时后在途 goroutine 仍在用罐也安全）。
	state.saveCookies()
	if res.err != nil {
		return nil, res.err
	}
	return res.out, nil
}

// idjLoadScript 加载器：先走共享的 jsStripModuleSyntax，再行级兜底
// （探针 §4.3 方案 A）：hadDefault 为 false 且原文含顶层 export default
// 时，逐行把 "export default " 开头的行改写成 "module.exports = …"。
// 共享剥离器不识别正则字面量，4 个真插件里 3 个靠这步才能加载；
// 兜底只落在 idj 加载器里，现有 JS 蜘蛛零风险。
func idjLoadScript(rt *goja.Runtime, script string) error {
	stripped := jsStripModuleSyntax(script)
	patched := stripped.script
	if !stripped.hadDefault && strings.Contains(script, "export default") {
		lines := strings.Split(patched, "\n")
		for i, ln := range lines {
			trimmed := strings.TrimSpace(ln)
			if strings.HasPrefix(trimmed, "export default ") || strings.HasPrefix(trimmed, "export default\t") {
				lines[i] = "module.exports =" + trimmed[len("export default"):]
			}
		}
		patched = strings.Join(lines, "\n")
	}
	_, err := rt.RunString(patched)
	return err
}

// idjRun 在一个新建的 runtime 里跑完一次调用：装 host → 加载脚本 →
// 找函数 → 单对象参数调用 → 结算 Promise → 导出结果。
func idjRun(s *idjCallState, script, fn, argJSON string) (map[string]interface{}, error) {
	rt := goja.New()
	s.rt = rt
	if err := idjInstallHost(s, rt); err != nil {
		return nil, err
	}
	if err := idjLoadScript(rt, script); err != nil {
		return nil, idjErr("E_INTERNAL", "加载插件脚本失败："+err.Error())
	}
	switch fn {
	case "__probe":
		return s.idjProbe(rt)
	case "__has":
		return s.idjHas(rt, argJSON)
	}
	resolved := fn
	if resolved == "player" {
		resolved = "play"
	}
	target, found := jsFindFunction(rt, resolved)
	if !found {
		return nil, idjErr("E_UNSUPPORTED", "插件没有提供函数 "+fn)
	}
	arg, err := idjParseArg(rt, argJSON, resolved)
	if err != nil {
		return nil, err
	}
	out, err := target(goja.Undefined(), arg)
	if err != nil {
		return nil, idjErrorFromGoErr(rt, err)
	}
	decoded, err := idjAwait(rt, out)
	if err != nil {
		return nil, err
	}
	return idjWrapResult(decoded), nil
}

// idjParseArg 解析单对象参数；play 做传参修复（设计 §3.6）：
// play({id: episodeId, episodeId, line})——把分集键同时填进 id 与
// episodeId，line 填 flag 显示名。不这样传橙果/爱果恒播第 1 集、
// 潮流丢线路选择。分集键优先取 episodeId，其次 playId（Dart 侧旧名），
// 再退回 id；line 优先取 line，其次 flag。
func idjParseArg(rt *goja.Runtime, argJSON, resolvedFn string) (goja.Value, error) {
	var argMap map[string]interface{}
	if strings.TrimSpace(argJSON) != "" {
		var anyArg interface{}
		if err := json.Unmarshal([]byte(argJSON), &anyArg); err != nil {
			return nil, idjErr("E_ARGS", "插件参数不是合法 JSON："+err.Error())
		}
		if m, ok := anyArg.(map[string]interface{}); ok {
			argMap = m
		} else if anyArg != nil {
			return rt.ToValue(anyArg), nil
		}
	}
	if argMap == nil {
		argMap = map[string]interface{}{}
	}
	if resolvedFn == "play" {
		episodeID := firstNonEmptyString(argMap["episodeId"], argMap["playId"], argMap["id"])
		line := firstNonEmptyString(argMap["line"], argMap["flag"])
		if episodeID != "" {
			argMap["id"] = episodeID
			argMap["episodeId"] = episodeID
		}
		if line != "" {
			argMap["line"] = line
		}
	}
	return rt.ToValue(argMap), nil
}

func firstNonEmptyString(values ...interface{}) string {
	for _, v := range values {
		switch n := v.(type) {
		case string:
			if strings.TrimSpace(n) != "" {
				return n
			}
		case float64:
			return strconv.FormatFloat(n, 'f', -1, 64)
		case float32:
			return strconv.FormatFloat(float64(n), 'f', -1, 32)
		case int:
			return strconv.Itoa(n)
		case int64:
			return strconv.FormatInt(n, 10)
		case json.Number:
			return n.String()
		}
	}
	return ""
}

// idjProbe：probe 试加载（安装链用）。插件导出 init 时调一次 init({})，
// 再检查 manifest.capabilities 声明的能力函数是否齐全；缺失的记为
// probe 失败，报错写明缺哪个函数。不联网取站方数据。
func (s *idjCallState) idjProbe(rt *goja.Runtime) (map[string]interface{}, error) {
	if initFn, found := jsFindFunction(rt, "init"); found {
		out, err := initFn(goja.Undefined(), rt.ToValue(map[string]interface{}{}))
		if err != nil {
			return nil, idjErrorFromGoErr(rt, err)
		}
		if _, err := idjAwait(rt, out); err != nil {
			return nil, err
		}
	}
	required := s.manifest.capabilities
	if len(required) == 0 {
		required = []string{"home", "category", "search", "detail", "play"}
	}
	foundList := []string{}
	missing := []string{}
	for _, name := range required {
		if _, ok := jsFindFunction(rt, name); ok {
			foundList = append(foundList, name)
		} else {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return nil, idjErr("E_INTERNAL", "插件缺少函数："+strings.Join(missing, "、"))
	}
	return map[string]interface{}{"ok": true, "found": foundList, "plugin": s.pluginID}, nil
}

// idjHas：has(fn) 探查，参数 {"fn": "home"}，返回 {"has": bool}。
func (s *idjCallState) idjHas(rt *goja.Runtime, argJSON string) (map[string]interface{}, error) {
	name := ""
	if strings.TrimSpace(argJSON) != "" {
		var m map[string]interface{}
		if err := json.Unmarshal([]byte(argJSON), &m); err == nil {
			name, _ = m["fn"].(string)
		}
	}
	_, found := jsFindFunction(rt, name)
	return map[string]interface{}{"has": found}, nil
}

// idjAwait 结算 async 函数的返回值（机制 A，探针已证实）：
// 同步 resolve 的 Promise 在顶层调用返回时已结算；pending 才泵一次
// 空的顶层 RunString("0;")；rejected 把带码错误还原出来。
func idjAwait(rt *goja.Runtime, out goja.Value) (interface{}, error) {
	if out == nil || goja.IsUndefined(out) || goja.IsNull(out) {
		return nil, nil
	}
	if p, ok := out.Export().(*goja.Promise); ok {
		if p.State() == goja.PromiseStatePending {
			if _, err := rt.RunString("0;"); err != nil {
				return nil, idjErr("E_INTERNAL", "结算插件 Promise 失败："+err.Error())
			}
		}
		switch p.State() {
		case goja.PromiseStateFulfilled:
			return idjExportResult(rt, p.Result())
		case goja.PromiseStateRejected:
			return nil, idjErrorFromValue(rt, p.Result())
		default:
			return nil, idjErr("E_TIMEOUT", "插件调用未在预算内结算")
		}
	}
	return idjExportResult(rt, out)
}

func idjExportResult(rt *goja.Runtime, v goja.Value) (interface{}, error) {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil, nil
	}
	return jsExportValue(rt, v)
}

func idjWrapResult(decoded interface{}) map[string]interface{} {
	if decoded == nil {
		return map[string]interface{}{}
	}
	if m, ok := decoded.(map[string]interface{}); ok {
		return m
	}
	if list, ok := decoded.([]interface{}); ok {
		return map[string]interface{}{"list": list}
	}
	return map[string]interface{}{"result": decoded}
}

// ---------------------------------------------------------------------------
// host 桥：Go 回调直接挂成 host.* 的方法，再用一段自写的小 prelude
// 把 host 与 console 冻住。iDuanJu 用 __host JSON 桥，本树不用那套：
// 直接绑 Go 回调更简单，且不复制 PluginPrelude 的字符串。
// ---------------------------------------------------------------------------

// idjFreezePrelude 冻结 host 与 console（自写，约 15 行）：
// 深冻 host 整棵对象树；globalThis 上的 host/console 改为不可写、
// 不可配置，插件改不掉宿主入口。
const idjFreezePrelude = `(function () {
  'use strict';
  var freezeDeep = function (o) {
    if (o && (typeof o === 'object' || typeof o === 'function')) {
      var keys = Object.getOwnPropertyNames(o);
      for (var i = 0; i < keys.length; i++) {
        var v = o[keys[i]];
        if (v && (typeof v === 'object' || typeof v === 'function')) { freezeDeep(v); }
      }
      Object.freeze(o);
    }
    return o;
  };
  freezeDeep(host);
  freezeDeep(console);
  Object.defineProperty(globalThis, 'host', { value: host, writable: false, configurable: false });
  Object.defineProperty(globalThis, 'console', { value: console, writable: false, configurable: false });
})();`

func idjInstallHost(s *idjCallState, rt *goja.Runtime) error {
	// Node/CommonJS 形态：module.exports 与 exports 预定义（照
	// app_js_spider.go runtime() 的做法），export default 由加载器转过去。
	moduleObj := rt.NewObject()
	exportsObj := rt.NewObject()
	_ = moduleObj.Set("exports", exportsObj)
	rt.Set("module", moduleObj)
	rt.Set("exports", exportsObj)
	rt.Set("global", rt.GlobalObject())

	hostObj := rt.NewObject()
	// version 必须用纯 goja 对象建：Go map 转过去是宿主对象，
	// Object.freeze 会报 "Host object field … cannot be made read-only"。
	versionObj := rt.NewObject()
	_ = versionObj.Set("app", idjVersionApp)
	_ = versionObj.Set("spec", idjVersionSpec)
	_ = hostObj.Set("version", versionObj)
	_ = hostObj.Set("has", s.hostHasFunc(rt))
	_ = hostObj.Set("error", s.hostErrorFunc(rt))
	_ = hostObj.Set("log", s.hostLogFunc(rt))
	_ = hostObj.Set("settings", rt.NewObject())
	_ = hostObj.Set("storage", s.hostStorageObject(rt))
	_ = hostObj.Set("http", s.hostHTTPObject(rt))
	_ = hostObj.Set("html", s.hostHTMLObject(rt))
	_ = hostObj.Set("crypto", s.hostCryptoObject(rt))
	_ = hostObj.Set("codec", s.hostCodecObject(rt))
	_ = hostObj.Set("m3u8", s.hostM3U8Object(rt))
	_ = hostObj.Set("url", s.hostURLObject(rt))
	// WebHome 接口面对照补宿主（app_js_idj_webhome.go）：res 资源代理、
	// pan 网盘验活入口、history 本站观看、site/config/device 上下文。
	// 全部只新增注册项，不改既有方法行为。
	_ = hostObj.Set("res", s.hostResFunc(rt))
	_ = hostObj.Set("pan", s.hostPanObject(rt))
	_ = hostObj.Set("history", s.hostHistoryObject(rt))
	_ = hostObj.Set("site", s.hostSiteFunc(rt))
	_ = hostObj.Set("config", s.hostConfigFunc(rt))
	_ = hostObj.Set("device", s.hostDeviceFunc(rt))
	rt.Set("host", hostObj)

	consoleObj := rt.NewObject()
	logFn := s.hostLogFunc(rt)
	_ = consoleObj.Set("log", logFn)
	_ = consoleObj.Set("info", logFn)
	_ = consoleObj.Set("warn", logFn)
	_ = consoleObj.Set("error", logFn)
	rt.Set("console", consoleObj)

	if _, err := rt.RunString(idjFreezePrelude); err != nil {
		return idjErr("E_INTERNAL", "安装 host 桥失败："+err.Error())
	}
	return nil
}

// idjHostCaps 是 host.has 诚实返回的能力表：只含本版真正实现的，
// 未实现的 image.stripes / image.aes 返回 false（iDuanJu Android
// 也没有这两项，4 个插件没用到，本版不做）。
var idjHostCaps = map[string]bool{
	"http": true, "html": true,
	"crypto.hash": true, "crypto.hmac": true, "crypto.aes": true, "crypto.rsa": true,
	"codec": true, "m3u8": true, "storage": true, "settings": true, "url": true,
	"log": true, "error": true, "version": true, "has": true,
	"http.request": true, "http.get": true, "http.post": true, "http.allowed": true,
	"crypto.md5": true, "crypto.sha1": true, "crypto.sha256": true, "crypto.sha512": true,
	"crypto.random": true, "codec.base64": true, "codec.gunzip": true, "codec.unpack": true,
	"m3u8.parse": true, "html.parse": true, "url.resolve": true, "storage.get": true,
	"image.stripes": false, "image.aes": false,
	// WebHome 对照补宿主（app_js_idj_webhome.go）。pan.check 的方法面
	// 已注册，但检测后端未接线时调用会明确 reject E_UNSUPPORTED。
	"res": true, "pan": true, "pan.check": true,
	"history": true, "history.list": true,
	"site": true, "config": true, "device": true,
}

func (s *idjCallState) hostHasFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		cap := ""
		if len(call.Arguments) > 0 {
			cap = jsValueString(call.Arguments[0])
		}
		return rt.ToValue(idjHostCaps[cap])
	}
}

func (s *idjCallState) hostErrorFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		code, msg := "", ""
		if len(call.Arguments) > 0 {
			code = jsValueString(call.Arguments[0])
		}
		if len(call.Arguments) > 1 {
			msg = jsValueString(call.Arguments[1])
		}
		if msg == "" {
			msg = code
		}
		return idjErrorObject(rt, code, msg)
	}
}

func (s *idjCallState) hostLogFunc(rt *goja.Runtime) func(goja.FunctionCall) goja.Value {
	return func(call goja.FunctionCall) goja.Value {
		parts := make([]string, 0, len(call.Arguments))
		for _, arg := range call.Arguments {
			if arg == nil || goja.IsUndefined(arg) || goja.IsNull(arg) {
				parts = append(parts, "")
				continue
			}
			if exported := arg.Export(); exported != nil {
				if text, ok := exported.(string); ok {
					parts = append(parts, text)
					continue
				}
			}
			parts = append(parts, jsValueString(arg))
		}
		msg := strings.Join(parts, " ")
		if len(msg) > 500 {
			msg = msg[:500]
		}
		log.Printf("[idj %s] %s", s.pluginID, msg)
		return goja.Undefined()
	}
}

// ---------------------------------------------------------------------------
// host.storage：同步调用（已从 plugin_js_analysis.md 核实：插件用法是
// 同步取值，Go 回调直接返回值；未存过的 key 返回 null；值以字符串存，
// 插件自己 JSON.stringify/parse；非字符串值存成 JSON 文本）。
// ---------------------------------------------------------------------------

func (s *idjCallState) hostStorageObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("get", func(call goja.FunctionCall) goja.Value {
		if !s.manifest.storageAllowed() {
			idjThrow(rt, "E_PERMISSION", "插件没有声明 storage 权限")
		}
		if len(call.Arguments) == 0 {
			return goja.Null()
		}
		key := jsValueString(call.Arguments[0])
		mu := idjFileLock(s.pluginID)
		mu.Lock()
		stored := idjLoadStorage(s.dir)
		mu.Unlock()
		if v, ok := stored[key]; ok {
			return rt.ToValue(v)
		}
		return goja.Null()
	})
	_ = obj.Set("set", func(call goja.FunctionCall) goja.Value {
		if !s.manifest.storageAllowed() {
			idjThrow(rt, "E_PERMISSION", "插件没有声明 storage 权限")
		}
		if len(call.Arguments) < 2 {
			return goja.Undefined()
		}
		key := jsValueString(call.Arguments[0])
		value := idjStorageValueString(call.Arguments[1])
		mu := idjFileLock(s.pluginID)
		mu.Lock()
		defer mu.Unlock()
		stored := idjLoadStorage(s.dir)
		stored[key] = value
		if err := idjSaveStorage(s.dir, stored); err != nil {
			// 超 1MB 拒绝并回滚：idjSaveStorage 在超限时根本不写盘，
			// 这里直接把带码错误抛给插件（try/catch 能接住）。
			if coded, ok := err.(*idjError); ok {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_INTERNAL", err.Error())
		}
		return goja.Undefined()
	})
	_ = obj.Set("remove", func(call goja.FunctionCall) goja.Value {
		if !s.manifest.storageAllowed() {
			idjThrow(rt, "E_PERMISSION", "插件没有声明 storage 权限")
		}
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		key := jsValueString(call.Arguments[0])
		mu := idjFileLock(s.pluginID)
		mu.Lock()
		defer mu.Unlock()
		stored := idjLoadStorage(s.dir)
		delete(stored, key)
		if err := idjSaveStorage(s.dir, stored); err != nil {
			if coded, ok := err.(*idjError); ok {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_INTERNAL", err.Error())
		}
		return goja.Undefined()
	})
	return obj
}

// idjStorageValueString：字符串原样存；其他 JSON 值编成 JSON 文本存
// （插件侧 JSON.parse 能还原；iDuanJu 存任意 JSON 值，本版以字符串
// 文件格式兼容它）。
func idjStorageValueString(v goja.Value) string {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return ""
	}
	if exported := v.Export(); exported != nil {
		if text, ok := exported.(string); ok {
			return text
		}
		if data, err := json.Marshal(exported); err == nil {
			return string(data)
		}
	}
	return jsValueString(v)
}

// ---------------------------------------------------------------------------
// host.http：request/get/post/allowed
// ---------------------------------------------------------------------------

// idjForbiddenHeaders 是禁发头精确 11 项：照抄
// PluginNet.swift:207-208 的清单，不许猜——唯独 `authorization` 不在内：
// 用户 2026-11-24 18:40 令宿主放行 Authorization 头（妻友社站方列表 / 详情 /
// 搜索 / 播放全要这个头，token 是插件自己游客登录拿到的，宿主只放行、不碰
// 别的鉴权逻辑）。其余 11 项（Cookie、Host、代理相关、连接控制类）照旧剥离。
var idjForbiddenHeaders = map[string]bool{
	"cookie": true, "cookie2": true, "host": true,
	"proxy-authorization": true, "connection": true, "content-length": true,
	"transfer-encoding": true, "te": true, "upgrade": true,
	"proxy-connection": true, "keep-alive": true,
}

// idjHTTPDefaultUA 是无 UA 时的默认请求头（iDuanJu 的 iPhone Safari；
// 4 个插件自己都带 UA，基本走不到这行）。
const idjHTTPDefaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

func (s *idjCallState) hostHTTPObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("request", func(call goja.FunctionCall) goja.Value {
		return s.httpRequestValue(rt, call)
	})
	_ = obj.Set("get", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return s.httpPromiseReject(rt, idjErr("E_PERMISSION", "地址无效"))
		}
		urlText := jsValueString(call.Arguments[0])
		opts := idjExportMap(call, 1)
		return s.httpDoPromise(rt, urlText, "GET", "", opts)
	})
	_ = obj.Set("post", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return s.httpPromiseReject(rt, idjErr("E_PERMISSION", "地址无效"))
		}
		urlText := jsValueString(call.Arguments[0])
		body := ""
		if len(call.Arguments) > 1 {
			body = idjStorageValueString(call.Arguments[1])
		}
		opts := idjExportMap(call, 2)
		return s.httpDoPromise(rt, urlText, "POST", body, opts)
	})
	_ = obj.Set("allowed", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue(false)
		}
		_, err := idjCheckURL(s.manifest, jsValueString(call.Arguments[0]))
		return rt.ToValue(err == nil)
	})
	return obj
}

func idjExportMap(call goja.FunctionCall, idx int) map[string]interface{} {
	if len(call.Arguments) <= idx {
		return nil
	}
	if exported := call.Arguments[idx].Export(); exported != nil {
		if m, ok := exported.(map[string]interface{}); ok {
			return m
		}
	}
	return nil
}

// httpRequestValue 是 host.http.request 的 Go 回调：返回 Promise，
// 回调内同步发完请求再 resolve/reject（机制 A，探针已证实）。
func (s *idjCallState) httpRequestValue(rt *goja.Runtime, call goja.FunctionCall) goja.Value {
	req := jsFetchParseArgs(call)
	timeoutMS := idjRequestTimeoutMS(call)
	opts := idjExportMap(call, 0)
	return s.httpDoPromise(rt, req.url, req.method, req.body, mergeHTTPOpts(opts, req.headers, timeoutMS))
}

func mergeHTTPOpts(opts map[string]interface{}, headers map[string]string, timeoutMS int) map[string]interface{} {
	out := map[string]interface{}{}
	for k, v := range opts {
		out[k] = v
	}
	if headers != nil {
		out["__headers"] = headers
	}
	if timeoutMS > 0 {
		out["timeout"] = timeoutMS
	}
	return out
}

// idjRequestTimeoutMS 从 request 参数里取 timeout（毫秒）。
func idjRequestTimeoutMS(call goja.FunctionCall) int {
	for i := 0; i < len(call.Arguments) && i < 2; i++ {
		if m := idjExportMap(call, i); m != nil {
			if v, ok := m["timeout"]; ok {
				return idjTimeoutToMS(v)
			}
		}
	}
	return 0
}

func idjTimeoutToMS(v interface{}) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int64:
		return int(n)
	case int:
		return n
	case json.Number:
		if f, err := n.Float64(); err == nil {
			return int(f)
		}
	case string:
		if f, err := strconv.ParseFloat(strings.TrimSpace(n), 64); err == nil {
			return int(f)
		}
	}
	return 0
}

// httpDoPromise 发一次请求并包成 Promise：成功 resolve 响应对象，
// 失败 reject 带码错误对象。
//
// WebHome 对照扩展（只加不改）：opts.responseType 取
// 'text'（默认）|'json'|'base64'，决定 body 的形态——json 由宿主解析
// 成 JS 值（解析失败 reject E_PARSE），base64 返回原始字节的 Base64
// 文本；响应对象新增 ok（status 是否 2xx）与 cookies（最终响应
// Set-Cookie 的 "name=value" 数组）。既有 status/url/headers/body
// （text 形态）语义不变，旧插件不受影响。
func (s *idjCallState) httpDoPromise(rt *goja.Runtime, urlText, method, body string, opts map[string]interface{}) goja.Value {
	promise, resolve, reject := rt.NewPromise()
	headers := map[string]string{}
	timeoutMS := 0
	responseType := "text"
	if opts != nil {
		if h, ok := opts["__headers"].(map[string]string); ok {
			headers = h
		}
		if h, ok := opts["headers"].(map[string]interface{}); ok {
			for k, v := range h {
				headers[k] = fmt.Sprint(v)
			}
		}
		timeoutMS = idjTimeoutToMS(opts["timeout"])
		if v, ok := opts["responseType"].(string); ok && strings.TrimSpace(v) != "" {
			responseType = strings.ToLower(strings.TrimSpace(v))
		}
	}
	if responseType != "text" && responseType != "json" && responseType != "base64" {
		_ = reject(idjErrorObject(rt, "E_ARGS", "responseType 只支持 text/json/base64"))
		return rt.ToValue(promise)
	}
	status, respHeaders, respBody, respCookies, finalURL, err := s.httpDo(urlText, method, body, headers, timeoutMS)
	if err != nil {
		var coded *idjError
		if errors.As(err, &coded) {
			_ = reject(idjErrorObject(rt, coded.code, coded.message))
		} else {
			_ = reject(idjErrorObject(rt, "E_INTERNAL", err.Error()))
		}
		return rt.ToValue(promise)
	}
	respObj := rt.NewObject()
	_ = respObj.Set("status", status)
	_ = respObj.Set("url", finalURL)
	_ = respObj.Set("headers", rt.ToValue(respHeaders))
	_ = respObj.Set("ok", status >= 200 && status < 300)
	_ = respObj.Set("cookies", rt.ToValue(respCookies))
	switch responseType {
	case "base64":
		_ = respObj.Set("body", base64.StdEncoding.EncodeToString(respBody))
	case "json":
		var parsed interface{}
		if err := json.Unmarshal(respBody, &parsed); err != nil {
			_ = reject(idjErrorObject(rt, "E_PARSE", "响应不是合法 JSON："+err.Error()))
			return rt.ToValue(promise)
		}
		_ = respObj.Set("body", rt.ToValue(parsed))
	default:
		_ = respObj.Set("body", string(respBody))
	}
	_ = resolve(respObj)
	return rt.ToValue(promise)
}

func (s *idjCallState) httpPromiseReject(rt *goja.Runtime, err *idjError) goja.Value {
	promise, _, reject := rt.NewPromise()
	_ = reject(idjErrorObject(rt, err.code, err.message))
	return rt.ToValue(promise)
}

// httpDo 执行一次 host.http.request：白名单 → 限额 → 禁发头剥离 →
// 发请求 → CF 判定 → 20MB 上限 → 小写响应头。返回
// (status, headers, body, cookies, finalURL, err)；cookies 是
// WebHome 对照扩展新增的返回值（最终响应 Set-Cookie 的
// "name=value" 列表），其余行为不变。
func (s *idjCallState) httpDo(urlText, method, body string, headers map[string]string, timeoutMS int) (int, map[string]string, []byte, []string, string, error) {
	if strings.TrimSpace(urlText) == "" {
		return 0, nil, nil, nil, "", idjErr("E_PERMISSION", "地址无效")
	}
	if method == "" {
		method = "GET"
	}
	method = strings.ToUpper(method)
	u, err := idjCheckURL(s.manifest, urlText)
	if err != nil {
		return 0, nil, nil, nil, "", err
	}
	if err := idjRateCheck(s.pluginID, s.pluginName, &s.callCount); err != nil {
		return 0, nil, nil, nil, "", err
	}
	if timeoutMS <= 0 {
		timeoutMS = idjDefaultRequestTimeoutMS
	}
	if timeoutMS < 1000 {
		timeoutMS = 1000
	}
	if timeoutMS > 60000 {
		timeoutMS = 60000
	}
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	httpReq, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return 0, nil, nil, nil, "", idjErr("E_NETWORK", "创建请求失败："+err.Error())
	}
	s.visited[strings.ToLower(u.Hostname())] = true
	httpReq.Header.Set("User-Agent", idjHTTPDefaultUA)
	httpReq.Header.Set("Accept", "*/*")
	for k, v := range headers {
		if idjForbiddenHeaders[strings.ToLower(strings.TrimSpace(k))] {
			continue
		}
		httpReq.Header.Set(k, v)
	}
	resp, err := s.client.Do(httpReq)
	if err != nil {
		var coded *idjError
		if errors.As(err, &coded) {
			return 0, nil, nil, nil, "", coded
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return 0, nil, nil, nil, "", idjErr("E_TIMEOUT", "请求超时（"+strconv.Itoa(timeoutMS)+" 毫秒）")
		}
		var urlErr *url.Error
		if errors.As(err, &urlErr) && urlErr.Timeout() {
			return 0, nil, nil, nil, "", idjErr("E_TIMEOUT", "请求超时（"+strconv.Itoa(timeoutMS)+" 毫秒）")
		}
		return 0, nil, nil, nil, "", idjErr("E_NETWORK", "请求失败："+err.Error())
	}
	defer resp.Body.Close()
	// CF 判定（只认 403 + cf-mitigated: challenge，与
	// network_browser.go 的 browserChallengeStatus /
	// isCFMitigatedChallenge 同一规则，v1 只报 E_CF_REQUIRED，不解盾）。
	if browserChallengeStatus(resp) && isCFMitigatedChallenge(resp) {
		return 0, nil, nil, nil, "", idjErr("E_CF_REQUIRED", "站方返回 Cloudflare 验证页")
	}
	limit := idjBodyLimit()
	data, err := io.ReadAll(io.LimitReader(resp.Body, int64(limit)+1))
	if err != nil {
		return 0, nil, nil, nil, "", idjErr("E_NETWORK", "读取响应失败："+err.Error())
	}
	if len(data) > limit {
		return 0, nil, nil, nil, "", idjErr("E_INTERNAL", "响应体超过 20MB 上限")
	}
	lowerHeaders := map[string]string{}
	for k, values := range resp.Header {
		if len(values) > 0 {
			lowerHeaders[strings.ToLower(k)] = strings.Join(values, ", ")
		}
	}
	finalURL := u.String()
	if resp.Request != nil && resp.Request.URL != nil {
		finalURL = resp.Request.URL.String()
	}
	setCookies := []string{}
	for _, c := range resp.Cookies() {
		setCookies = append(setCookies, c.Name+"="+c.Value)
	}
	return resp.StatusCode, lowerHeaders, data, setCookies, finalURL, nil
}

// ---------------------------------------------------------------------------
// host.html.parse：复用 jsParseHTML / jsSelectAll。选择器是子集，只支持
// tag / .class / #id / [attr=val] / 后代 / > 子代 / 逗号分组，不支持
// 伪类、属性包含/开头匹配、:nth-child 等——不支持的写法返回空结果，
// 不静默编数据（缺口见设计 §2.4 与 adapt_plan R9）。
// ---------------------------------------------------------------------------

func (s *idjCallState) hostHTMLObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("parse", func(call goja.FunctionCall) goja.Value {
		text := ""
		if len(call.Arguments) > 0 {
			text = jsValueString(call.Arguments[0])
		}
		doc, err := jsParseHTML(text)
		if err != nil {
			idjThrow(rt, "E_PARSE", "解析 HTML 失败："+err.Error())
		}
		count := 0
		var walk func(*html.Node)
		walk = func(n *html.Node) {
			count++
			for child := n.FirstChild; child != nil; child = child.NextSibling {
				walk(child)
			}
		}
		walk(doc)
		s.htmlNodes += count
		if s.htmlNodes > idjMaxHTMLNodes {
			idjThrow(rt, "E_MEMORY", "HTML 节点数超过 300000 上限")
		}
		s.htmlNextID++
		id := s.htmlNextID
		s.htmlDocs[id] = doc
		return s.htmlNodeObject(rt, doc)
	})
	return obj
}

func (s *idjCallState) htmlNodeObject(rt *goja.Runtime, n *html.Node) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("text", func(goja.FunctionCall) goja.Value {
		return rt.ToValue(jsHTMLText(n))
	})
	_ = obj.Set("html", func(goja.FunctionCall) goja.Value {
		var buf bytes.Buffer
		for child := n.FirstChild; child != nil; child = child.NextSibling {
			_ = html.Render(&buf, child)
		}
		return rt.ToValue(buf.String())
	})
	_ = obj.Set("outerHtml", func(goja.FunctionCall) goja.Value {
		return rt.ToValue(jsHTMLOuter(n))
	})
	_ = obj.Set("attr", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		want := jsValueString(call.Arguments[0])
		for _, a := range n.Attr {
			if a.Key == want {
				return rt.ToValue(a.Val)
			}
		}
		return rt.ToValue("")
	})
	_ = obj.Set("select", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue([]interface{}{})
		}
		nodes := jsSelectAll(n, jsValueString(call.Arguments[0]))
		out := make([]interface{}, 0, len(nodes))
		for _, child := range nodes {
			out = append(out, s.htmlNodeObject(rt, child))
		}
		return rt.ToValue(out)
	})
	_ = obj.Set("selectFirst", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Null()
		}
		nodes := jsSelectAll(n, jsValueString(call.Arguments[0]))
		if len(nodes) == 0 {
			return goja.Null()
		}
		return s.htmlNodeObject(rt, nodes[0])
	})
	return obj
}

// ---------------------------------------------------------------------------
// host.crypto / host.codec：编解码约定与 iDuanJu 一致——
// decode 默认 utf8，encode 默认 hex；aes 加密默认 in=utf8/out=base64，
// 解密默认 in=base64/out=utf8；padding 默认 pkcs7，"none" 关掉。
// ---------------------------------------------------------------------------

func idjDecodeBytes(s, enc string) ([]byte, error) {
	switch strings.ToLower(strings.TrimSpace(enc)) {
	case "", "utf8", "text":
		return []byte(s), nil
	case "hex":
		b, err := hex.DecodeString(strings.TrimSpace(s))
		if err != nil {
			return nil, idjErr("E_INTERNAL", "hex 不合法")
		}
		return b, nil
	case "base64":
		t := strings.NewReplacer("-", "+", "_", "/").Replace(s)
		t = strings.Map(func(r rune) rune {
			if r == ' ' || r == '\t' || r == '\r' || r == '\n' {
				return -1
			}
			return r
		}, t)
		for len(t)%4 != 0 {
			t += "="
		}
		b, err := base64.StdEncoding.DecodeString(t)
		if err != nil {
			return nil, idjErr("E_INTERNAL", "base64 不合法")
		}
		return b, nil
	case "latin1":
		out := make([]byte, 0, len(s))
		for _, r := range s {
			out = append(out, byte(r))
		}
		return out, nil
	default:
		return nil, idjErr("E_INTERNAL", "不支持的编码 "+enc)
	}
}

func idjEncodeBytes(b []byte, enc string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(enc)) {
	case "", "hex":
		return hex.EncodeToString(b), nil
	case "base64":
		return base64.StdEncoding.EncodeToString(b), nil
	case "utf8", "text":
		return string(b), nil
	case "latin1":
		runes := make([]rune, len(b))
		for i, v := range b {
			runes[i] = rune(v)
		}
		return string(runes), nil
	default:
		return "", idjErr("E_INTERNAL", "不支持的编码 "+enc)
	}
}

func idjHashBytes(alg string, data []byte) ([]byte, error) {
	var h hash.Hash
	switch strings.ToLower(strings.TrimSpace(alg)) {
	case "md5":
		h = md5.New()
	case "sha1":
		h = sha1.New()
	case "sha256":
		h = sha256.New()
	case "sha384":
		h = sha512.New384()
	case "sha512":
		h = sha512.New()
	default:
		return nil, idjErr("E_INTERNAL", "不支持的哈希 "+alg)
	}
	_, _ = h.Write(data)
	return h.Sum(nil), nil
}

func idjHMACBytes(alg string, key, data []byte) ([]byte, error) {
	var h func() hash.Hash
	switch strings.ToLower(strings.TrimSpace(alg)) {
	case "md5":
		h = md5.New
	case "sha1":
		h = sha1.New
	case "sha256":
		h = sha256.New
	case "sha512":
		h = sha512.New
	default:
		return nil, idjErr("E_INTERNAL", "不支持的 HMAC "+alg)
	}
	mac := hmac.New(h, key)
	_, _ = mac.Write(data)
	return mac.Sum(nil), nil
}

// idjAESEncrypt / idjAESDecrypt：cbc/ecb/ctr/gcm。PKCS7 填充复用树里
// 已有的 pkcs7Pad/pkcs7Unpad（Go 标准库没有）；ECB 标准库没有，
// 按块手写；CTR 用 cipher.NewCTR（大端计数，与 iDuanJu 的 CTR_BE 一致）；
// GCM 数据形态是 ciphertext‖16 字节 tag。
func idjAESEncrypt(mode string, key, iv, data []byte, padding bool) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, idjErr("E_INTERNAL", "AES key 长度必须是 16/24/32 字节")
	}
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "gcm":
		if len(iv) != 12 {
			return nil, idjErr("E_INTERNAL", "GCM 需要 12 字节 iv")
		}
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			return nil, idjErr("E_INTERNAL", "AES-GCM 初始化失败："+err.Error())
		}
		return gcm.Seal(nil, iv, data, nil), nil
	case "ctr":
		if len(iv) != aes.BlockSize {
			return nil, idjErr("E_INTERNAL", "CTR 需要 16 字节 iv")
		}
		out := make([]byte, len(data))
		cipher.NewCTR(block, iv).XORKeyStream(out, data)
		return out, nil
	case "ecb":
		plain := data
		if padding {
			plain = pkcs7Pad(data, aes.BlockSize)
		} else if len(plain)%aes.BlockSize != 0 {
			return nil, idjErr("E_INTERNAL", "数据长度不是 16 的倍数（检查 padding）")
		}
		out := make([]byte, len(plain))
		for i := 0; i < len(plain); i += aes.BlockSize {
			block.Encrypt(out[i:i+aes.BlockSize], plain[i:i+aes.BlockSize])
		}
		return out, nil
	case "cbc", "":
		if len(iv) != aes.BlockSize {
			return nil, idjErr("E_INTERNAL", "CBC 需要 16 字节 iv")
		}
		plain := data
		if padding {
			plain = pkcs7Pad(data, aes.BlockSize)
		} else if len(plain)%aes.BlockSize != 0 {
			return nil, idjErr("E_INTERNAL", "数据长度不是 16 的倍数（检查 padding）")
		}
		out := make([]byte, len(plain))
		cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, plain)
		return out, nil
	default:
		return nil, idjErr("E_INTERNAL", "不支持的 AES 模式 "+mode)
	}
}

func idjAESDecrypt(mode string, key, iv, data []byte, padding bool) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, idjErr("E_INTERNAL", "AES key 长度必须是 16/24/32 字节")
	}
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "gcm":
		if len(iv) != 12 {
			return nil, idjErr("E_INTERNAL", "GCM 需要 12 字节 iv")
		}
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			return nil, idjErr("E_INTERNAL", "AES-GCM 初始化失败："+err.Error())
		}
		if len(data) < 16 {
			return nil, idjErr("E_INTERNAL", "GCM 数据太短")
		}
		plain, err := gcm.Open(nil, iv, data, nil)
		if err != nil {
			return nil, idjErr("E_INTERNAL", "AES-GCM 解密失败")
		}
		return plain, nil
	case "ctr":
		if len(iv) != aes.BlockSize {
			return nil, idjErr("E_INTERNAL", "CTR 需要 16 字节 iv")
		}
		out := make([]byte, len(data))
		cipher.NewCTR(block, iv).XORKeyStream(out, data)
		return out, nil
	case "ecb":
		if len(data)%aes.BlockSize != 0 {
			return nil, idjErr("E_INTERNAL", "数据长度不是 16 的倍数（检查 padding）")
		}
		out := make([]byte, len(data))
		for i := 0; i < len(data); i += aes.BlockSize {
			block.Decrypt(out[i:i+aes.BlockSize], data[i:i+aes.BlockSize])
		}
		if padding {
			return pkcs7UnpadToErr(out)
		}
		return out, nil
	case "cbc", "":
		if len(iv) != aes.BlockSize {
			return nil, idjErr("E_INTERNAL", "CBC 需要 16 字节 iv")
		}
		if len(data)%aes.BlockSize != 0 {
			return nil, idjErr("E_INTERNAL", "数据长度不是 16 的倍数（检查 padding）")
		}
		out := make([]byte, len(data))
		cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, data)
		if padding {
			return pkcs7UnpadToErr(out)
		}
		return out, nil
	default:
		return nil, idjErr("E_INTERNAL", "不支持的 AES 模式 "+mode)
	}
}

func pkcs7UnpadToErr(out []byte) ([]byte, error) {
	plain, err := pkcs7Unpad(out, aes.BlockSize)
	if err != nil {
		return nil, idjErr("E_INTERNAL", "AES 去填充失败："+err.Error())
	}
	return plain, nil
}

// idjParseRSAPublicKey 解析 PEM 公钥：BEGIN PUBLIC KEY 走 PKIX，
// BEGIN RSA PUBLIC KEY 走 PKCS#1，其余先试 PKIX 再试 PKCS#1。
func idjParseRSAPublicKey(pemText string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode([]byte(pemText))
	if block == nil {
		return nil, idjErr("E_INTERNAL", "RSA 公钥不是合法 PEM")
	}
	if pub, err := x509.ParsePKIXPublicKey(block.Bytes); err == nil {
		if rsaPub, ok := pub.(*rsa.PublicKey); ok {
			return rsaPub, nil
		}
		return nil, idjErr("E_INTERNAL", "RSA 公钥不是 RSA 密钥")
	}
	if rsaPub, err := x509.ParsePKCS1PublicKey(block.Bytes); err == nil {
		return rsaPub, nil
	}
	return nil, idjErr("E_INTERNAL", "RSA 公钥无法导入")
}

func idjCryptoValue(rt *goja.Runtime, fn func() (string, error)) goja.Value {
	out, err := fn()
	if err != nil {
		var coded *idjError
		if errors.As(err, &coded) {
			idjThrow(rt, coded.code, coded.message)
		}
		idjThrow(rt, "E_INTERNAL", err.Error())
	}
	return rt.ToValue(out)
}

func idjOptMap(call goja.FunctionCall, idx int) map[string]interface{} {
	if m := idjExportMap(call, idx); m != nil {
		return m
	}
	return map[string]interface{}{}
}

func idjOptString(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
			if v != nil {
				return fmt.Sprint(v)
			}
		}
	}
	return ""
}

func (s *idjCallState) hostCryptoObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	hashFn := func(alg string) func(goja.FunctionCall) goja.Value {
		return func(call goja.FunctionCall) goja.Value {
			return idjCryptoValue(rt, func() (string, error) {
				if len(call.Arguments) == 0 {
					return "", idjErr("E_INTERNAL", "缺少哈希输入")
				}
				opts := idjOptMap(call, 1)
				data, err := idjDecodeBytes(jsValueString(call.Arguments[0]), idjOptString(opts, "in"))
				if err != nil {
					return "", err
				}
				sum, err := idjHashBytes(alg, data)
				if err != nil {
					return "", err
				}
				return idjEncodeBytes(sum, idjOptString(opts, "out"))
			})
		}
	}
	_ = obj.Set("md5", hashFn("md5"))
	_ = obj.Set("sha1", hashFn("sha1"))
	_ = obj.Set("sha256", hashFn("sha256"))
	_ = obj.Set("sha512", hashFn("sha512"))
	_ = obj.Set("hmac", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) < 3 {
				return "", idjErr("E_INTERNAL", "hmac 需要 (alg, key, data)")
			}
			opts := idjOptMap(call, 3)
			key, err := idjDecodeBytes(jsValueString(call.Arguments[1]), idjOptString(opts, "keyEncoding"))
			if err != nil {
				return "", err
			}
			data, err := idjDecodeBytes(jsValueString(call.Arguments[2]), idjOptString(opts, "in"))
			if err != nil {
				return "", err
			}
			sum, err := idjHMACBytes(jsValueString(call.Arguments[0]), key, data)
			if err != nil {
				return "", err
			}
			return idjEncodeBytes(sum, idjOptString(opts, "out"))
		})
	})
	_ = obj.Set("aes", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			opts := idjOptMap(call, 0)
			encrypt := idjOptString(opts, "op") == "encrypt"
			keyEnc := idjOptString(opts, "keyEncoding")
			key, err := idjDecodeBytes(idjOptString(opts, "key"), keyEnc)
			if err != nil {
				return "", err
			}
			var iv []byte
			if raw := idjOptString(opts, "iv"); raw != "" {
				ivEnc := idjOptString(opts, "ivEncoding")
				if ivEnc == "" {
					ivEnc = keyEnc
				}
				iv, err = idjDecodeBytes(raw, ivEnc)
				if err != nil {
					return "", err
				}
			}
			inEnc := idjOptString(opts, "in")
			if inEnc == "" {
				if encrypt {
					inEnc = "utf8"
				} else {
					inEnc = "base64"
				}
			}
			data, err := idjDecodeBytes(idjOptString(opts, "data"), inEnc)
			if err != nil {
				return "", err
			}
			padding := idjOptString(opts, "padding") != "none"
			mode := idjOptString(opts, "mode")
			if mode == "" {
				mode = "cbc"
			}
			var out []byte
			if encrypt {
				out, err = idjAESEncrypt(mode, key, iv, data, padding)
			} else {
				out, err = idjAESDecrypt(mode, key, iv, data, padding)
			}
			if err != nil {
				return "", err
			}
			outEnc := idjOptString(opts, "out")
			if outEnc == "" {
				if encrypt {
					outEnc = "base64"
				} else {
					outEnc = "utf8"
				}
			}
			return idjEncodeBytes(out, outEnc)
		})
	})
	_ = obj.Set("rsa", func(call goja.FunctionCall) goja.Value {
		// verify 返回布尔值，encrypt 返回字符串，分开处理，不走
		// idjCryptoValue 的字符串包装。
		opts := idjOptMap(call, 0)
		pub, err := idjParseRSAPublicKey(idjOptString(opts, "publicKeyPem"))
		if err != nil {
			var coded *idjError
			if errors.As(err, &coded) {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_INTERNAL", err.Error())
		}
		data, err := idjDecodeBytes(idjOptString(opts, "data"), idjOptString(opts, "in"))
		if err != nil {
			var coded *idjError
			if errors.As(err, &coded) {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_INTERNAL", err.Error())
		}
		if idjOptString(opts, "op") == "verify" {
			sig, err := idjDecodeBytes(idjOptString(opts, "signature"), "base64")
			if err != nil {
				idjThrow(rt, "E_INTERNAL", "签名不是合法 base64")
			}
			var verifyErr error
			if strings.ToLower(idjOptString(opts, "hash")) == "sha1" {
				sum := sha1.Sum(data)
				verifyErr = rsa.VerifyPKCS1v15(pub, crypto.SHA1, sum[:], sig)
			} else {
				sum := sha256.Sum256(data)
				verifyErr = rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig)
			}
			return rt.ToValue(verifyErr == nil)
		}
		var encrypted []byte
		if idjOptString(opts, "padding") == "oaep" {
			// iDuanJu 的 OAEP 是 SHA-1（.rsaEncryptionOAEPSHA1）。
			encrypted, err = rsa.EncryptOAEP(sha1.New(), rand.Reader, pub, data, nil)
		} else {
			encrypted, err = rsa.EncryptPKCS1v15(rand.Reader, pub, data)
		}
		if err != nil {
			idjThrow(rt, "E_INTERNAL", "RSA 加密失败")
		}
		outEnc := idjOptString(opts, "out")
		if outEnc == "" {
			outEnc = "base64"
		}
		encoded, err := idjEncodeBytes(encrypted, outEnc)
		if err != nil {
			var coded *idjError
			if errors.As(err, &coded) {
				idjThrow(rt, coded.code, coded.message)
			}
			idjThrow(rt, "E_INTERNAL", err.Error())
		}
		return rt.ToValue(encoded)
	})
	_ = obj.Set("randomHex", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			n := 16
			if len(call.Arguments) > 0 {
				if v, ok := call.Arguments[0].Export().(int64); ok {
					n = int(v)
				} else if v, ok := call.Arguments[0].Export().(float64); ok {
					n = int(v)
				}
			}
			if n < 1 {
				n = 1
			}
			if n > 1024 {
				n = 1024
			}
			buf := make([]byte, n)
			if _, err := rand.Read(buf); err != nil {
				return "", idjErr("E_INTERNAL", "随机数生成失败")
			}
			return hex.EncodeToString(buf), nil
		})
	})
	return obj
}

func (s *idjCallState) hostCodecObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	convert := func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) < 3 {
				return "", idjErr("E_INTERNAL", "convert 需要 (data, from, to)")
			}
			data, err := idjDecodeBytes(jsValueString(call.Arguments[0]), jsValueString(call.Arguments[1]))
			if err != nil {
				return "", err
			}
			return idjEncodeBytes(data, jsValueString(call.Arguments[2]))
		})
	}
	_ = obj.Set("convert", convert)
	_ = obj.Set("base64Encode", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) == 0 {
				return "", idjErr("E_INTERNAL", "缺少输入")
			}
			opts := idjOptMap(call, 1)
			from := idjOptString(opts, "from")
			if from == "" {
				from = "utf8"
			}
			data, err := idjDecodeBytes(jsValueString(call.Arguments[0]), from)
			if err != nil {
				return "", err
			}
			return idjEncodeBytes(data, "base64")
		})
	})
	_ = obj.Set("base64Decode", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) == 0 {
				return "", idjErr("E_INTERNAL", "缺少输入")
			}
			opts := idjOptMap(call, 1)
			to := idjOptString(opts, "to")
			if to == "" {
				to = "utf8"
			}
			data, err := idjDecodeBytes(jsValueString(call.Arguments[0]), "base64")
			if err != nil {
				return "", err
			}
			return idjEncodeBytes(data, to)
		})
	})
	_ = obj.Set("hexEncode", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) == 0 {
				return "", idjErr("E_INTERNAL", "缺少输入")
			}
			opts := idjOptMap(call, 1)
			from := idjOptString(opts, "from")
			if from == "" {
				from = "utf8"
			}
			data, err := idjDecodeBytes(jsValueString(call.Arguments[0]), from)
			if err != nil {
				return "", err
			}
			return idjEncodeBytes(data, "hex")
		})
	})
	_ = obj.Set("gunzip", func(call goja.FunctionCall) goja.Value {
		return idjCryptoValue(rt, func() (string, error) {
			if len(call.Arguments) == 0 {
				return "", idjErr("E_INTERNAL", "缺少输入")
			}
			raw, err := idjDecodeBytes(jsValueString(call.Arguments[0]), "base64")
			if err != nil {
				return "", err
			}
			var reader io.ReadCloser
			switch {
			case len(raw) > 2 && raw[0] == 0x1f && raw[1] == 0x8b:
				reader, err = gzip.NewReader(bytes.NewReader(raw))
			case len(raw) > 2 && raw[0] == 0x78:
				reader, err = zlib.NewReader(bytes.NewReader(raw))
			default:
				return "", idjErr("E_INTERNAL", "解压失败")
			}
			if err != nil {
				return "", idjErr("E_INTERNAL", "解压失败")
			}
			defer reader.Close()
			out, err := io.ReadAll(reader)
			if err != nil {
				return "", idjErr("E_INTERNAL", "解压失败")
			}
			return string(out), nil
		})
	})
	_ = obj.Set("unpackPacker", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(idjUnpackPacker(jsValueString(call.Arguments[0])))
	})
	return obj
}

// idjUnpackPacker 解 Dean Edwards eval(function(p,a,c,k,e,d)…) 打包器：
// 纯字符串替换，不执行。算法是公开的打包格式本身（正则取参 → 按进制
// 建表 → 按词替换），自写 Go 实现。
var idjPackerPattern = regexp.MustCompile(`eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',\s*(\d+),\s*(\d+),\s*'([^']*)'\s*\.split\('\|'\)`)

func idjUnpackPacker(script string) string {
	m := idjPackerPattern.FindStringSubmatch(script)
	if m == nil {
		return ""
	}
	base, err1 := strconv.Atoi(m[2])
	count, err2 := strconv.Atoi(m[3])
	if err1 != nil || err2 != nil {
		return ""
	}
	// base <= 1 会死循环，超大 count 会无界分配，按上游同款守卫拦掉。
	if base <= 1 || base > 62 || count < 0 || count > 200000 {
		return ""
	}
	packed := m[1]
	keys := strings.Split(m[4], "|")
	lookup := make(map[string]string, count)
	for i := 0; i < count; i++ {
		k := idjToBase(i, base)
		if i < len(keys) && keys[i] != "" {
			lookup[k] = keys[i]
		} else {
			lookup[k] = k
		}
	}
	wordPattern := regexp.MustCompile(`\b(\w+)\b`)
	out := wordPattern.ReplaceAllStringFunc(packed, func(token string) string {
		if v, ok := lookup[token]; ok {
			return v
		}
		return token
	})
	return strings.ReplaceAll(out, `\'`, "'")
}

func idjToBase(n, base int) string {
	const digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(digits[n%base]) + s
		n /= base
	}
	return s
}

// ---------------------------------------------------------------------------
// host.m3u8.parse：新写完整解析（master/media 两级、相对地址补全、
// #EXT-X-KEY 提取）。输出形态与规范一致：
// {variants: [{url, bandwidth, resolution, name}],
//  segments: [{url, duration}], key?: {method, uri, iv}}。
// media_playlist.go 的 m3u8Duration 只有时长解析，不是这个。
// ---------------------------------------------------------------------------

var idjM3U8AttrPattern = regexp.MustCompile(`([A-Z0-9-]+)=("[^"]*"|[^,]*)`)

func idjM3U8Attrs(line string) map[string]string {
	out := map[string]string{}
	for _, m := range idjM3U8AttrPattern.FindAllStringSubmatch(line, -1) {
		out[m[1]] = strings.Trim(m[2], `"`)
	}
	return out
}

func idjM3U8Abs(base *url.URL, s string) string {
	if base == nil {
		return s
	}
	if ref, err := url.Parse(s); err == nil {
		return base.ResolveReference(ref).String()
	}
	return s
}

func (s *idjCallState) hostM3U8Object(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("parse", func(call goja.FunctionCall) goja.Value {
		text := ""
		if len(call.Arguments) > 0 {
			text = jsValueString(call.Arguments[0])
		}
		var base *url.URL
		if len(call.Arguments) > 1 {
			if raw := strings.TrimSpace(jsValueString(call.Arguments[1])); raw != "" {
				base, _ = url.Parse(raw)
			}
		}
		variants := []interface{}{}
		segments := []interface{}{}
		var key map[string]interface{}
		var pendingVariant map[string]string
		var pendingDuration float64
		hasDuration := false
		for _, rawLine := range strings.Split(text, "\n") {
			line := strings.TrimSpace(rawLine)
			switch {
			case strings.HasPrefix(line, "#EXT-X-STREAM-INF:"):
				pendingVariant = idjM3U8Attrs(line[len("#EXT-X-STREAM-INF:"):])
			case strings.HasPrefix(line, "#EXTINF:"):
				rest := line[len("#EXTINF:"):]
				if idx := strings.Index(rest, ","); idx >= 0 {
					rest = rest[:idx]
				}
				if d, err := strconv.ParseFloat(strings.TrimSpace(rest), 64); err == nil {
					pendingDuration, hasDuration = d, true
				}
			case strings.HasPrefix(line, "#EXT-X-KEY:"):
				attrs := idjM3U8Attrs(line[len("#EXT-X-KEY:"):])
				uri := attrs["URI"]
				if uri != "" {
					uri = idjM3U8Abs(base, uri)
				}
				key = map[string]interface{}{"method": attrs["METHOD"], "uri": uri, "iv": attrs["IV"]}
			case line != "" && !strings.HasPrefix(line, "#"):
				if pendingVariant != nil {
					bandwidth := 0
					if v := pendingVariant["BANDWIDTH"]; v != "" {
						bandwidth, _ = strconv.Atoi(v)
					}
					variants = append(variants, map[string]interface{}{
						"url":        idjM3U8Abs(base, line),
						"bandwidth":  bandwidth,
						"resolution": pendingVariant["RESOLUTION"],
						"name":       pendingVariant["NAME"],
					})
					pendingVariant = nil
				} else {
					duration := 0.0
					if hasDuration {
						duration = pendingDuration
					}
					segments = append(segments, map[string]interface{}{
						"url":      idjM3U8Abs(base, line),
						"duration": duration,
					})
					pendingDuration, hasDuration = 0, false
				}
			}
		}
		out := map[string]interface{}{"variants": variants, "segments": segments}
		if key != nil {
			out["key"] = key
		}
		return rt.ToValue(out)
	})
	return obj
}

// ---------------------------------------------------------------------------
// host.url：resolve / encodeForm
// ---------------------------------------------------------------------------

func (s *idjCallState) hostURLObject(rt *goja.Runtime) *goja.Object {
	obj := rt.NewObject()
	_ = obj.Set("resolve", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) < 2 {
			if len(call.Arguments) == 1 {
				return rt.ToValue(jsValueString(call.Arguments[0]))
			}
			return rt.ToValue("")
		}
		baseText := jsValueString(call.Arguments[0])
		relText := jsValueString(call.Arguments[1])
		base, err := url.Parse(baseText)
		if err != nil || base == nil {
			return rt.ToValue(relText)
		}
		rel, err := url.Parse(relText)
		if err != nil {
			return rt.ToValue(relText)
		}
		return rt.ToValue(base.ResolveReference(rel).String())
	})
	_ = obj.Set("encodeForm", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		objVal := call.Arguments[0].ToObject(rt)
		if objVal == nil {
			return rt.ToValue("")
		}
		// 用 JS 侧的键顺序（Object.keys 的插入序），不用 Go map 的随机序。
		keys := objVal.Keys()
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			v := objVal.Get(k)
			text := ""
			if v != nil && !goja.IsUndefined(v) && !goja.IsNull(v) {
				text = jsValueString(v)
			}
			parts = append(parts, url.QueryEscape(k)+"="+url.QueryEscape(text))
		}
		return rt.ToValue(strings.Join(parts, "&"))
	})
	return obj
}
