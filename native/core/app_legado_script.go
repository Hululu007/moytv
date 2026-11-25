package core

import (
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"golang.org/x/net/html"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

type legadoJSCtx struct {
	rt           *goja.Runtime
	javaObj      *goja.Object
	vars         map[string]string
	bookVars     map[string]string
	cacheVars    map[string]string
	loginInfo    map[string]string
	baseURL      string
	sourceURL    string
	page         int
	key          string
	sourceObj    interface{}
	sourceFields map[string]interface{}
	jsLib        string
	jsLibLoaded  bool
	jsLibErr     error
	bookTitle    string
	bookURL      string
	curBlock     string
	curJSON      interface{}
	curJSONOK    bool
	jsErr        error
	headers      map[string]string
}

// legadoDeviceID is a stable per-process pseudo device id used by
// java.androidId()/java.deviceID(). The core has no real device identity;
// a random id per process is enough for sources that just need *some*
// id in a header or a query string. It is NOT persisted across restarts.
var (
	legadoDeviceIDOnce sync.Once
	legadoDeviceIDVal  string
)

func legadoDeviceID() string {
	legadoDeviceIDOnce.Do(func() {
		var b [10]byte
		if _, err := rand.Read(b[:]); err != nil {
			legadoDeviceIDVal = fmt.Sprintf("moyi-%d", time.Now().UnixNano())
			return
		}
		legadoDeviceIDVal = fmt.Sprintf("moyi-%x", b[:])
	})
	return legadoDeviceIDVal
}

// legadoEncodeURI percent-encodes s the way Legado's java.encodeURI does.
// With no charset (or utf-8) it is url.QueryEscape; with gbk/gb2312 the
// string is first encoded to GBK bytes and each byte is percent-encoded.
func legadoEncodeURI(s, charset string) string {
	if strings.EqualFold(strings.TrimSpace(charset), "gbk") ||
		strings.EqualFold(strings.TrimSpace(charset), "gb2312") {
		b, _, err := transform.String(simplifiedchinese.GBK.NewEncoder(), s)
		if err == nil {
			var sb strings.Builder
			for i := 0; i < len(b); i++ {
				c := b[i]
				if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
					c == '-' || c == '_' || c == '.' || c == '~' {
					sb.WriteByte(c)
				} else {
					fmt.Fprintf(&sb, "%%%02X", c)
				}
			}
			return sb.String()
		}
	}
	return url.QueryEscape(s)
}

func (c *legadoJSCtx) setSource(src LegadoSource) {
	c.headers = src.Headers
	c.jsLib = src.JsLib
	c.sourceFields = map[string]interface{}{
		"bookSourceName":    src.Name,
		"bookSourceUrl":     src.URL,
		"bookSourceType":    src.Type,
		"searchUrl":         src.SearchURL,
		"exploreUrl":        src.ExploreURL,
		"loginUrl":          src.LoginURL,
		"bookSourceComment": src.Comment,
	}
	c.sourceObj = c.sourceFields
}

func newLegadoJSCtx(sourceURL string) *legadoJSCtx {
	return &legadoJSCtx{
		vars:      map[string]string{},
		bookVars:  map[string]string{},
		cacheVars: map[string]string{},
		loginInfo: map[string]string{},
		sourceURL: sourceURL,
		baseURL:   sourceURL,
		page:      1,
	}
}

func (c *legadoJSCtx) setBlock(block string) {
	c.curBlock = block
	c.curJSON = nil
	c.curJSONOK = false
	cleaned := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(block), "\uFEFF"))
	if strings.HasPrefix(cleaned, "{") || strings.HasPrefix(cleaned, "[") {
		var root interface{}
		if err := json.Unmarshal([]byte(cleaned), &root); err == nil {
			c.curJSON = root
			c.curJSONOK = true
		}
	}
}

func legadoJSGuard(fn func(goja.FunctionCall) (out goja.Value)) func(goja.FunctionCall) (out goja.Value) {
	return func(call goja.FunctionCall) (out goja.Value) {
		defer func() {
			if recover() != nil {
				out = goja.Undefined()
			}
		}()
		out = fn(call)
		if out == nil {
			out = goja.Undefined()
		}
		return out
	}
}

func (c *legadoJSCtx) runtime() *goja.Runtime {
	if c.rt != nil {
		return c.rt
	}
	rt := goja.New()
	c.rt = rt
	// Compatibility shim for JSON.parse: evalJSCur pre-parses a JSON
	// response body into an object and hands it to the rule as `result`,
	// so rules can read result.data... directly. Real Legado hands rules
	// the raw string, and the common rule idiom JSON.parse(result) then
	// works. Under goja, JSON.parse(anObject) coerces the object to
	// "[object Object]" and throws "invalid character 'o'" (6873
	// Lofter, 7939 墨阅）. Return a non-string argument unchanged so
	// both idioms work; string arguments still go through the real
	// parser (including an optional reviver).
	if jsonVal := rt.Get("JSON"); jsonVal != nil {
		if jsonObj := jsonVal.ToObject(rt); jsonObj != nil {
			if parseFn, ok := goja.AssertFunction(jsonObj.Get("parse")); ok {
				jsonObj.Set("parse", func(call goja.FunctionCall) goja.Value {
					arg := call.Argument(0)
					if _, isStr := arg.Export().(string); isStr {
						v, err := parseFn(goja.Undefined(), call.Arguments...)
						if err != nil {
							panic(err)
						}
						return v
					}
					return arg
				})
			}
		}
	}
	javaObj := rt.NewObject()
	c.javaObj = javaObj
	javaObj.Set("ajax", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(c.javaAjax(call))
	}))
	javaObj.Set("ajaxAll", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return c.javaAjaxAll(call)
	}))
	javaObj.Set("get", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(c.vars[call.Arguments[0].String()])
	}))
	javaObj.Set("put", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.vars[call.Arguments[0].String()] = v
			// Return the stored value (not undefined): Legado rule
			// templates such as {{java.put("page",page)}} evaluate to
			// the last expression, so the put must yield its value.
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	javaObj.Set("getString", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(c.javaGetString(call))
	}))
	javaObj.Set("getStringList", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return c.javaGetStringList(call)
	}))
	javaObj.Set("getElements", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return c.javaGetElements(call)
	}))
	javaObj.Set("log", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	javaObj.Set("toast", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	javaObj.Set("longToast", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	javaObj.Set("timeFormat", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(c.javaTimeFormat(call))
	}))
	javaObj.Set("md", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		sum := md5.Sum([]byte(call.Arguments[0].String()))
		return rt.ToValue(fmt.Sprintf("%x", sum))
	}))
	javaObj.Set("md5Encode", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		sum := md5.Sum([]byte(call.Arguments[0].String()))
		return rt.ToValue(fmt.Sprintf("%x", sum))
	}))
	javaObj.Set("randomUUID", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			return rt.ToValue("")
		}
		b[6] = (b[6] & 0x0f) | 0x40
		b[8] = (b[8] & 0x3f) | 0x80
		return rt.ToValue(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
	}))
	javaObj.Set("base64Encode", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(base64.StdEncoding.EncodeToString([]byte(call.Arguments[0].String())))
	}))
	javaObj.Set("base64Decode", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		b, err := base64.StdEncoding.DecodeString(call.Arguments[0].String())
		if err != nil {
			return rt.ToValue("")
		}
		return rt.ToValue(string(b))
	}))
	// java.encodeURI(str[, charset]): percent-encode a string, as Legado
	// sources use it (java.encodeURI(key), java.encodeURI(key,'gbk')).
	// The global encodeURI exists in goja, but sources call it on java.
	javaObj.Set("encodeURI", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		charset := ""
		if len(call.Arguments) > 1 {
			charset = call.Arguments[1].String()
		}
		return rt.ToValue(legadoEncodeURI(call.Arguments[0].String(), charset))
	}))
	javaObj.Set("encodeURIComponent", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(legadoEncodeURI(call.Arguments[0].String(), ""))
	}))
	// Device identity: the core has no real device id; return a stable
	// per-process pseudo id so sources that embed one (Lofter's
	// java.androidId(), 墨阅 header's java.deviceID()) get *some* id.
	javaObj.Set("androidId", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(legadoDeviceID())
	}))
	javaObj.Set("deviceID", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(legadoDeviceID())
	}))
	// java.t2s / java.s2t: traditional<->simplified conversion. No
	// conversion table is bundled with the core, so these currently
	// return the input unchanged (the source still works end to end;
	// titles and text stay in the site's original script). A real
	// mapping table can replace the body later without touching callers.
	javaObj.Set("t2s", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(call.Arguments[0].String())
	}))
	javaObj.Set("s2t", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(call.Arguments[0].String())
	}))
	javaObj.Set("openUrl", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	// Browser automation is unavailable in the core: return "" so rules
	// that wait on a rendered page fall through instead of throwing a
	// ReferenceError. Such sources can still work when their rules have
	// a non-browser fallback; when they don't, the step fails with an
	// empty result rather than crashing the whole evaluation.
	javaObj.Set("startBrowserAwait", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	javaObj.Set("startBrowser", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	javaObj.Set("post", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		body := ""
		if len(call.Arguments) > 1 {
			body = call.Arguments[1].String()
		}
		resp, err := legadoRequest(call.Arguments[0].String(), "POST", body, c.headers)
		if err != nil {
			return rt.ToValue("")
		}
		return rt.ToValue(resp)
	}))
	javaObj.Set("getCookie", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	javaObj.Set("clearCookie", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	javaObj.Set("copyText", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	javaObj.Set("getWebViewUA", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36")
	}))
	javaObj.Set("getStrResponse", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	javaObj.Set("getElement", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return c.jsArray(nil)
	}))
	javaObj.Set("hexDecodeToString", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		s := strings.TrimSpace(call.Arguments[0].String())
		if len(s)%2 != 0 {
			return rt.ToValue("")
		}
		out := make([]byte, 0, len(s)/2)
		for i := 0; i+1 < len(s); i += 2 {
			hi, ok1 := hexVal(s[i])
			lo, ok2 := hexVal(s[i+1])
			if !ok1 || !ok2 {
				return rt.ToValue("")
			}
			out = append(out, hi<<4|lo)
		}
		return rt.ToValue(string(out))
	}))
	javaObj.Set("digestHex", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		sum := md5.Sum([]byte(call.Arguments[0].String()))
		return rt.ToValue(fmt.Sprintf("%x", sum))
	}))
	rt.Set("java", javaObj)
	bookObj := rt.NewObject()
	bookObj.Set("getVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(c.bookVars[call.Arguments[0].String()])
	}))
	bookObj.Set("putVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			c.bookVars[call.Arguments[0].String()] = legadoJSValueString(rt, call.Arguments[1])
		}
		return goja.Undefined()
	}))
	// book.putCustomVariable/getCustomVariable: Legado's per-book
	// annotation store (6873 Lofter intro, 1751 chapterList, 8019
	// init). One argument stores the whole custom-variable string;
	// two arguments store key -> value. Returns the stored value so
	// expression contexts keep working.
	bookObj.Set("putCustomVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.bookVars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		v := legadoJSValueString(rt, call.Arguments[0])
		c.bookVars["customVariable"] = v
		return rt.ToValue(v)
	}))
	bookObj.Set("getCustomVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue(c.bookVars["customVariable"])
		}
		return rt.ToValue(c.bookVars[call.Arguments[0].String()])
	}))
	bookObj.Set("bookUrl", c.bookURL)
	bookObj.Set("name", c.bookTitle)
	rt.Set("book", bookObj)
	// The `source` object: the source's own fields plus the variable
	// accessors Legado sources use (source.getVariable(),
	// source.setVariable(), source.get()/put(), source.getLoginInfo(),
	// source.putLoginInfo(), source.getLoginInfoMap()). The variable
	// store is shared with java.put/java.get: jsLib code such as
	// SRCFG(source) reads it via source.getVariable(), and searchUrl
	// templates write it via java.put().
	sourceObj := rt.NewObject()
	for k, v := range c.sourceFields {
		sourceObj.Set(k, v)
	}
	sourceObj.Set("getVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			if len(c.vars) == 0 {
				return rt.ToValue("")
			}
			b, err := json.Marshal(c.vars)
			if err != nil {
				return rt.ToValue("")
			}
			return rt.ToValue(string(b))
		}
		return rt.ToValue(c.vars[call.Arguments[0].String()])
	}))
	sourceObj.Set("setVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		var m map[string]string
		if json.Unmarshal([]byte(call.Arguments[0].String()), &m) == nil {
			c.vars = m
		}
		return goja.Undefined()
	}))
	sourceObj.Set("putVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.vars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	sourceObj.Set("get", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		k := call.Arguments[0].String()
		if v, ok := c.vars[k]; ok {
			return rt.ToValue(v)
		}
		if v, ok := c.sourceFields[k]; ok {
			return rt.ToValue(legadoJSExportString(v))
		}
		return rt.ToValue("")
	}))
	sourceObj.Set("put", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.vars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	sourceObj.Set("getLoginInfo", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(c.loginInfo) == 0 {
			return rt.ToValue("")
		}
		b, err := json.Marshal(c.loginInfo)
		if err != nil {
			return rt.ToValue("")
		}
		return rt.ToValue(string(b))
	}))
	sourceObj.Set("putLoginInfo", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		var m map[string]string
		if json.Unmarshal([]byte(call.Arguments[0].String()), &m) == nil {
			c.loginInfo = m
		}
		return goja.Undefined()
	}))
	sourceObj.Set("getLoginInfoMap", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		obj := rt.NewObject()
		for k, v := range c.loginInfo {
			obj.Set(k, v)
		}
		return obj
	}))
	// Login header string (1751, 6873, 7814, 8011, 8019, 8124, 8128):
	// getHeaderMap() reads source.getLoginHeader() and JSON-parses it;
	// putLoginHeader stores the header JSON and returns it, so callers
	// such as `token = source.putLoginHeader(JSON.stringify(head))`
	// receive the stored value. No login ever happens in the core, so
	// the stored header is empty unless a rule put one there.
	sourceObj.Set("getLoginHeader", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(c.loginInfo["header"])
	}))
	sourceObj.Set("putLoginHeader", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		v := legadoJSValueString(rt, call.Arguments[0])
		c.loginInfo["header"] = v
		return rt.ToValue(v)
	}))
	rt.Set("source", sourceObj)
	// Per-source in-memory cache (cache.get/put/getFromMemory/putMemory).
	// There is no on-disk file cache in the core, so getFile returns "".
	cacheObj := rt.NewObject()
	cacheObj.Set("get", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(c.cacheVars[call.Arguments[0].String()])
	}))
	cacheObj.Set("put", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.cacheVars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	cacheObj.Set("getFromMemory", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(c.cacheVars[call.Arguments[0].String()])
	}))
	cacheObj.Set("putMemory", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.cacheVars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	cacheObj.Set("getFile", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	rt.Set("cache", cacheObj)
	// Bare getVariable/putVariable: some sources call them without a
	// receiver. They read/write the same variable store as java.put.
	rt.Set("getVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		return rt.ToValue(c.vars[call.Arguments[0].String()])
	}))
	rt.Set("putVariable", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			v := legadoJSValueString(rt, call.Arguments[1])
			c.vars[call.Arguments[0].String()] = v
			return rt.ToValue(v)
		}
		return goja.Undefined()
	}))
	rt.Set("Reload", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		body, err := legadoRequest(call.Arguments[0].String(), "GET", "", c.headers)
		if err != nil {
			return rt.ToValue("")
		}
		return rt.ToValue(body)
	}))
	jsoupObj := rt.NewObject()
	jsoupInner := rt.NewObject()
	jsoupInner.Set("parse", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return c.jsoupParse(call)
	}))
	jsoupObj.Set("Jsoup", jsoupInner)
	orgObj := rt.NewObject()
	orgObj.Set("jsoup", jsoupObj)
	rt.Set("org", orgObj)
	// Cookie manager (7632): the core keeps no cookies, so getCookie
	// returns "" and removeCookie is a no-op; the object only exists so
	// `typeof cookieManager.getCookie === 'function'` checks pass and
	// the rule falls through to its no-cookie branch.
	cookieObj := rt.NewObject()
	cookieObj.Set("getCookie", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	cookieObj.Set("getCookies", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue([]interface{}{})
	}))
	cookieObj.Set("removeCookie", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	}))
	rt.Set("cookie", cookieObj)
	// Rhino-style Packages bridge (7895, 7814, 8006, 8007, 8011, ...).
	// Only the shapes these sources actually use are emulated; real
	// Java classes (Cipher, StrResponse, ...) are out of scope.
	rt.Set("Packages", legadoPackagesObject(rt))
	return rt
}

// legadoJSInt reads a goja value as an int64 (JS numbers, numeric
// strings, booleans).
func legadoJSInt(v goja.Value) int64 {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return 0
	}
	if n, ok := v.Export().(int64); ok {
		return n
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(v.String()), 64)
	if err != nil {
		return 0
	}
	return int64(f)
}

// legadoEncodeBytes encodes s in the named charset (UTF-8 default,
// GBK/GB2312 via the simplifiedchinese encoder).
func legadoEncodeBytes(s, charset string) []byte {
	switch strings.ToUpper(strings.TrimSpace(charset)) {
	case "GBK", "GB2312", "GB18030":
		b, _, err := transform.Bytes(simplifiedchinese.GBK.NewEncoder(), []byte(s))
		if err == nil {
			return b
		}
	}
	return []byte(s)
}

// legadoJSBytes converts a JS value to bytes: a string becomes its
// bytes (UTF-8), a JS array of numbers becomes the byte values, a
// []byte passed from Go stays as-is.
func legadoJSBytes(rt *goja.Runtime, v goja.Value) []byte {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil
	}
	if b, ok := v.Export().([]byte); ok {
		return b
	}
	if s, ok := v.Export().(string); ok {
		return []byte(s)
	}
	obj := v.ToObject(rt)
	if obj == nil {
		return []byte(v.String())
	}
	if length := obj.Get("length"); length != nil {
		n := int(legadoJSInt(length))
		if n >= 0 && n <= 1<<26 {
			out := make([]byte, n)
			for i := 0; i < n; i++ {
				out[i] = byte(legadoJSInt(obj.Get(strconv.Itoa(i))))
			}
			return out
		}
	}
	return []byte(v.String())
}

// legadoJSByteArray builds a JS array of numbers from bytes, so JS code
// can index it (b[i] & 0xff) and read b.length.
func legadoJSByteArray(rt *goja.Runtime, b []byte) goja.Value {
	arr := make([]interface{}, len(b))
	for i, v := range b {
		arr[i] = int64(v)
	}
	return rt.ToValue(arr)
}

func legadoMD5Hex(b []byte) string {
	sum := md5.Sum(b)
	return hex.EncodeToString(sum[:])
}

// legadoPackagesObject builds the minimal Packages tree used by Legado
// sources: java.lang (Thread.sleep, System.currentTimeMillis,
// String constructor with getBytes, Byte.TYPE, reflect.Array),
// java.security.MessageDigest (MD5/SHA-1/SHA-256/SHA-512),
// java.util (Base64, Arrays.copyOf/copyOfRange, HashMap),
// java.io.ByteArrayOutputStream, android.util.Base64,
// cn.hutool.crypto.digest.DigestUtil.md5Hex, and the Legado
// TimeoutCancellationException type. Deliberately NOT emulated:
// javax.crypto.Cipher (7814 AES-GCM) and
// io.legado.app.help.http.StrResponse (8019).
func legadoPackagesObject(rt *goja.Runtime) *goja.Object {
	guard := func(f func(goja.FunctionCall) goja.Value) func(goja.FunctionCall) goja.Value {
		return legadoJSGuard(f)
	}
	// NOTE: this goja version only treats func(ConstructorCall)
	// *Object as a native constructor; a func returning goja.Value
	// is a plain function and `new` on it throws "not a
	// constructor". All Packages constructors below return *Object.
	guardCtor := func(f func(goja.ConstructorCall) *goja.Object) func(goja.ConstructorCall) *goja.Object {
		return func(call goja.ConstructorCall) (v *goja.Object) {
			defer func() {
				if r := recover(); r != nil {
					v = rt.NewObject()
				}
			}()
			return f(call)
		}
	}

	javaObj := rt.NewObject()
	langObj := rt.NewObject()
	threadObj := rt.NewObject()
	threadObj.Set("sleep", guard(func(call goja.FunctionCall) goja.Value {
		ms := int64(0)
		if len(call.Arguments) > 0 {
			ms = legadoJSInt(call.Arguments[0])
		}
		// Cap the sleep: rule evaluation runs under a 10s timer, a
		// longer sleep would only time the rule out.
		if ms > 5000 {
			ms = 5000
		}
		if ms > 0 {
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
		return goja.Undefined()
	}))
	langObj.Set("Thread", threadObj)
	systemObj := rt.NewObject()
	systemObj.Set("currentTimeMillis", guard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(time.Now().UnixMilli())
	}))
	systemObj.Set("nanoTime", guard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(time.Now().UnixNano())
	}))
	systemObj.Set("getenv", guard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue("")
	}))
	langObj.Set("System", systemObj)
	// new java.lang.String(s): getBytes(charset) + toString.
	langObj.Set("String", guardCtor(func(call goja.ConstructorCall) *goja.Object {
		s := ""
		if len(call.Arguments) > 0 {
			s = legadoJSValueString(rt, call.Arguments[0])
		}
		obj := call.This
		obj.Set("getBytes", guard(func(c goja.FunctionCall) goja.Value {
			cs := "UTF-8"
			if len(c.Arguments) > 0 {
				cs = legadoJSValueString(rt, c.Arguments[0])
			}
			return legadoJSByteArray(rt, legadoEncodeBytes(s, cs))
		}))
		obj.Set("toString", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue(s)
		}))
		obj.Set("length", len([]rune(s)))
		return obj
	}))
	byteObj := rt.NewObject()
	byteObj.Set("TYPE", "byte")
	langObj.Set("Byte", byteObj)
	reflectObj := rt.NewObject()
	arrayObj := rt.NewObject()
	arrayObj.Set("newInstance", guard(func(call goja.FunctionCall) goja.Value {
		n := int64(0)
		if len(call.Arguments) > 1 {
			n = legadoJSInt(call.Arguments[1])
		}
		if n < 0 || n > 1<<26 {
			return rt.ToValue([]interface{}{})
		}
		return legadoJSByteArray(rt, make([]byte, n))
	}))
	reflectObj.Set("Array", arrayObj)
	langObj.Set("reflect", reflectObj)
	javaObj.Set("lang", langObj)

	securityObj := rt.NewObject()
	mdObj := rt.NewObject()
	mdObj.Set("getInstance", guard(func(call goja.FunctionCall) goja.Value {
		alg := strings.ToUpper(strings.ReplaceAll(legadoJSValueString(rt, call.Argument(0)), "-", ""))
		d := rt.NewObject()
		var buf []byte
		digest := func(data []byte) goja.Value {
			var sum []byte
			switch alg {
			case "SHA1":
				h := sha1.Sum(data)
				sum = h[:]
			case "SHA256":
				h := sha256.Sum256(data)
				sum = h[:]
			case "SHA512":
				h := sha512.Sum512(data)
				sum = h[:]
			default: // MD5 and anything unknown fall back to MD5.
				h := md5.Sum(data)
				sum = h[:]
			}
			buf = nil
			return legadoJSByteArray(rt, sum)
		}
		d.Set("update", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) > 0 {
				buf = append(buf, legadoJSBytes(rt, c.Arguments[0])...)
			}
			return goja.Undefined()
		}))
		d.Set("digest", guard(func(c goja.FunctionCall) goja.Value {
			data := buf
			if len(c.Arguments) > 0 && !goja.IsUndefined(c.Arguments[0]) && !goja.IsNull(c.Arguments[0]) {
				data = append(append([]byte{}, buf...), legadoJSBytes(rt, c.Arguments[0])...)
			}
			return digest(data)
		}))
		return d
	}))
	securityObj.Set("MessageDigest", mdObj)
	javaObj.Set("security", securityObj)

	utilObj := rt.NewObject()
	b64Obj := rt.NewObject()
	b64Obj.Set("getDecoder", guard(func(call goja.FunctionCall) goja.Value {
		dec := rt.NewObject()
		dec.Set("decode", guard(func(c goja.FunctionCall) goja.Value {
			s := legadoJSValueString(rt, c.Argument(0))
			b, err := base64.StdEncoding.DecodeString(s)
			if err != nil {
				b, _ = base64.RawURLEncoding.DecodeString(s)
			}
			return legadoJSByteArray(rt, b)
		}))
		return dec
	}))
	b64Obj.Set("getEncoder", guard(func(call goja.FunctionCall) goja.Value {
		enc := rt.NewObject()
		enc.Set("encodeToString", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue(base64.StdEncoding.EncodeToString(legadoJSBytes(rt, c.Argument(0))))
		}))
		enc.Set("encode", guard(func(c goja.FunctionCall) goja.Value {
			return legadoJSByteArray(rt, []byte(base64.StdEncoding.EncodeToString(legadoJSBytes(rt, c.Argument(0)))))
		}))
		return enc
	}))
	utilObj.Set("Base64", b64Obj)
	arraysObj := rt.NewObject()
	arraysObj.Set("copyOf", guard(func(call goja.FunctionCall) goja.Value {
		src := legadoJSBytes(rt, call.Argument(0))
		n := int(legadoJSInt(call.Argument(1)))
		if n < 0 {
			n = 0
		}
		out := make([]byte, n)
		copy(out, src)
		return legadoJSByteArray(rt, out)
	}))
	arraysObj.Set("copyOfRange", guard(func(call goja.FunctionCall) goja.Value {
		src := legadoJSBytes(rt, call.Argument(0))
		from := int(legadoJSInt(call.Argument(1)))
		to := int(legadoJSInt(call.Argument(2)))
		if from < 0 {
			from = 0
		}
		if to > len(src) {
			to = len(src)
		}
		if from > to {
			from = to
		}
		return legadoJSByteArray(rt, src[from:to])
	}))
	utilObj.Set("Arrays", arraysObj)
	utilObj.Set("HashMap", guardCtor(func(call goja.ConstructorCall) *goja.Object {
		m := map[string]goja.Value{}
		obj := call.This
		obj.Set("put", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) < 2 {
				return goja.Undefined()
			}
			k := c.Arguments[0].String()
			prev, ok := m[k]
			m[k] = c.Arguments[1]
			if !ok {
				return goja.Null()
			}
			return prev
		}))
		obj.Set("get", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) == 0 {
				return goja.Null()
			}
			if v, ok := m[c.Arguments[0].String()]; ok {
				return v
			}
			return goja.Null()
		}))
		obj.Set("containsKey", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) == 0 {
				return rt.ToValue(false)
			}
			_, ok := m[c.Arguments[0].String()]
			return rt.ToValue(ok)
		}))
		obj.Set("remove", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) == 0 {
				return goja.Null()
			}
			k := c.Arguments[0].String()
			v, ok := m[k]
			delete(m, k)
			if !ok {
				return goja.Null()
			}
			return v
		}))
		obj.Set("size", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue(len(m))
		}))
		obj.Set("keySet", guard(func(c goja.FunctionCall) goja.Value {
			keys := make([]interface{}, 0, len(m))
			for k := range m {
				keys = append(keys, k)
			}
			return rt.ToValue(keys)
		}))
		return obj
	}))
	javaObj.Set("util", utilObj)

	ioObj := rt.NewObject()
	ioObj.Set("ByteArrayOutputStream", guardCtor(func(call goja.ConstructorCall) *goja.Object {
		var buf []byte
		obj := call.This
		obj.Set("write", guard(func(c goja.FunctionCall) goja.Value {
			if len(c.Arguments) == 0 {
				return goja.Undefined()
			}
			if len(c.Arguments) == 1 {
				if n, ok := c.Arguments[0].Export().(int64); ok {
					buf = append(buf, byte(n))
					return goja.Undefined()
				}
			}
			buf = append(buf, legadoJSBytes(rt, c.Arguments[0])...)
			return goja.Undefined()
		}))
		obj.Set("toByteArray", guard(func(c goja.FunctionCall) goja.Value {
			return legadoJSByteArray(rt, buf)
		}))
		obj.Set("toString", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue(string(buf))
		}))
		obj.Set("size", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue(len(buf))
		}))
		obj.Set("reset", guard(func(c goja.FunctionCall) goja.Value {
			buf = nil
			return goja.Undefined()
		}))
		return obj
	}))
	// java.io lives under Packages.java.io, not Packages.io.
	javaObj.Set("io", ioObj)

	androidObj := rt.NewObject()
	androidB64 := rt.NewObject()
	androidB64.Set("DEFAULT", 0)
	androidB64.Set("NO_WRAP", 2)
	androidB64.Set("URL_SAFE", 8)
	androidB64.Set("encodeToString", guard(func(call goja.FunctionCall) goja.Value {
		b := legadoJSBytes(rt, call.Argument(0))
		flags := int64(0)
		if len(call.Arguments) > 1 {
			flags = legadoJSInt(call.Arguments[1])
		}
		if flags&8 != 0 {
			return rt.ToValue(base64.RawURLEncoding.EncodeToString(b))
		}
		return rt.ToValue(base64.StdEncoding.EncodeToString(b))
	}))
	androidB64.Set("decode", guard(func(call goja.FunctionCall) goja.Value {
		s := legadoJSValueString(rt, call.Argument(0))
		flags := int64(0)
		if len(call.Arguments) > 1 {
			flags = legadoJSInt(call.Arguments[1])
		}
		var b []byte
		var err error
		if flags&8 != 0 {
			b, err = base64.RawURLEncoding.DecodeString(s)
		} else {
			b, err = base64.StdEncoding.DecodeString(s)
		}
		if err != nil {
			b, _ = base64.RawStdEncoding.DecodeString(s)
		}
		return legadoJSByteArray(rt, b)
	}))
	androidUtil := rt.NewObject()
	androidUtil.Set("Base64", androidB64)
	androidObj.Set("util", androidUtil)

	cnObj := rt.NewObject()
	hutoolObj := rt.NewObject()
	hutoolCrypto := rt.NewObject()
	hutoolDigest := rt.NewObject()
	digestUtil := rt.NewObject()
	digestUtil.Set("md5Hex", guard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(legadoMD5Hex([]byte(legadoJSValueString(rt, call.Argument(0)))))
	}))
	hutoolDigest.Set("DigestUtil", digestUtil)
	hutoolCrypto.Set("digest", hutoolDigest)
	hutoolObj.Set("crypto", hutoolCrypto)
	cnObj.Set("hutool", hutoolObj)

	legadoObj := rt.NewObject()
	legadoKazusa := rt.NewObject()
	legadoUtils := rt.NewObject()
	legadoUtils.Set("TimeoutCancellationException", guardCtor(func(call goja.ConstructorCall) *goja.Object {
		msg := ""
		if len(call.Arguments) > 0 {
			msg = legadoJSValueString(rt, call.Arguments[0])
		}
		obj := call.This
		obj.Set("message", msg)
		obj.Set("toString", guard(func(c goja.FunctionCall) goja.Value {
			return rt.ToValue("TimeoutCancellationException: " + msg)
		}))
		return obj
	}))
	legadoKazusa.Set("utils", legadoUtils)
	legadoObj.Set("kazusa", legadoKazusa)

	packagesObj := rt.NewObject()
	packagesObj.Set("java", javaObj)
	packagesObj.Set("android", androidObj)
	packagesObj.Set("cn", cnObj)
	ioTop := rt.NewObject()
	ioTop.Set("legado", legadoObj)
	packagesObj.Set("io", ioTop)
	return packagesObj
}

func (c *legadoJSCtx) javaAjax(call goja.FunctionCall) string {
	if len(call.Arguments) == 0 {
		return ""
	}
	raw := call.Arguments[0].String()
	urlStr := raw
	opts := ""
	if i := strings.Index(raw, ",{"); i >= 0 {
		urlStr = raw[:i]
		opts = raw[i+1:]
	}
	if len(call.Arguments) > 1 {
		second := call.Arguments[1]
		if !goja.IsUndefined(second) && !goja.IsNull(second) {
			if s, ok := second.Export().(string); ok {
				opts = s
			} else if b, err := json.Marshal(second.Export()); err == nil {
				opts = string(b)
			}
		}
	}
	method := "GET"
	body := ""
	headers := map[string]string{}
	if opts != "" {
		var m map[string]interface{}
		if json.Unmarshal([]byte(opts), &m) == nil {
			if v, ok := m["method"].(string); ok && v != "" {
				method = strings.ToUpper(v)
			}
			if v, ok := m["body"].(string); ok {
				body = v
			}
			if h, ok := m["headers"].(map[string]interface{}); ok {
				for k, v := range h {
					if vs, ok := v.(string); ok {
						headers[k] = vs
					}
				}
			}
			if h, ok := m["headers"].(string); ok {
				var hm map[string]interface{}
				if json.Unmarshal([]byte(h), &hm) == nil {
					for k, v := range hm {
						if vs, ok := v.(string); ok {
							headers[k] = vs
						}
					}
				}
			}
		}
	}
	return c.javaAjaxDo(urlStr, method, body, headers)
}

func (c *legadoJSCtx) javaAjaxDo(urlStr, method, body string, headers map[string]string) string {
	if urlStr == "" {
		return ""
	}
	resp, err := legadoRequest(urlStr, method, body, legadoMergeHeaders(c.headers, headers))
	if err != nil {
		return ""
	}
	return resp
}

func (c *legadoJSCtx) javaAjaxAll(call goja.FunctionCall) goja.Value {
	rt := c.runtime()
	elems := []goja.Value{}
	var items []interface{}
	if len(call.Arguments) > 0 {
		if arr, ok := call.Arguments[0].Export().([]interface{}); ok {
			items = arr
		} else {
			for _, a := range call.Arguments {
				items = append(items, a.Export())
			}
		}
	}
	for _, it := range items {
		switch v := it.(type) {
		case string:
			elems = append(elems, rt.ToValue(c.javaAjaxDo(v, "GET", "", nil)))
		case []interface{}:
			urlStr := ""
			opts := ""
			if len(v) > 0 {
				urlStr, _ = v[0].(string)
			}
			if len(v) > 1 {
				if s, ok := v[1].(string); ok {
					opts = s
				} else if b, err := json.Marshal(v[1]); err == nil {
					opts = string(b)
				}
			}
			method := "GET"
			body := ""
			headers := map[string]string{}
			if opts != "" {
				var m map[string]interface{}
				if json.Unmarshal([]byte(opts), &m) == nil {
					if mv, ok := m["method"].(string); ok && mv != "" {
						method = strings.ToUpper(mv)
					}
					if bv, ok := m["body"].(string); ok {
						body = bv
					}
					if h, ok := m["headers"].(map[string]interface{}); ok {
						for k, hv := range h {
							if vs, ok := hv.(string); ok {
								headers[k] = vs
							}
						}
					}
				}
			}
			elems = append(elems, rt.ToValue(c.javaAjaxDo(urlStr, method, body, headers)))
		default:
			elems = append(elems, rt.ToValue(""))
		}
	}
	return c.jsArray(elems)
}

func (c *legadoJSCtx) javaGetString(call goja.FunctionCall) string {
	if len(call.Arguments) == 0 {
		return ""
	}
	arg := call.Arguments[0].String()
	if strings.HasPrefix(arg, "$") {
		if c.curJSONOK {
			nodes := legadoJSONEval(c.curJSON, mustLegadoSegs(arg))
			if len(nodes) > 0 {
				return legadoJSONValueString(nodes[0])
			}
		}
		return ""
	}
	if strings.HasPrefix(arg, "http") {
		resp, err := legadoRequest(arg, "GET", "", c.headers)
		if err != nil {
			return ""
		}
		return resp
	}
	return c.vars[arg]
}

func mustLegadoSegs(rule string) []legadoJSONSeg {
	segs, _ := legadoParseJSONPath(rule)
	return segs
}

func (c *legadoJSCtx) javaGetStringList(call goja.FunctionCall) goja.Value {
	rt := c.runtime()
	if len(call.Arguments) == 0 || !c.curJSONOK {
		return c.jsArray(nil)
	}
	path := call.Arguments[0].String()
	segs, ok := legadoParseJSONPath(path)
	if !ok {
		return c.jsArray(nil)
	}
	nodes := legadoJSONEval(c.curJSON, segs)
	elems := []goja.Value{}
	for _, n := range nodes {
		if s, ok := n.(string); ok {
			elems = append(elems, rt.ToValue(s))
		}
	}
	return c.jsArray(elems)
}

func (c *legadoJSCtx) javaGetElements(call goja.FunctionCall) goja.Value {
	if len(call.Arguments) == 0 {
		return c.jsArray(nil)
	}
	nodes := legadoSelectNodes(c.curBlock, call.Arguments[0].String())
	elems := []goja.Value{}
	for _, n := range nodes {
		elems = append(elems, c.jsElement(n))
	}
	return c.jsArray(elems)
}

func (c *legadoJSCtx) jsoupParse(call goja.FunctionCall) goja.Value {
	rt := c.runtime()
	if len(call.Arguments) == 0 {
		return c.jsArray(nil)
	}
	page := call.Arguments[0].String()
	obj := rt.NewObject()
	obj.Set("select", legadoJSGuard(func(selCall goja.FunctionCall) goja.Value {
		if len(selCall.Arguments) == 0 {
			return c.jsArray(nil)
		}
		nodes := legadoSelectNodes(page, selCall.Arguments[0].String())
		elems := []goja.Value{}
		for _, n := range nodes {
			elems = append(elems, c.jsElement(n))
		}
		return c.jsArray(elems)
	}))
	return obj
}

func (c *legadoJSCtx) jsElement(n *html.Node) goja.Value {
	rt := c.runtime()
	obj := rt.NewObject()
	obj.Set("text", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(hikerNodeText(n))
	}))
	obj.Set("attr", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue("")
		}
		if v, ok := hikerAttr(n, call.Arguments[0].String()); ok {
			return rt.ToValue(v)
		}
		return rt.ToValue("")
	}))
	obj.Set("html", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return rt.ToValue(hikerOuterHTML(n))
	}))
	return obj
}

func (c *legadoJSCtx) jsArray(elems []goja.Value) goja.Value {
	rt := c.runtime()
	arrVal, err := rt.RunString("[]")
	if err != nil {
		return rt.ToValue([]string{})
	}
	arr := arrVal.ToObject(rt)
	for i, e := range elems {
		arr.Set(strconv.Itoa(i), e)
	}
	arrCopy := arrVal
	arr.Set("toArray", legadoJSGuard(func(call goja.FunctionCall) goja.Value {
		return arrCopy
	}))
	return arrVal
}

func (c *legadoJSCtx) javaTimeFormat(call goja.FunctionCall) string {
	if len(call.Arguments) == 0 {
		return ""
	}
	raw := strings.TrimSpace(call.Arguments[0].String())
	if raw == "" {
		return ""
	}
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		var t time.Time
		switch {
		case n > 1000000000000:
			t = time.UnixMilli(n)
		case n > 1000000000:
			t = time.Unix(n, 0)
		default:
			t = time.Unix(n, 0)
		}
		return t.Format("2006-01-02 15:04:05")
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.Format("2006-01-02 15:04:05")
	}
	return raw
}

func hexVal(b byte) (byte, bool) {
	switch {
	case b >= '0' && b <= '9':
		return b - '0', true
	case b >= 'a' && b <= 'f':
		return b - 'a' + 10, true
	case b >= 'A' && b <= 'F':
		return b - 'A' + 10, true
	}
	return 0, false
}

func legadoJSValueString(rt *goja.Runtime, v goja.Value) string {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return ""
	}
	return legadoJSExportString(v.Export())
}

func legadoJSExportString(v interface{}) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		if x {
			return "true"
		}
		return "false"
	case []interface{}:
		parts := []string{}
		for _, el := range x {
			parts = append(parts, legadoJSExportString(el))
		}
		return strings.Join(parts, "\n")
	default:
		b, err := json.Marshal(x)
		if err != nil {
			return ""
		}
		return string(b)
	}
}

func (c *legadoJSCtx) evalJSCur(script, cur string) (goja.Value, error) {
	rt := c.runtime()
	v := rt.ToValue(cur)
	if trimmed := strings.TrimSpace(cur); strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		var parsed interface{}
		if err := json.Unmarshal([]byte(trimmed), &parsed); err == nil {
			v = rt.ToValue(parsed)
			if m, isMap := parsed.(map[string]interface{}); isMap {
				// ToValue(map) yields a host object on which
				// defineProperty fails ("Host object field ...
				// cannot be made configurable"); rebuild the top
				// level as a plain JS object so the hidden
				// toString/length below can be attached.
				obj := rt.NewObject()
				for k, val := range m {
					obj.Set(k, rt.ToValue(val))
				}
				v = obj
			}
			// The parsed value stands in for the raw response string
			// real Legado hands rules, so make the string idioms work
			// too: String(result) must return the JSON text (rules do
			// JSON.parse(String(result)), 8146 墨阅·起点）, and
			// result.length on an object must read as the text length
			// (6873 chapterList tests result.length). Both are hidden
			// (non-enumerable) so JSON.stringify(result) stays clean.
			if obj := v.ToObject(rt); obj != nil {
				text := trimmed
				// Hidden (non-enumerable) own properties, defined
				// through the builtin Object.defineProperty: this
				// goja version does not export DefineOwnProperty.
				defineProp, _ := goja.AssertFunction(rt.Get("Object").ToObject(rt).Get("defineProperty"))
				setHidden := func(name string, val goja.Value) {
					if defineProp == nil {
						return
					}
					desc := rt.NewObject()
					desc.Set("value", val)
					desc.Set("writable", true)
					desc.Set("enumerable", false)
					desc.Set("configurable", true)
					_, _ = defineProp(goja.Undefined(), obj, rt.ToValue(name), desc)
				}
				setHidden("toString", rt.ToValue(func(call goja.FunctionCall) goja.Value {
					return rt.ToValue(text)
				}))
				if _, isMap := parsed.(map[string]interface{}); isMap {
					setHidden("length", rt.ToValue(len(text)))
				}
			}
		}
	}
	return c.evalJS(script, v)
}

func (c *legadoJSCtx) evalJS(script string, result goja.Value) (goja.Value, error) {
	rt := c.runtime()
	rt.Set("result", result)
	rt.Set("baseUrl", c.baseURL)
	rt.Set("page", c.page)
	rt.Set("key", c.key)
	if c.javaObj != nil {
		c.javaObj.Set("baseUrl", c.baseURL)
	}
	type evalOut struct {
		v   goja.Value
		err error
	}
	done := make(chan evalOut, 1)
	go func() {
		// A bad jsLib must fail the rule, never the process: recover
		// any panic from the script (or from a callback that escaped
		// its guard) and report it as a plain evaluation error. The
		// runtime belongs to this request's context, so a poisoned
		// runtime dies with the context.
		defer func() {
			if r := recover(); r != nil {
				done <- evalOut{nil, fmt.Errorf("legado js panic: %v", r)}
			}
		}()
		// Load the source's jsLib once per context, under the same
		// timeout guard as the rule script. jsLib holds the helper
		// functions the rules call (SRCFG, qmSearch, TX_search,
		// ensureConfig, ...); without it every such source fails with
		// "X is not defined". A jsLib load error is recorded but does
		// not block the rule: functions declared before the failing
		// statement are still usable.
		if !c.jsLibLoaded && strings.TrimSpace(c.jsLib) != "" {
			c.jsLibLoaded = true
			if _, err := rt.RunString(c.jsLib); err != nil {
				c.jsLibErr = err
			}
		}
		v, err := rt.RunString(script)
		done <- evalOut{v: v, err: err}
	}()
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	select {
	case out := <-done:
		if out.err != nil {
			return nil, out.err
		}
		if out.v == nil || goja.IsUndefined(out.v) || goja.IsNull(out.v) {
			if rv := rt.Get("result"); rv != nil && !goja.IsUndefined(rv) {
				return rv, nil
			}
			return goja.Undefined(), nil
		}
		return out.v, nil
	case <-timer.C:
		rt.Interrupt("legado js timeout")
		<-done
		rt.ClearInterrupt()
		return nil, fmt.Errorf("legado js timeout")
	}
}

var legadoBareTagRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]*$`)

func legadoSelectNodes(htmlText, selector string) []*html.Node {
	selector = strings.TrimSpace(selector)
	if selector == "" {
		return nil
	}
	if strings.Contains(selector, "@") {
		if nodes, _, ok := legadoEvalDialect(htmlText, selector, true); ok && len(nodes) > 0 {
			return nodes
		}
	}
	if i := strings.Index(selector, "@"); i >= 0 {
		left := strings.TrimSpace(selector[:i])
		right := strings.TrimSpace(selector[i+1:])
		if legadoBareTagRe.MatchString(right) {
			return legadoSelectNodes(htmlText, left+" "+right)
		}
		nodes := legadoSelectNodes(htmlText, left)
		if right == "text" || right == "html" || hikerIsAttr(right) {
			out := []*html.Node{}
			for _, n := range nodes {
				if right == "text" || right == "html" {
					out = append(out, n)
					continue
				}
				if _, ok := hikerAttr(n, right); ok {
					out = append(out, n)
				}
			}
			return out
		}
		return nodes
	}
	groups := strings.Split(selector, ",")
	seen := map[*html.Node]bool{}
	out := []*html.Node{}
	for _, g := range groups {
		g = strings.TrimSpace(g)
		if g == "" {
			continue
		}
		parts := strings.FieldsFunc(g, func(r rune) bool {
			return r == ' ' || r == '>' || r == '\t' || r == '\n' || r == '\r'
		})
		toks := []string{}
		for _, p := range parts {
			if p == "" {
				continue
			}
			if strings.ContainsAny(p, "+~") {
				continue
			}
			if i := strings.Index(p, ":"); i >= 0 {
				p = p[:i]
				if p == "" {
					continue
				}
			}
			toks = append(toks, p)
		}
		if len(toks) == 0 {
			continue
		}
		for _, n := range hikerSelectChain(htmlText, strings.Join(toks, "&&")) {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
	}
	return out
}

var legadoPutRe = regexp.MustCompile(`@put:\{([^:}]+):([^}]*)\}`)
var legadoGetRe = regexp.MustCompile(`@get:\{([^}]+)\}`)

// legadoTemplateSpan returns the end index (exclusive) of the {{...}}
// template starting at start, or -1 when the template never closes.
// Braces inside string literals, comments and regex literals do not
// count, so a whole-URL IIFE such as {{(function(){...})()}} is one
// span even though its body contains braces. The old [^{}]* regex
// could not match those at all.
func legadoTemplateSpan(s string, start int) int {
	depth := 2 // the opening {{
	i := start + 2
	var str byte
	esc := false
	lineComment := false
	blockComment := false
	regexOK := true
	for i < len(s) {
		c := s[i]
		if lineComment {
			if c == '\n' {
				lineComment = false
			}
			i++
			continue
		}
		if blockComment {
			if c == '*' && i+1 < len(s) && s[i+1] == '/' {
				blockComment = false
				i += 2
				continue
			}
			i++
			continue
		}
		if str != 0 {
			if esc {
				esc = false
				i++
				continue
			}
			if c == '\\' {
				esc = true
				i++
				continue
			}
			if c == str {
				str = 0
			}
			i++
			continue
		}
		if c == '/' && i+1 < len(s) {
			if s[i+1] == '/' {
				lineComment = true
				i += 2
				continue
			}
			if s[i+1] == '*' {
				blockComment = true
				i += 2
				continue
			}
			if regexOK {
				i++
				inClass := false
				for i < len(s) {
					rc := s[i]
					if rc == '\\' {
						i += 2
						continue
					}
					if rc == '[' {
						inClass = true
					}
					if rc == ']' {
						inClass = false
					}
					if rc == '/' && !inClass {
						i++
						for i < len(s) && ((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z')) {
							i++
						}
						break
					}
					if rc == '\n' {
						break
					}
					i++
				}
				regexOK = false
				continue
			}
		}
		if c == '\'' || c == '"' || c == '`' {
			str = c
			regexOK = false
			i++
			continue
		}
		if c == '{' {
			depth++
			regexOK = true
			i++
			continue
		}
		if c == '}' {
			depth--
			if depth == 0 {
				return i + 1
			}
			regexOK = false
			i++
			continue
		}
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$' || c == ')' || c == ']' {
			regexOK = false
		} else if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			regexOK = true
		}
		i++
	}
	return -1
}

// legadoReplaceTemplates replaces every {{...}} span in s. fn gets the
// trimmed inner text and returns (replacement, true), or ("", false) to
// keep the original span untouched.
func legadoReplaceTemplates(s string, fn func(inner string) (string, bool)) string {
	var out strings.Builder
	i := 0
	for {
		j := strings.Index(s[i:], "{{")
		if j < 0 {
			out.WriteString(s[i:])
			break
		}
		start := i + j
		end := legadoTemplateSpan(s, start)
		if end < 0 {
			out.WriteString(s[i:])
			break
		}
		out.WriteString(s[i:start])
		inner := strings.TrimSpace(s[start+2 : end-2])
		if rep, ok := fn(inner); ok {
			out.WriteString(rep)
		} else {
			out.WriteString(s[start:end])
		}
		i = end
	}
	return out.String()
}

func legadoApplyPutGet(rule, block string, ctx *legadoJSCtx) string {
	rule = legadoPutRe.ReplaceAllStringFunc(rule, func(m string) string {
		sub := legadoPutRe.FindStringSubmatch(m)
		if len(sub) < 3 {
			return ""
		}
		key := strings.TrimSpace(sub[1])
		expr := strings.TrimSpace(sub[2])
		val := ""
		if expr != "" {
			if strings.HasPrefix(expr, "$") {
				val = legadoJSONFieldAny(block, expr)
			} else {
				val = legadoField(block, expr)
			}
		}
		ctx.vars[key] = val
		return ""
	})
	rule = legadoGetRe.ReplaceAllStringFunc(rule, func(m string) string {
		sub := legadoGetRe.FindStringSubmatch(m)
		if len(sub) < 2 {
			return ""
		}
		return ctx.vars[strings.TrimSpace(sub[1])]
	})
	return rule
}

func (c *legadoJSCtx) expandTemplates(s, block string) string {
	return legadoReplaceTemplates(s, func(inner string) (string, bool) {
		if inner == "" {
			return "", false
		}
		if strings.HasPrefix(inner, "book.") {
			switch inner {
			case "book.name":
				return c.bookTitle, true
			case "book.url":
				return c.bookURL, true
			}
			return "", true
		}
		if strings.HasPrefix(inner, "$") {
			return legadoJSONFieldAny(block, inner), true
		}
		rt := c.runtime()
		v, err := c.evalJSCur(inner, block)
		if err != nil {
			c.jsErr = err
			return "", true
		}
		return legadoJSValueString(rt, v), true
	})
}

func (c *legadoJSCtx) expandURLTemplate(tmpl string) string {
	tmpl = strings.ReplaceAll(tmpl, "{{page}}", strconv.Itoa(c.page))
	rt := c.runtime()
	return legadoReplaceTemplates(tmpl, func(inner string) (string, bool) {
		if inner == "" || strings.HasPrefix(inner, "$") {
			return "", false
		}
		v, err := c.evalJS(inner, rt.ToValue(""))
		if err != nil {
			c.jsErr = err
			return "", true
		}
		return legadoJSValueString(rt, v), true
	})
}

type legadoStage struct {
	js   bool
	text string
}

func legadoSplitStages(rule string) []legadoStage {
	var stages []legadoStage
	rest := rule
	for rest != "" {
		iJS := strings.Index(rest, "@js:")
		iTag := strings.Index(rest, "<js>")
		if iJS < 0 && iTag < 0 {
			stages = append(stages, legadoStage{js: false, text: rest})
			break
		}
		if iTag >= 0 && (iJS < 0 || iTag < iJS) {
			if iTag > 0 {
				stages = append(stages, legadoStage{js: false, text: rest[:iTag]})
			}
			end := strings.Index(rest[iTag+4:], "</js>")
			if end < 0 {
				stages = append(stages, legadoStage{js: true, text: rest[iTag+4:]})
				break
			}
			stages = append(stages, legadoStage{js: true, text: rest[iTag+4 : iTag+4+end]})
			rest = rest[iTag+4+end+5:]
			continue
		}
		if iJS > 0 {
			stages = append(stages, legadoStage{js: false, text: rest[:iJS]})
		}
		after := rest[iJS+4:]
		nextTag := strings.Index(after, "<js>")
		if nextTag < 0 {
			stages = append(stages, legadoStage{js: true, text: after})
			break
		}
		stages = append(stages, legadoStage{js: true, text: after[:nextTag]})
		rest = after[nextTag:]
	}
	out := []legadoStage{}
	for _, s := range stages {
		if strings.TrimSpace(s.text) == "" {
			continue
		}
		out = append(out, s)
	}
	return out
}

func legadoHasMarkers(rule string) bool {
	return strings.Contains(rule, "@js:") || strings.Contains(rule, "<js>") ||
		strings.Contains(rule, "@put:") || strings.Contains(rule, "@get:") ||
		strings.Contains(rule, "{{")
}

func (c *legadoJSCtx) evalSelectorScalar(cur, stageRule string) string {
	for _, line := range strings.Split(stageRule, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if v := legadoField(cur, line); v != "" {
			return v
		}
	}
	return ""
}

func (c *legadoJSCtx) evalScalar(block, rule string) string {
	if body, spec := legadoSplitReplace(rule); spec != nil {
		return legadoApplyReplace(c.evalScalarNoReplace(block, body), spec)
	}
	return c.evalScalarNoReplace(block, rule)
}

var legadoSingleBraceRe = regexp.MustCompile(`\{(\$\.[A-Za-z0-9_\.\[\]\*]+)\}`)

func legadoExpandSingleBrace(rule, block string) (string, bool) {
	if !legadoIsJSONBody(block) || strings.Contains(rule, "<js>") || strings.Contains(rule, "@js:") {
		return rule, false
	}
	locs := legadoSingleBraceRe.FindAllStringSubmatchIndex(rule, -1)
	if len(locs) == 0 {
		return rule, false
	}
	var out strings.Builder
	last := 0
	hit := false
	for _, loc := range locs {
		start, end, gstart, gend := loc[0], loc[1], loc[2], loc[3]
		if (start > 0 && rule[start-1] == '{') || (end < len(rule) && rule[end] == '}') {
			continue
		}
		out.WriteString(rule[last:start])
		out.WriteString(legadoJSONFieldAny(block, rule[gstart:gend]))
		last = end
		hit = true
	}
	if !hit {
		return rule, false
	}
	out.WriteString(rule[last:])
	return out.String(), true
}

func (c *legadoJSCtx) evalScalarNoReplace(block, rule string) string {
	hadTemplate := strings.Contains(rule, "{{") || strings.Contains(rule, "@get:")
	putRule := legadoApplyPutGet(rule, block, c)
	if single, ok := legadoExpandSingleBrace(putRule, block); ok {
		putRule = single
		hadTemplate = true
	}
	expanded := c.expandTemplates(putRule, block)
	probe := legadoPutRe.ReplaceAllString(rule, "")
	probe = legadoGetRe.ReplaceAllString(probe, "")
	probe = legadoReplaceTemplates(probe, func(string) (string, bool) { return "", true })
	if strings.TrimSpace(probe) == "" {
		return expanded
	}
	rule = expanded
	stages := legadoSplitStages(rule)
	if len(stages) == 0 {
		return ""
	}
	if len(stages) == 1 && !stages[0].js {
		if v := legadoField(block, stages[0].text); v != "" {
			return v
		}
		if hadTemplate {
			return expanded
		}
		return ""
	}
	cur := block
	for _, st := range stages {
		if st.js {
			rt := c.runtime()
			v, err := c.evalJSCur(st.text, cur)
			if err != nil {
				c.jsErr = err
				return ""
			}
			cur = legadoJSValueString(rt, v)
		} else {
			cur = c.evalSelectorScalar(cur, st.text)
		}
	}
	if cur == "" && hadTemplate {
		return expanded
	}
	return cur
}

func (c *legadoJSCtx) evalSelectorList(body, stageRule string) []string {
	alts := []string{}
	for _, alt := range strings.Split(stageRule, "||") {
		alt = strings.TrimSpace(alt)
		if alt != "" {
			alts = append(alts, alt)
		}
	}
	if legadoIsJSONBody(body) {
		for _, alt := range alts {
			if blocks := legadoJSONListBlocks(body, alt); len(blocks) > 0 {
				return blocks
			}
		}
	}
	for _, alt := range alts {
		for _, r := range strings.Split(alt, "\n") {
			r = strings.TrimSpace(r)
			if r == "" {
				continue
			}
			if strings.HasPrefix(r, "/") || strings.HasPrefix(r, "@XPath:") {
				if nodes, _, ok := legadoEvalXPath(body, r, true); ok && len(nodes) > 0 {
					blocks := []string{}
					for _, n := range nodes {
						blocks = append(blocks, hikerOuterHTML(n))
					}
					return blocks
				}
				continue
			}
			if nodes, _, ok := legadoEvalDialect(body, r, true); ok && len(nodes) > 0 {
				blocks := []string{}
				for _, n := range nodes {
					blocks = append(blocks, hikerOuterHTML(n))
				}
				return blocks
			}
			if blocks := hikerParseArray(body, legadoChain(legadoSplitSel(r))); len(blocks) > 0 {
				return blocks
			}
		}
	}
	return nil
}

func (c *legadoJSCtx) evalList(body, rule string) []string {
	c.setBlock(body)
	rule = legadoApplyPutGet(rule, body, c)
	rule = c.expandTemplates(rule, body)
	stages := legadoSplitStages(rule)
	if len(stages) == 0 {
		return nil
	}
	if len(stages) == 1 && !stages[0].js {
		return c.evalSelectorList(body, stages[0].text)
	}
	var cur interface{} = body
	for _, st := range stages {
		if st.js {
			rt := c.runtime()
			var resultVal goja.Value
			var out goja.Value
			var err error
			switch v := cur.(type) {
			case string:
				out, err = c.evalJSCur(st.text, v)
			case []string:
				elems := make([]goja.Value, len(v))
				for i, s := range v {
					elems[i] = rt.ToValue(s)
				}
				resultVal = c.jsArray(elems)
				out, err = c.evalJS(st.text, resultVal)
			default:
				out, err = c.evalJS(st.text, rt.ToValue(""))
			}
			if err != nil {
				c.jsErr = err
				return nil
			}
			if arr, ok := out.Export().([]interface{}); ok {
				blocks := []string{}
				for _, el := range arr {
					blocks = append(blocks, legadoJSExportString(el))
				}
				cur = blocks
			} else {
				cur = legadoJSValueString(rt, out)
			}
		} else {
			var input string
			switch v := cur.(type) {
			case string:
				input = v
			case []string:
				b, err := json.Marshal(v)
				if err != nil {
					return nil
				}
				input = string(b)
			}
			cur = c.evalSelectorList(input, st.text)
		}
	}
	switch v := cur.(type) {
	case []string:
		return v
	case string:
		if v == "" {
			return nil
		}
		return []string{v}
	}
	return nil
}

type legadoImage struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

func legadoSplitImageSrc(src, base string) legadoImage {
	img := legadoImage{URL: legadoAbs(base, strings.TrimSpace(src))}
	if i := strings.Index(src, ",{"); i >= 0 {
		img.URL = legadoAbs(base, strings.TrimSpace(src[:i]))
		var m map[string]interface{}
		if json.Unmarshal([]byte(strings.TrimSpace(src[i+1:])), &m) == nil {
			headers := map[string]string{}
			if h, ok := m["headers"].(map[string]interface{}); ok {
				for k, v := range h {
					if vs, ok := v.(string); ok {
						headers[k] = vs
					}
				}
			} else if h, ok := m["headers"].(string); ok {
				var hm map[string]interface{}
				if json.Unmarshal([]byte(h), &hm) == nil {
					for k, v := range hm {
						if vs, ok := v.(string); ok {
							headers[k] = vs
						}
					}
				}
			} else {
				for k, v := range m {
					if vs, ok := v.(string); ok {
						headers[k] = vs
					}
				}
			}
			if len(headers) > 0 {
				img.Headers = headers
			}
		}
	}
	return img
}

func legadoScanImgSrcs(contentHTML string) []string {
	srcs := []string{}
	lower := strings.ToLower(contentHTML)
	i := 0
	for {
		j := strings.Index(lower[i:], "<img")
		if j < 0 {
			break
		}
		i += j + 4
		gt := strings.Index(contentHTML[i:], ">")
		if gt < 0 {
			break
		}
		tag := contentHTML[i : i+gt]
		i += gt + 1
		ltag := strings.ToLower(tag)
		k := strings.Index(ltag, "src")
		if k < 0 {
			continue
		}
		rest := tag[k+3:]
		rest = strings.TrimLeft(rest, " \t\r\n")
		if !strings.HasPrefix(rest, "=") {
			continue
		}
		rest = strings.TrimLeft(rest[1:], " \t\r\n")
		if rest == "" {
			continue
		}
		q := rest[0]
		if q != '"' && q != '\'' {
			end := strings.IndexAny(rest, " \t\r\n>")
			if end < 0 {
				end = len(rest)
			}
			srcs = append(srcs, rest[:end])
			continue
		}
		body := rest[1:]
		val := ""
		for p := 0; p < len(body); {
			if body[p] == q {
				val = body[:p]
				break
			}
			if body[p] == ',' && p+1 < len(body) && body[p+1] == '{' {
				depth := 0
				inStr := false
				esc := false
				end := -1
				for x := p + 1; x < len(body); x++ {
					c := body[x]
					if inStr {
						if esc {
							esc = false
						} else if c == '\\' {
							esc = true
						} else if c == q {
							inStr = false
						}
						continue
					}
					if c == q {
						inStr = true
					} else if c == '{' {
						depth++
					} else if c == '}' {
						depth--
						if depth == 0 {
							end = x + 1
							break
						}
					}
				}
				if end < 0 {
					val = body[:p]
					break
				}
				val = body[:end]
				break
			}
			p++
		}
		if val == "" {
			val = body
			if e := strings.IndexByte(val, q); e >= 0 {
				val = val[:e]
			}
		}
		if val != "" {
			srcs = append(srcs, val)
		}
	}
	return srcs
}

func legadoExtractImages(contentHTML, base string) ([]legadoImage, string) {
	srcs := legadoScanImgSrcs(contentHTML)
	if len(srcs) == 0 {
		return nil, contentHTML
	}
	images := []legadoImage{}
	for _, src := range srcs {
		if src == "" {
			continue
		}
		img := legadoSplitImageSrc(src, base)
		if img.URL == "" {
			continue
		}
		if len(img.Headers) == 0 {
			img.Headers = map[string]string{"Referer": base}
		}
		images = append(images, img)
	}
	text := legadoHTMLToText(contentHTML)
	return images, text
}

var legadoKnownTags = map[string]bool{
	"a": true, "abbr": true, "address": true, "area": true, "article": true,
	"aside": true, "audio": true, "b": true, "base": true, "bdi": true,
	"bdo": true, "blockquote": true, "body": true, "br": true, "button": true,
	"canvas": true, "caption": true, "cite": true, "code": true, "col": true,
	"colgroup": true, "data": true, "datalist": true, "dd": true, "del": true,
	"details": true, "dfn": true, "dialog": true, "div": true, "dl": true,
	"dt": true, "em": true, "embed": true, "fieldset": true, "figcaption": true,
	"figure": true, "footer": true, "form": true, "h1": true, "h2": true,
	"h3": true, "h4": true, "h5": true, "h6": true, "head": true,
	"header": true, "hgroup": true, "hr": true, "html": true, "i": true,
	"iframe": true, "img": true, "input": true, "ins": true, "kbd": true,
	"label": true, "legend": true, "li": true, "link": true, "main": true,
	"map": true, "mark": true, "menu": true, "meta": true, "meter": true,
	"nav": true, "noscript": true, "object": true, "ol": true, "optgroup": true,
	"option": true, "output": true, "p": true, "picture": true, "pre": true,
	"progress": true, "q": true, "rp": true, "rt": true, "ruby": true,
	"s": true, "samp": true, "script": true, "section": true, "select": true,
	"small": true, "source": true, "span": true, "strong": true, "style": true,
	"sub": true, "summary": true, "sup": true, "table": true, "tbody": true,
	"td": true, "template": true, "textarea": true, "tfoot": true, "th": true,
	"thead": true, "time": true, "title": true, "tr": true, "track": true,
	"u": true, "ul": true, "var": true, "video": true, "wbr": true,
}

type legadoStep struct {
	tag          string
	classes      []string
	id           string
	textContains string
	attrName     string
	attrVal      string
	attrContains bool
	unionTagCls  bool
	child        bool
	index        int
	hasIndex     bool
	exclude      int
	hasExclude   bool
	nth          int
	nthOfType    bool
	hasNth       bool
	siblingSep   bool
}

var legadoNthRe = regexp.MustCompile(`:nth-(child|of-type)\((\d+)\)$`)

var legadoNthAnyRe = regexp.MustCompile(`:nth-(child|of-type)\(\d+\)`)

func legadoStripNth(part string) (string, legadoStep) {
	st := legadoStep{}
	if m := legadoNthRe.FindStringSubmatch(part); m != nil {
		n, err := strconv.Atoi(m[2])
		if err == nil {
			st.nth = n
			st.nthOfType = m[1] == "of-type"
			st.hasNth = true
			part = part[:len(part)-len(m[0])]
		}
	}
	return part, st
}

type legadoLevel struct {
	alts [][]legadoStep
}

func legadoIsDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func legadoIsIntToken(s string) bool {
	if s == "" {
		return false
	}
	if s[0] == '-' {
		return legadoIsDigits(s[1:])
	}
	return legadoIsDigits(s)
}

func legadoParseDialectStep(part string) (legadoStep, bool) {
	part = strings.TrimSpace(part)
	if part == "" {
		return legadoStep{}, false
	}
	if part == "~" {
		return legadoStep{siblingSep: true}, true
	}
	part, nthSt := legadoStripNth(part)
	st := legadoStep{nth: nthSt.nth, nthOfType: nthSt.nthOfType, hasNth: nthSt.hasNth}
	if i := strings.Index(part, "!"); i >= 0 {
		exclStr := part[i+1:]
		n, err := strconv.Atoi(exclStr)
		if err != nil {
			return legadoStep{}, false
		}
		st.exclude = n
		st.hasExclude = true
		part = part[:i]
		if part == "" {
			return legadoStep{}, false
		}
	}
	toks := strings.Split(part, ".")
	head := toks[0]
	rest := []string{}
	if len(toks) > 1 {
		rest = toks[1:]
	}
	addID := func(v string) bool {
		if v == "" {
			return false
		}
		st.id = v
		return true
	}
	switch {
	case head == "class":
		if len(toks) < 2 || toks[1] == "" {
			return legadoStep{}, false
		}
		st.classes = append(st.classes, toks[1])
		rest = toks[2:]
	case head == "tag":
		if len(toks) < 2 || toks[1] == "" {
			return legadoStep{}, false
		}
		st.tag = strings.ToLower(toks[1])
		rest = toks[2:]
	case head == "id":
		if len(toks) < 2 || toks[1] == "" {
			return legadoStep{}, false
		}
		st.id = toks[1]
		rest = toks[2:]
	case head == "text":
		if len(toks) < 2 || toks[1] == "" {
			return legadoStep{}, false
		}
		st.textContains = strings.Join(toks[1:], ".")
		rest = nil
	case head == "":
		if len(toks) < 2 || toks[1] == "" {
			return legadoStep{}, false
		}
		st.classes = append(st.classes, toks[1])
		rest = toks[2:]
	case strings.HasPrefix(head, "#"):
		if !addID(head[1:]) {
			return legadoStep{}, false
		}
	case strings.Contains(head, "#"):
		parts := strings.SplitN(head, "#", 2)
		if parts[0] != "" {
			st.tag = strings.ToLower(parts[0])
		}
		if !addID(parts[1]) {
			return legadoStep{}, false
		}
	case legadoKnownTags[strings.ToLower(head)]:
		st.tag = strings.ToLower(head)
	case len(toks) == 1:
		st.unionTagCls = true
		st.tag = strings.ToLower(head)
		st.classes = append(st.classes, head)
	default:
		st.tag = strings.ToLower(head)
	}
	for _, t := range rest {
		if t == "" {
			return legadoStep{}, false
		}
		if strings.Contains(t, "#") {
			parts := strings.SplitN(t, "#", 2)
			if parts[0] != "" {
				st.classes = append(st.classes, parts[0])
			}
			if !addID(parts[1]) {
				return legadoStep{}, false
			}
			continue
		}
		if legadoIsIntToken(t) {
			n, err := strconv.Atoi(t)
			if err != nil {
				return legadoStep{}, false
			}
			st.index = n
			st.hasIndex = true
			continue
		}
		st.classes = append(st.classes, t)
	}
	return st, true
}

func legadoParseDialectLevel(seg string) ([]legadoStep, bool) {
	seg = strings.TrimSpace(seg)
	if seg == "" {
		return nil, false
	}
	cleaned := legadoNthAnyRe.ReplaceAllString(seg, "")
	if strings.ContainsAny(cleaned, ">,[\"':(") {
		return nil, false
	}
	subs := strings.Fields(seg)
	if len(subs) == 0 {
		return nil, false
	}
	steps := []legadoStep{}
	for _, sub := range subs {
		st, ok := legadoParseDialectStep(sub)
		if !ok {
			return nil, false
		}
		steps = append(steps, st)
	}
	return steps, true
}

func legadoIsValueToken(s string) bool {
	switch s {
	case "text", "html", "ownText", "textNodes", "all", "outerHtml":
		return true
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func legadoParseDialect(rule string, forElements bool) ([]legadoLevel, string, bool) {
	rule = strings.TrimSpace(rule)
	if rule == "" {
		return nil, "", false
	}
	rule = strings.TrimPrefix(rule, "@@")
	rule = strings.TrimPrefix(rule, "@CSS:")
	parts := strings.Split(rule, "@")
	if len(parts) == 0 {
		return nil, "", false
	}
	if strings.HasPrefix(parts[0], "+") || strings.HasPrefix(parts[0], "-") {
		parts[0] = parts[0][1:]
	}
	value := "text"
	stepParts := parts
	if !forElements && len(parts) > 1 {
		last := parts[len(parts)-1]
		if legadoIsValueToken(last) {
			value = last
			stepParts = parts[:len(parts)-1]
		} else if strings.HasPrefix(last, "tag.") || strings.HasPrefix(last, "class.") || strings.HasPrefix(last, "id.") {
			value = "text"
		} else if strings.Contains(last, ".") {
			value = "text"
		} else if legadoKnownTags[strings.ToLower(last)] {
			value = "text"
		} else {
			value = last
			stepParts = parts[:len(parts)-1]
		}
	}
	if len(stepParts) == 0 {
		return nil, "", false
	}
	levels := []legadoLevel{}
	for _, seg := range stepParts {
		alts := [][]legadoStep{}
		for _, altSeg := range strings.Split(seg, "&&") {
			steps, ok := legadoParseDialectLevel(altSeg)
			if !ok {
				return nil, "", false
			}
			alts = append(alts, steps)
		}
		levels = append(levels, legadoLevel{alts: alts})
	}
	return levels, value, true
}

func legadoNodeMatches(n *html.Node, st legadoStep) bool {
	if n.Type != html.ElementNode {
		return false
	}
	if st.tag != "" && !st.unionTagCls && n.Data != st.tag {
		return false
	}
	if st.unionTagCls {
		hit := n.Data == st.tag
		if !hit {
			for _, c := range strings.Fields(legadoAttrVal(n, "class")) {
				if c == st.classes[0] {
					hit = true
					break
				}
			}
		}
		if !hit {
			return false
		}
	} else {
		for _, c := range st.classes {
			found := false
			for _, f := range strings.Fields(legadoAttrVal(n, "class")) {
				if f == c {
					found = true
					break
				}
			}
			if !found {
				return false
			}
		}
	}
	if st.id != "" && legadoAttrVal(n, "id") != st.id {
		return false
	}
	if st.textContains != "" && !strings.Contains(hikerNodeText(n), st.textContains) {
		return false
	}
	if st.attrName != "" {
		v, ok := hikerAttr(n, st.attrName)
		if !ok {
			return false
		}
		if st.attrContains {
			if !strings.Contains(v, st.attrVal) {
				return false
			}
		} else if v != st.attrVal {
			return false
		}
	}
	return true
}

func legadoAttrVal(n *html.Node, name string) string {
	if v, ok := hikerAttr(n, name); ok {
		return v
	}
	return ""
}

func legadoDescendants(n *html.Node, st legadoStep, out *[]*html.Node) {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.ElementNode && legadoNodeMatches(c, st) {
			*out = append(*out, c)
		}
		legadoDescendants(c, st, out)
	}
}

func legadoNthMatch(n *html.Node, st legadoStep) bool {
	idx := 0
	for s := n.PrevSibling; s != nil; s = s.PrevSibling {
		if s.Type != html.ElementNode {
			continue
		}
		if st.nthOfType && s.Data != n.Data {
			continue
		}
		idx++
	}
	return idx+1 == st.nth
}

func legadoFilterNth(nodes []*html.Node, st legadoStep) []*html.Node {
	if !st.hasNth {
		return nodes
	}
	out := []*html.Node{}
	for _, n := range nodes {
		if legadoNthMatch(n, st) {
			out = append(out, n)
		}
	}
	return out
}

func legadoApplyStep(cur []*html.Node, st legadoStep, order map[*html.Node]int) []*html.Node {
	if st.child {
		var out []*html.Node
		for _, parent := range cur {
			var matched []*html.Node
			for c := parent.FirstChild; c != nil; c = c.NextSibling {
				if c.Type == html.ElementNode && legadoNodeMatches(c, st) {
					matched = append(matched, c)
				}
			}
			matched = legadoFilterNth(matched, st)
			if st.hasExclude {
				idx := st.exclude
				if idx < 0 {
					idx = len(matched) + idx
				}
				if idx >= 0 && idx < len(matched) {
					matched = append(matched[:idx], matched[idx+1:]...)
				}
			}
			if st.hasIndex {
				idx := st.index
				if idx < 0 {
					idx = len(matched) + idx
				}
				if idx >= 0 && idx < len(matched) {
					matched = []*html.Node{matched[idx]}
				} else {
					matched = nil
				}
			}
			out = append(out, matched...)
		}
		return out
	}
	var out []*html.Node
	for _, parent := range cur {
		legadoDescendants(parent, st, &out)
	}
	out = legadoFilterNth(out, st)
	if st.hasExclude {
		idx := st.exclude
		if idx < 0 {
			idx = len(out) + idx
		}
		if idx >= 0 && idx < len(out) {
			out = append(out[:idx], out[idx+1:]...)
		}
	}
	if st.hasIndex {
		idx := st.index
		if idx < 0 {
			idx = len(out) + idx
		}
		if idx >= 0 && idx < len(out) {
			out = []*html.Node{out[idx]}
		} else {
			out = nil
		}
	}
	return out
}

func legadoApplyStepSibling(cur []*html.Node, st legadoStep, order map[*html.Node]int) []*html.Node {
	var out []*html.Node
	for _, n := range cur {
		var matched []*html.Node
		for s := n.NextSibling; s != nil; s = s.NextSibling {
			if s.Type == html.ElementNode && legadoNodeMatches(s, st) {
				matched = append(matched, s)
			}
		}
		matched = legadoFilterNth(matched, st)
		if st.hasExclude {
			idx := st.exclude
			if idx < 0 {
				idx = len(matched) + idx
			}
			if idx >= 0 && idx < len(matched) {
				matched = append(matched[:idx], matched[idx+1:]...)
			}
		}
		if st.hasIndex {
			idx := st.index
			if idx < 0 {
				idx = len(matched) + idx
			}
			if idx >= 0 && idx < len(matched) {
				matched = []*html.Node{matched[idx]}
			} else {
				matched = nil
			}
		}
		out = append(out, matched...)
	}
	return out
}

func legadoWalkLevels(doc *html.Node, order map[*html.Node]int, levels []legadoLevel) []*html.Node {
	cur := []*html.Node{doc}
	for _, lvl := range levels {
		seen := map[*html.Node]bool{}
		var merged []*html.Node
		for _, alt := range lvl.alts {
			nodes := cur
			sibling := false
			for _, st := range alt {
				if st.siblingSep {
					sibling = true
					continue
				}
				if sibling {
					nodes = legadoApplyStepSibling(nodes, st, order)
					sibling = false
				} else {
					nodes = legadoApplyStep(nodes, st, order)
				}
				if len(nodes) == 0 {
					break
				}
			}
			for _, n := range nodes {
				if !seen[n] {
					seen[n] = true
					merged = append(merged, n)
				}
			}
		}
		if order != nil && len(merged) > 1 {
			for i := 1; i < len(merged); i++ {
				for j := i; j > 0 && order[merged[j]] < order[merged[j-1]]; j-- {
					merged[j], merged[j-1] = merged[j-1], merged[j]
				}
			}
		}
		cur = merged
		if len(cur) == 0 {
			break
		}
	}
	return cur
}

func legadoParseDoc(htmlText string) (*html.Node, map[*html.Node]int) {
	doc, err := html.Parse(strings.NewReader(htmlText))
	if err != nil {
		return nil, nil
	}
	order := map[*html.Node]int{}
	i := 0
	var walk func(n *html.Node)
	walk = func(n *html.Node) {
		order[n] = i
		i++
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	return doc, order
}

func legadoBlockRoot(doc *html.Node) *html.Node {
	var body *html.Node
	var walk func(n *html.Node)
	walk = func(n *html.Node) {
		if body != nil {
			return
		}
		if n.Type == html.ElementNode && n.Data == "body" {
			body = n
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	if body != nil {
		for c := body.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html.ElementNode {
				return c
			}
		}
	}
	var first *html.Node
	walk = func(n *html.Node) {
		if first != nil {
			return
		}
		if n.Type == html.ElementNode {
			first = n
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	return first
}

func legadoNodeOwnText(n *html.Node) string {
	parts := []string{}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.TextNode {
			if s := strings.TrimSpace(c.Data); s != "" {
				parts = append(parts, s)
			}
		}
	}
	return strings.Join(parts, " ")
}

func legadoNodeTextNodes(n *html.Node) string {
	parts := []string{}
	var walk func(x *html.Node)
	walk = func(x *html.Node) {
		if x.Type == html.TextNode {
			if s := strings.TrimSpace(x.Data); s != "" {
				parts = append(parts, s)
			}
			return
		}
		for c := x.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return strings.Join(parts, "\n")
}

func legadoScalarFromNodes(nodes []*html.Node, value string) string {
	if len(nodes) == 0 {
		return ""
	}
	switch value {
	case "html", "all", "outerHtml":
		parts := []string{}
		for _, n := range nodes {
			parts = append(parts, hikerOuterHTML(n))
		}
		return strings.Join(parts, "")
	case "ownText":
		parts := []string{}
		for _, n := range nodes {
			if s := legadoNodeOwnText(n); s != "" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, "\n")
	case "textNodes":
		parts := []string{}
		for _, n := range nodes {
			if s := legadoNodeTextNodes(n); s != "" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, "\n")
	case "text", "":
		parts := []string{}
		for _, n := range nodes {
			if s := strings.TrimSpace(hikerNodeText(n)); s != "" {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, "\n")
	default:
		parts := []string{}
		for _, n := range nodes {
			if v, ok := hikerAttr(n, value); ok {
				parts = append(parts, v)
			}
		}
		return strings.Join(parts, "\n")
	}
}

func legadoEvalDialect(htmlText, rule string, forElements bool) ([]*html.Node, string, bool) {
	levels, value, ok := legadoParseDialect(rule, forElements)
	if !ok {
		return nil, "", false
	}
	doc, order := legadoParseDoc(htmlText)
	if doc == nil {
		return nil, "", false
	}
	nodes := legadoWalkLevels(doc, order, levels)
	return nodes, value, true
}

var legadoXPathStepRe = regexp.MustCompile(`^([A-Za-z0-9_\-\*]+)(\[(.*)\])?$`)

func legadoParseXPathPred(pred string, st *legadoStep) bool {
	pred = strings.TrimSpace(pred)
	if pred == "" {
		return false
	}
	if legadoIsDigits(pred) {
		n, err := strconv.Atoi(pred)
		if err != nil || n < 1 {
			return false
		}
		st.index = n - 1
		st.hasIndex = true
		return true
	}
	if strings.HasPrefix(pred, "contains(") && strings.HasSuffix(pred, ")") {
		inner := pred[len("contains(") : len(pred)-1]
		parts := strings.SplitN(inner, ",", 2)
		if len(parts) != 2 {
			return false
		}
		attr := strings.TrimSpace(parts[0])
		val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
		if !strings.HasPrefix(attr, "@") {
			return false
		}
		st.attrName = attr[1:]
		st.attrVal = val
		st.attrContains = true
		return true
	}
	if strings.HasPrefix(pred, "@") {
		eq := strings.Index(pred, "=")
		if eq < 0 {
			return false
		}
		attr := pred[1:eq]
		val := strings.Trim(strings.TrimSpace(pred[eq+1:]), `"'`)
		if attr == "class" {
			st.classes = append(st.classes, val)
			return true
		}
		if attr == "id" {
			st.id = val
			return true
		}
		st.attrName = attr
		st.attrVal = val
		return true
	}
	return false
}

func legadoParseXPathOne(xpath string) ([]legadoLevel, string, bool) {
	xpath = strings.TrimSpace(xpath)
	xpath = strings.TrimPrefix(xpath, "@XPath:")
	value := "text"
	steps := []legadoStep{}
	i := 0
	for i < len(xpath) {
		child := false
		if strings.HasPrefix(xpath[i:], "//") {
			i += 2
		} else if xpath[i] == '/' {
			child = true
			i++
		} else {
			return nil, "", false
		}
		if i >= len(xpath) {
			return nil, "", false
		}
		if strings.HasPrefix(xpath[i:], "text()") {
			value = "text"
			i += len("text()")
			break
		}
		if xpath[i] == '@' {
			j := i + 1
			for j < len(xpath) && xpath[j] != '/' {
				j++
			}
			value = xpath[i+1 : j]
			i = j
			break
		}
		j := i
		depth := 0
		for j < len(xpath) {
			if xpath[j] == '[' {
				depth++
			} else if xpath[j] == ']' {
				depth--
			} else if xpath[j] == '/' && depth == 0 {
				break
			}
			j++
		}
		token := xpath[i:j]
		i = j
		m := legadoXPathStepRe.FindStringSubmatch(token)
		if m == nil {
			return nil, "", false
		}
		st := legadoStep{child: child}
		if m[1] != "*" {
			st.tag = strings.ToLower(m[1])
		}
		if m[3] != "" {
			if !legadoParseXPathPred(m[3], &st) {
				return nil, "", false
			}
		}
		steps = append(steps, st)
	}
	if len(steps) == 0 {
		return nil, "", false
	}
	levels := []legadoLevel{}
	for _, st := range steps {
		levels = append(levels, legadoLevel{alts: [][]legadoStep{{st}}})
	}
	return levels, value, true
}

func legadoSplitXPathUnion(xpath string) []string {
	parts := []string{}
	depth := 0
	var quote byte
	start := 0
	for i := 0; i < len(xpath); i++ {
		c := xpath[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
		case '[':
			depth++
		case ']':
			depth--
		case '|':
			if depth == 0 {
				parts = append(parts, xpath[start:i])
				start = i + 1
			}
		}
	}
	parts = append(parts, xpath[start:])
	return parts
}

func legadoEvalXPath(htmlText, xpath string, forElements bool) ([]*html.Node, string, bool) {
	doc, order := legadoParseDoc(htmlText)
	if doc == nil {
		return nil, "", false
	}
	seen := map[*html.Node]bool{}
	var nodes []*html.Node
	value := "text"
	for _, part := range legadoSplitXPathUnion(xpath) {
		levels, v, ok := legadoParseXPathOne(part)
		if !ok {
			continue
		}
		value = v
		for _, n := range legadoWalkLevels(doc, order, levels) {
			if !seen[n] {
				seen[n] = true
				nodes = append(nodes, n)
			}
		}
	}
	if len(nodes) == 0 {
		return nil, "", false
	}
	return nodes, value, true
}

func legadoSplitReplace(rule string) (string, []string) {
	parts := strings.Split(rule, "##")
	if len(parts) == 1 {
		return rule, nil
	}
	return parts[0], parts[1:]
}

func legadoApplyReplace(s string, spec []string) string {
	for i := 0; i < len(spec); i += 2 {
		pat := spec[i]
		rep := ""
		if i+1 < len(spec) {
			rep = spec[i+1]
		}
		re, err := regexp.Compile(pat)
		if err != nil {
			continue
		}
		s = re.ReplaceAllString(s, rep)
	}
	return s
}

var legadoImageExtRe = regexp.MustCompile(`(?i)\.(jpg|jpeg|png|webp|gif|bmp|avif)(\?.*)?$`)

func legadoExtractBareImageLines(text, base string, fullStyle bool) ([]legadoImage, string) {
	lines := strings.Split(text, "\n")
	images := []legadoImage{}
	rest := []string{}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.Contains(line, " ") {
			if line != "" {
				rest = append(rest, line)
			}
			continue
		}
		urlPart := line
		if i := strings.Index(line, ",{"); i >= 0 {
			urlPart = line[:i]
		}
		isImg := false
		if strings.HasPrefix(urlPart, "http://") || strings.HasPrefix(urlPart, "https://") {
			isImg = fullStyle || legadoImageExtRe.MatchString(urlPart)
		} else if fullStyle && strings.HasPrefix(urlPart, "/") {
			isImg = true
		} else if fullStyle && strings.Contains(urlPart, "/") && legadoImageExtRe.MatchString(urlPart) {
			isImg = true
		}
		if !isImg {
			rest = append(rest, line)
			continue
		}
		img := legadoSplitImageSrc(line, base)
		if img.URL == "" {
			rest = append(rest, line)
			continue
		}
		if len(img.Headers) == 0 {
			img.Headers = map[string]string{"Referer": base}
		}
		images = append(images, img)
	}
	return images, strings.Join(rest, "\n")
}
