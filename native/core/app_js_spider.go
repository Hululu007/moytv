package core

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

type jsSpiderCtx struct {
	rt        *goja.Runtime
	client    *http.Client
	result    goja.Value
	resultSet bool
}

func jsSpiderHTTPClient() *http.Client {
	jar, _ := cookiejar.New(nil)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// 直连：显式置 nil，不继承环境变量代理。
	transport.Proxy = nil
	return &http.Client{
		Transport: transport,
		Jar:       jar,
		Timeout:   25 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many redirects")
			}
			return nil
		},
	}
}

func jsValueString(v goja.Value) string {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return ""
	}
	return v.String()
}

// jsFetchRequest 是 request/req/fetch 三个取数入口的公共参数形态。
type jsFetchRequest struct {
	url     string
	method  string
	body    string
	headers map[string]string
	buffer  int
}

// jsFetchBufferMode 把脚本传入的 buffer 选项归一成 0–3 模式：
// 0 文本、1 字节数组、2 Base64、3 原始字节（与 easytv/CatVod 的
// req options.buffer 口径一致）。旧写法 buffer:true 按 Base64（2）
// 兼容，false/缺省为文本（0）；数字字符串同样认。
func jsFetchBufferMode(value interface{}) int {
	switch v := value.(type) {
	case bool:
		if v {
			return 2
		}
		return 0
	case float64:
		return jsFetchBufferClamp(int(v))
	case int64:
		return jsFetchBufferClamp(int(v))
	case string:
		trimmed := strings.TrimSpace(v)
		if n, err := strconv.Atoi(trimmed); err == nil {
			return jsFetchBufferClamp(n)
		}
		if trimmed != "" && !strings.EqualFold(trimmed, "false") {
			return 2
		}
		return 0
	default:
		return 0
	}
}

func jsFetchBufferClamp(mode int) int {
	if mode < 0 {
		return 0
	}
	if mode > 3 {
		return 3
	}
	return mode
}

func jsFetchParseArgs(call goja.FunctionCall) jsFetchRequest {
	req := jsFetchRequest{method: "GET", headers: map[string]string{}}
	if len(call.Arguments) > 0 {
		if exported := call.Arguments[0].Export(); exported != nil {
			switch val := exported.(type) {
			case string:
				req.url = val
			case map[string]interface{}:
				if u, ok := val["url"].(string); ok {
					req.url = u
				}
				if m, ok := val["method"].(string); ok && m != "" {
					req.method = strings.ToUpper(m)
				}
				if b, ok := val["body"].(string); ok {
					req.body = b
				}
				if d, ok := val["data"]; ok && req.body == "" {
					req.body, req.method = jsFetchEncodeData(d, req.method, val)
					jsFetchEnsureContentType(&req, val)
				}
				if h, ok := val["headers"].(map[string]interface{}); ok {
					for k, hv := range h {
						req.headers[k] = fmt.Sprint(hv)
					}
				}
				if buf, ok := val["buffer"]; ok {
					req.buffer = jsFetchBufferMode(buf)
				}
				if params, ok := val["params"].(map[string]interface{}); ok && req.url != "" {
					req.url = jsFetchAppendParams(req.url, params)
				}
			}
		}
	}
	if len(call.Arguments) > 1 {
		if exported := call.Arguments[1].Export(); exported != nil {
			if h, ok := exported.(map[string]interface{}); ok {
				if jsFetchIsOptionsMap(h) {
					jsFetchApplyOptions(&req, h)
				} else {
					for k, hv := range h {
						req.headers[k] = fmt.Sprint(hv)
					}
				}
			} else if s, ok := exported.(string); ok && s != "" {
				req.body = s
			}
		}
	}
	if req.method == "" {
		req.method = "GET"
	}
	return req
}

// jsFetchIsOptionsMap 区分第二参数的两种形态：纯 headers 映射（旧契约，
// 键全是请求头）与 options 对象（含 data/method/headers/buffer 等键）。
func jsFetchIsOptionsMap(h map[string]interface{}) bool {
	for _, key := range []string{"data", "method", "headers", "buffer", "body", "params", "url"} {
		if _, ok := h[key]; ok {
			return true
		}
	}
	return false
}

// jsFetchApplyOptions 把 options 对象里的字段分别落到请求上：嵌套 headers
// 展开、data 编码成请求体、method/buffer/body 生效；options 自身的键不
// 当成请求头。
func jsFetchApplyOptions(req *jsFetchRequest, h map[string]interface{}) {
	if nested, ok := h["headers"].(map[string]interface{}); ok {
		for k, hv := range nested {
			req.headers[k] = fmt.Sprint(hv)
		}
	}
	if m, ok := h["method"].(string); ok && m != "" {
		req.method = strings.ToUpper(m)
	}
	if buf, ok := h["buffer"]; ok {
		req.buffer = jsFetchBufferMode(buf)
	}
	if b, ok := h["body"].(string); ok && b != "" {
		req.body = b
	}
	if d, ok := h["data"]; ok && req.body == "" {
		req.body, req.method = jsFetchEncodeData(d, req.method, h)
		jsFetchEnsureContentType(req, h)
	}
	if params, ok := h["params"].(map[string]interface{}); ok && req.url != "" {
		req.url = jsFetchAppendParams(req.url, params)
	}
}

// jsFetchEnsureContentType：data 编码出的请求体若无显式 Content-Type，
// 按编码形态补一个（表单体补 form，JSON 体补 json），服务端才能解析。
func jsFetchEnsureContentType(req *jsFetchRequest, options map[string]interface{}) {
	for k := range req.headers {
		if strings.EqualFold(k, "Content-Type") {
			return
		}
	}
	contentType := "application/x-www-form-urlencoded"
	if h, ok := options["headers"].(map[string]interface{}); ok {
		for k, hv := range h {
			if strings.EqualFold(k, "Content-Type") && strings.Contains(strings.ToLower(fmt.Sprint(hv)), "application/json") {
				contentType = "application/json"
			}
		}
	}
	if strings.HasPrefix(strings.TrimSpace(req.body), "{") {
		contentType = "application/json"
	}
	req.headers["Content-Type"] = contentType
}

// 声明 application/json 时编成 JSON。data 出现且方法仍是 GET 时改 POST。
func jsFetchEncodeData(data interface{}, method string, options map[string]interface{}) (string, string) {
	if method == "" || method == "GET" {
		method = "POST"
	}
	contentType := ""
	if h, ok := options["headers"].(map[string]interface{}); ok {
		for k, hv := range h {
			if strings.EqualFold(k, "Content-Type") {
				contentType = fmt.Sprint(hv)
			}
		}
	}
	if m, ok := data.(map[string]interface{}); ok {
		if strings.Contains(strings.ToLower(contentType), "application/json") {
			if body, err := json.Marshal(m); err == nil {
				return string(body), method
			}
		}
		parts := []string{}
		for k, v := range m {
			parts = append(parts, fmt.Sprintf("%s=%s", jsFetchFormEscape(k), jsFetchFormEscape(fmt.Sprint(v))))
		}
		return strings.Join(parts, "&"), method
	}
	return fmt.Sprint(data), method
}

func jsFetchFormEscape(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(s, "%", "%25"), "&", "%26"), "=", "%3D")
}

func jsFetchAppendParams(rawURL string, params map[string]interface{}) string {
	if len(params) == 0 {
		return rawURL
	}
	sep := "?"
	if strings.Contains(rawURL, "?") {
		sep = "&"
	}
	parts := []string{}
	for k, v := range params {
		parts = append(parts, fmt.Sprintf("%s=%s", jsFetchFormEscape(k), jsFetchFormEscape(fmt.Sprint(v))))
	}
	return rawURL + sep + strings.Join(parts, "&")
}

func (c *jsSpiderCtx) jsDoFetch(req jsFetchRequest) (int, map[string]string, []byte, error) {
	var reader io.Reader
	if req.body != "" {
		reader = strings.NewReader(req.body)
	}
	httpReq, err := http.NewRequest(req.method, req.url, reader)
	if err != nil {
		return 0, nil, nil, err
	}
	httpReq.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36")
	httpReq.Header.Set("Accept", "*/*")
	for k, v := range req.headers {
		httpReq.Header.Set(k, v)
	}
	resp, err := c.client.Do(httpReq)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return 0, nil, nil, err
	}
	headers := map[string]string{}
	for k, values := range resp.Header {
		if len(values) > 0 {
			headers[k] = values[0]
		}
	}
	return resp.StatusCode, headers, data, nil
}

// jsResponseObject 按 buffer 模式组装 req/fetch 的响应对象：
//   - 0 文本：content 为响应文本；
//   - 1 字节数组：goja 侧字节数组的表示尚未定，先按 Base64 与 2 同
//     处理（与旧的非 0 即 Base64 行为一致），脚本拿到的是无损编码，
//     不会是被错误解码的文本；
//   - 2 Base64：content 为响应的 Base64 文本；
//   - 3 原始字节：content 为字节数组（数字数组，content[i]/length 可用）。
//
// code 与 status/statusCode 同值并存：easytv/CatVod 习惯读 .code，
// 旧脚本读 .status，两边都给。
func (c *jsSpiderCtx) jsResponseObject(status int, headers map[string]string, body []byte, bufferMode int) goja.Value {
	rt := c.rt
	content := string(body)
	var contentValue goja.Value
	switch bufferMode {
	case 1, 2:
		content = base64.StdEncoding.EncodeToString(body)
		contentValue = rt.ToValue(content)
	case 3:
		bytes := make([]interface{}, len(body))
		for i, b := range body {
			bytes[i] = int(b)
		}
		contentValue = rt.ToValue(bytes)
	default:
		contentValue = rt.ToValue(content)
	}
	obj := rt.NewObject()
	_ = obj.Set("content", contentValue)
	_ = obj.Set("code", status)
	_ = obj.Set("status", status)
	_ = obj.Set("statusCode", status)
	_ = obj.Set("ok", status >= 200 && status < 300)
	_ = obj.Set("headers", rt.ToValue(headers))
	_ = obj.Set("text", func(goja.FunctionCall) goja.Value { return rt.ToValue(content) })
	_ = obj.Set("json", func(goja.FunctionCall) goja.Value {
		var decoded interface{}
		if err := json.Unmarshal(body, &decoded); err != nil {
			return goja.Undefined()
		}
		return rt.ToValue(decoded)
	})
	_ = obj.Set("toString", func(goja.FunctionCall) goja.Value { return rt.ToValue(content) })
	return obj
}

func (c *jsSpiderCtx) request(call goja.FunctionCall) goja.Value {
	req := jsFetchParseArgs(call)
	if req.url == "" {
		return c.rt.ToValue("")
	}
	_, _, data, err := c.jsDoFetch(req)
	if err != nil {
		return c.rt.ToValue("")
	}
	return c.rt.ToValue(string(data))
}

// jsReq 是 CatVod cat 形态的 req/fetch：返回带 content 的响应对象，
// 与 spider/catLib/http.js 的同步 http 契约一致（options.buffer 按
// 0–3 模式分流，见 jsResponseObject；样本里 req(url, {buffer: 2})
// 的 content 为 Base64）。
func (c *jsSpiderCtx) jsReq(call goja.FunctionCall) goja.Value {
	req := jsFetchParseArgs(call)
	if req.url == "" {
		return c.jsResponseObject(0, map[string]string{}, nil, 0)
	}
	status, headers, data, err := c.jsDoFetch(req)
	if err != nil {
		return c.jsResponseObject(0, map[string]string{}, nil, 0)
	}
	return c.jsResponseObject(status, headers, data, req.buffer)
}

func jsHTMLText(n *html.Node) string {
	var buf bytes.Buffer
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if node.Type == html.TextNode {
			buf.WriteString(node.Data)
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(n)
	cleaned := regexp.MustCompile(`\s+`).ReplaceAllString(buf.String(), " ")
	return strings.TrimSpace(cleaned)
}

func jsHTMLOuter(n *html.Node) string {
	var buf bytes.Buffer
	if err := html.Render(&buf, n); err != nil {
		return ""
	}
	return buf.String()
}

type jsSelector struct {
	tag     string
	id      string
	classes []string
	attrs   map[string]string
	attrAny []string
}

func jsParseSimpleSelector(part string) (jsSelector, bool) {
	sel := jsSelector{attrs: map[string]string{}}
	rest := part
	for {
		start := strings.Index(rest, "[")
		if start < 0 {
			break
		}
		end := strings.Index(rest[start:], "]")
		if end < 0 {
			return sel, false
		}
		inner := rest[start+1 : start+end]
		if eq := strings.Index(inner, "="); eq >= 0 {
			key := strings.TrimSpace(inner[:eq])
			val := strings.Trim(strings.TrimSpace(inner[eq+1:]), `"'`)
			sel.attrs[key] = val
		} else {
			sel.attrAny = append(sel.attrAny, strings.TrimSpace(inner))
		}
		rest = rest[:start] + rest[start+end+1:]
	}
	if idx := strings.Index(rest, "#"); idx >= 0 {
		head := rest[:idx]
		tail := rest[idx+1:]
		if dot := strings.Index(tail, "."); dot >= 0 {
			sel.id = tail[:dot]
			rest = head + tail[dot:]
		} else {
			sel.id = tail
			rest = head
		}
	}
	parts := strings.Split(rest, ".")
	if len(parts) > 0 && parts[0] != "" {
		sel.tag = strings.ToLower(parts[0])
	}
	for _, cls := range parts[1:] {
		if cls != "" {
			sel.classes = append(sel.classes, cls)
		}
	}
	if len(parts) > 0 && parts[0] == "" && sel.tag == "" {
		sel.tag = ""
	}
	return sel, true
}

func jsNodeMatches(n *html.Node, sel jsSelector) bool {
	if n.Type != html.ElementNode {
		return false
	}
	if sel.tag != "" && sel.tag != "*" && n.Data != sel.tag {
		return false
	}
	attrMap := map[string]string{}
	for _, a := range n.Attr {
		attrMap[a.Key] = a.Val
	}
	if sel.id != "" && attrMap["id"] != sel.id {
		return false
	}
	if len(sel.classes) > 0 {
		have := map[string]bool{}
		for _, cls := range strings.Fields(attrMap["class"]) {
			have[cls] = true
		}
		for _, want := range sel.classes {
			if !have[want] {
				return false
			}
		}
	}
	for k, v := range sel.attrs {
		if attrMap[k] != v {
			return false
		}
	}
	for _, k := range sel.attrAny {
		if _, ok := attrMap[k]; !ok {
			return false
		}
	}
	return true
}

func jsCollectDescendants(root *html.Node, sel jsSelector, out *[]*html.Node) {
	for child := root.FirstChild; child != nil; child = child.NextSibling {
		if jsNodeMatches(child, sel) {
			*out = append(*out, child)
		}
		jsCollectDescendants(child, sel, out)
	}
}

func jsSelectAll(doc *html.Node, selector string) []*html.Node {
	selector = strings.TrimSpace(selector)
	if selector == "" {
		return nil
	}
	groups := strings.Split(selector, ",")
	var all []*html.Node
	for _, group := range groups {
		group = strings.TrimSpace(group)
		if group == "" {
			continue
		}
		normalised := strings.ReplaceAll(group, ">", " > ")
		tokens := strings.Fields(normalised)
		current := []*html.Node{doc}
		childOnly := false
		for _, token := range tokens {
			if token == ">" {
				childOnly = true
				continue
			}
			sel, ok := jsParseSimpleSelector(token)
			if !ok {
				return nil
			}
			var next []*html.Node
			for _, node := range current {
				if childOnly {
					for child := node.FirstChild; child != nil; child = child.NextSibling {
						if jsNodeMatches(child, sel) {
							next = append(next, child)
						}
					}
				} else {
					jsCollectDescendants(node, sel, &next)
				}
			}
			current = next
			childOnly = false
			if len(current) == 0 {
				break
			}
		}
		all = append(all, current...)
	}
	return all
}

func jsSplitRule(rule string) (string, string) {
	parts := strings.Split(rule, "&&")
	if len(parts) == 1 {
		return strings.TrimSpace(parts[0]), "Text"
	}
	last := strings.TrimSpace(parts[len(parts)-1])
	return strings.TrimSpace(strings.Join(parts[:len(parts)-1], "&&")), last
}

func jsExtractFromNode(n *html.Node, attr string) string {
	switch strings.ToLower(attr) {
	case "", "text":
		return jsHTMLText(n)
	case "html", "outerhtml", "outer":
		return jsHTMLOuter(n)
	case "innerhtml", "inner":
		var buf bytes.Buffer
		for child := n.FirstChild; child != nil; child = child.NextSibling {
			_ = html.Render(&buf, child)
		}
		return buf.String()
	default:
		for _, a := range n.Attr {
			if a.Key == attr {
				return a.Val
			}
		}
		return ""
	}
}

func jsParseHTML(content string) (*html.Node, error) {
	return html.Parse(strings.NewReader(content))
}

func (c *jsSpiderCtx) pdfa(call goja.FunctionCall) goja.Value {
	if len(call.Arguments) < 2 {
		return c.rt.ToValue([]string{})
	}
	content := jsValueString(call.Arguments[0])
	selector := jsValueString(call.Arguments[1])
	doc, err := jsParseHTML(content)
	if err != nil {
		return c.rt.ToValue([]string{})
	}
	nodes := jsSelectAll(doc, selector)
	out := []string{}
	for _, n := range nodes {
		out = append(out, jsHTMLOuter(n))
	}
	return c.rt.ToValue(out)
}

func (c *jsSpiderCtx) pdfh(call goja.FunctionCall) goja.Value {
	if len(call.Arguments) < 2 {
		return c.rt.ToValue("")
	}
	content := jsValueString(call.Arguments[0])
	selector := jsValueString(call.Arguments[1])
	css, attr := jsSplitRule(selector)
	doc, err := jsParseHTML(content)
	if err != nil {
		return c.rt.ToValue("")
	}
	nodes := jsSelectAll(doc, css)
	if len(nodes) == 0 {
		return c.rt.ToValue("")
	}
	return c.rt.ToValue(jsExtractFromNode(nodes[0], attr))
}

func (c *jsSpiderCtx) pd(call goja.FunctionCall) goja.Value {
	if len(call.Arguments) < 2 {
		return c.rt.ToValue("")
	}
	content := jsValueString(call.Arguments[0])
	selector := jsValueString(call.Arguments[1])
	attr := "Text"
	if len(call.Arguments) > 2 {
		attr = jsValueString(call.Arguments[2])
		if attr == "" {
			attr = "Text"
		}
	} else {
		var css string
		css, attr = jsSplitRule(selector)
		selector = css
	}
	doc, err := jsParseHTML(content)
	if err != nil {
		return c.rt.ToValue("")
	}
	nodes := jsSelectAll(doc, selector)
	if len(nodes) == 0 {
		return c.rt.ToValue("")
	}
	return c.rt.ToValue(jsExtractFromNode(nodes[0], attr))
}

func (c *jsSpiderCtx) runtime() *goja.Runtime {
	if c.rt != nil {
		return c.rt
	}
	rt := goja.New()
	c.rt = rt
	guard := func(fn func(goja.FunctionCall) goja.Value) func(goja.FunctionCall) goja.Value {
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
	rt.Set("request", guard(c.request))
	rt.Set("get", guard(c.request))
	rt.Set("req", guard(c.jsReq))
	rt.Set("fetch", guard(c.jsReq))
	rt.Set("btoa", guard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return c.rt.ToValue("")
		}
		return c.rt.ToValue(base64.StdEncoding.EncodeToString([]byte(jsValueString(call.Arguments[0]))))
	}))
	rt.Set("atob", guard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return c.rt.ToValue("")
		}
		decoded, err := base64.StdEncoding.DecodeString(jsValueString(call.Arguments[0]))
		if err != nil {
			decoded, err = base64.RawStdEncoding.DecodeString(jsValueString(call.Arguments[0]))
		}
		if err != nil {
			return c.rt.ToValue("")
		}
		return c.rt.ToValue(string(decoded))
	}))
	rt.Set("Buffer", jsBufferObject(rt))
	// Node/CommonJS 形态：module.exports 与 exports 预定义，ESM 的
	// export default 由 jsStripModuleSyntax 转成 module.exports 赋值。
	moduleObj := rt.NewObject()
	exportsObj := rt.NewObject()
	_ = moduleObj.Set("exports", exportsObj)
	rt.Set("module", moduleObj)
	rt.Set("exports", exportsObj)
	rt.Set("global", rt.GlobalObject())
	rt.Set("post", guard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) > 0 {
			if exported := call.Arguments[0].Export(); exported != nil {
				if m, ok := exported.(map[string]interface{}); ok {
					m["method"] = "POST"
					call.Arguments[0] = rt.ToValue(m)
				}
			}
		}
		return c.request(call)
	}))
	rt.Set("pdfa", guard(c.pdfa))
	rt.Set("pdfh", guard(c.pdfh))
	rt.Set("pd", guard(c.pd))
	rt.Set("setResult", guard(func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) > 0 {
			c.result = call.Arguments[0]
			c.resultSet = true
		}
		return goja.Undefined()
	}))
	console := rt.NewObject()
	_ = console.Set("log", guard(func(call goja.FunctionCall) goja.Value { return goja.Undefined() }))
	_ = console.Set("error", guard(func(call goja.FunctionCall) goja.Value { return goja.Undefined() }))
	rt.Set("console", console)
	rt.Set("log", guard(func(call goja.FunctionCall) goja.Value { return goja.Undefined() }))
	rt.Set("print", guard(func(call goja.FunctionCall) goja.Value { return goja.Undefined() }))
	return rt
}

// jsBufferObject 提供 Node Buffer 的最小子集：Buffer.from(input, encoding)
// 与 buf.toString(encoding)/buf.length，覆盖蜘蛛里常见的 base64/hex 编解码。
// 其它 Buffer API（alloc/concat/compare 等）不在此列，调用会报未定义。
func jsBufferObject(rt *goja.Runtime) goja.Value {
	decodeInput := func(value goja.Value, encoding string) []byte {
		if exported := value.Export(); exported != nil {
			if list, ok := exported.([]interface{}); ok {
				out := make([]byte, 0, len(list))
				for _, item := range list {
					switch num := item.(type) {
					case int64:
						out = append(out, byte(num))
					case float64:
						out = append(out, byte(num))
					}
				}
				return out
			}
		}
		text := jsValueString(value)
		switch strings.ToLower(strings.TrimSpace(encoding)) {
		case "base64":
			if decoded, err := base64.StdEncoding.DecodeString(text); err == nil {
				return decoded
			}
			decoded, _ := base64.RawStdEncoding.DecodeString(text)
			return decoded
		case "base64url":
			decoded, _ := base64.RawURLEncoding.DecodeString(text)
			return decoded
		case "hex":
			decoded, _ := hex.DecodeString(text)
			return decoded
		default:
			return []byte(text)
		}
	}
	encodeBytes := func(data []byte, encoding string) string {
		switch strings.ToLower(strings.TrimSpace(encoding)) {
		case "base64":
			return base64.StdEncoding.EncodeToString(data)
		case "base64url":
			return base64.RawURLEncoding.EncodeToString(data)
		case "hex":
			return hex.EncodeToString(data)
		default:
			return string(data)
		}
	}
	bufferObj := rt.NewObject()
	_ = bufferObj.Set("from", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		encoding := ""
		if len(call.Arguments) > 1 {
			encoding = jsValueString(call.Arguments[1])
		}
		data := decodeInput(call.Arguments[0], encoding)
		inst := rt.NewObject()
		_ = inst.Set("__moyiBuffer", true)
		_ = inst.Set("length", len(data))
		_ = inst.Set("toString", func(inner goja.FunctionCall) goja.Value {
			enc := ""
			if len(inner.Arguments) > 0 {
				enc = jsValueString(inner.Arguments[0])
			}
			return rt.ToValue(encodeBytes(data, enc))
		})
		return inst
	})
	_ = bufferObj.Set("isBuffer", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return rt.ToValue(false)
		}
		obj := call.Arguments[0].ToObject(rt)
		if obj == nil {
			return rt.ToValue(false)
		}
		return rt.ToValue(obj.Get("__moyiBuffer") != nil && !goja.IsUndefined(obj.Get("__moyiBuffer")))
	})
	return bufferObj
}

func jsExportValue(rt *goja.Runtime, v goja.Value) (interface{}, error) {
	if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
		return nil, errors.New("JS spider returned nothing")
	}
	exported := v.Export()
	data, err := json.Marshal(exported)
	if err != nil {
		return nil, err
	}
	var decoded interface{}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, err
	}
	return decoded, nil
}

func jsFindFunction(rt *goja.Runtime, name string) (goja.Callable, bool) {
	if fn, ok := goja.AssertFunction(rt.Get(name)); ok {
		return fn, true
	}
	for _, holderName := range []string{"rule", "spider"} {
		holder := rt.Get(holderName)
		if holder == nil || goja.IsUndefined(holder) || goja.IsNull(holder) {
			continue
		}
		obj := holder.ToObject(rt)
		if obj == nil {
			continue
		}
		if fn, ok := goja.AssertFunction(obj.Get(name)); ok {
			return fn, true
		}
	}
	// Node/CommonJS 形态：module.exports 与 exports（export default 已转成
	// module.exports 赋值，见 jsStripModuleSyntax）。
	for _, holder := range jsModuleExportHolders(rt) {
		if holder == nil {
			continue
		}
		if fn, ok := goja.AssertFunction(holder.Get(name)); ok {
			return fn, true
		}
	}
	spiderCtor := rt.Get("Spider")
	if spiderCtor != nil && !goja.IsUndefined(spiderCtor) && !goja.IsNull(spiderCtor) {
		if ctor, ok := goja.AssertConstructor(spiderCtor); ok {
			inst, err := ctor(nil)
			if err == nil && inst != nil {
				obj := inst.ToObject(rt)
				if obj != nil {
					if fn, ok := goja.AssertFunction(obj.Get(name)); ok {
						return fn, true
					}
				}
			}
		}
	}
	return nil, false
}

func jsModuleExportHolders(rt *goja.Runtime) []*goja.Object {
	holders := []*goja.Object{}
	module := rt.Get("module")
	if module != nil && !goja.IsUndefined(module) && !goja.IsNull(module) {
		if moduleObj := module.ToObject(rt); moduleObj != nil {
			if exported := moduleObj.Get("exports"); exported != nil && !goja.IsUndefined(exported) && !goja.IsNull(exported) {
				if obj := exported.ToObject(rt); obj != nil {
					holders = append(holders, obj)
				}
			}
		}
	}
	exports := rt.Get("exports")
	if exports != nil && !goja.IsUndefined(exports) && !goja.IsNull(exports) {
		if obj := exports.ToObject(rt); obj != nil {
			holders = append(holders, obj)
		}
	}
	return holders
}

var jsOperationFunctions = map[string]string{
	"home":     "homeContent",
	"category": "categoryContent",
	"detail":   "detailContent",
	"search":   "searchContent",
	"player":   "playerContent",
}

func jsSpiderRun(script, operation, tid string, page int, query, vodID, flag, playID string) (map[string]interface{}, error) {
	return jsSpiderRunArgs(script, operation, tid, page, query, vodID, flag, playID, nil, false)
}

// jsSpiderRunArgs 是带筛选/快速搜索入参的分发：extend 是调用方给
// category 的筛选值（透传给脚本的 category(tid, pg, filter, extend)，
// filter 表示 extend 非空），quick 是调用方给 search 的快速搜索标志。
func jsSpiderRunArgs(script, operation, tid string, page int, query, vodID, flag, playID string, extend map[string]interface{}, quick bool) (map[string]interface{}, error) {
	fnName, ok := jsOperationFunctions[operation]
	if !ok {
		return nil, fmt.Errorf("unsupported JS spider operation: %s", operation)
	}
	ctx := &jsSpiderCtx{client: jsSpiderHTTPClient()}
	rt := ctx.runtime()
	originalScript := script
	script = jsStripModuleSyntax(script).script
	if _, err := rt.RunString(script); err != nil {
		if _, isDrpy := jsDescribeDrpyRule(originalScript); isDrpy {
			return nil, jsDrpyRuleError(originalScript, err)
		}
		return nil, err
	}
	resolvedName := fnName
	fn, found := jsFindFunction(rt, fnName)
	if !found {
		altNames := map[string][]string{
			"homeContent":     {"home", "homeVod"},
			"categoryContent": {"category"},
			"detailContent":   {"detail"},
			"searchContent":   {"search"},
			"playerContent":   {"play", "player"},
		}
		for _, alt := range altNames[fnName] {
			if altFn, ok := jsFindFunction(rt, alt); ok {
				fn = altFn
				resolvedName = alt
				found = true
				break
			}
		}
	}
	if !found {
		if _, isDrpy := jsDescribeDrpyRule(originalScript); isDrpy {
			return nil, jsDrpyRuleError(originalScript, nil)
		}
		err := fmt.Errorf("JS spider does not provide %s", fnName)
		if shape := jsClassifyScript(originalScript); shape == jsShapeCat || shape == jsShapeModule {
			err = fmt.Errorf("JS spider does not provide %s (script shape: %s)", fnName, shape)
		}
		return nil, err
	}
	var args []goja.Value
	switch operation {
	case "home":
		// cat 形态 home(filter)/homeVod(params) 取一个参数；TVBox
		// homeContent 无参。按实际命中的函数名分流，多余参数 JS 会忽略。
		if resolvedName == "home" || resolvedName == "homeVod" {
			args = []goja.Value{rt.ToValue(true)}
		} else {
			args = []goja.Value{}
		}
	case "category":
		extendArg := extend
		if extendArg == nil {
			extendArg = map[string]interface{}{}
		}
		args = []goja.Value{rt.ToValue(tid), rt.ToValue(page), rt.ToValue(len(extendArg) > 0), rt.ToValue(extendArg)}
	case "detail":
		// cat 形态 detail(vod_url) 取单个字符串；TVBox detailContent
		// 取 id 数组。按实际命中的函数名分流（样本：猫测试.js）。
		if resolvedName == "detail" {
			args = []goja.Value{rt.ToValue(vodID)}
		} else {
			args = []goja.Value{rt.ToValue([]string{vodID})}
		}
	case "search":
		// easytv 口径 search(key, quick, pg)：pg 传字符串，quick 透传
		// 调用方入参（旧实现恒传 false 且 pg 为 int，脚本按字符串拼
		// 页码时会拼出异常形态）。
		args = []goja.Value{rt.ToValue(query), rt.ToValue(quick), rt.ToValue(strconv.Itoa(page))}
	case "player":
		args = []goja.Value{rt.ToValue(flag), rt.ToValue(playID), rt.ToValue([]string{})}
	}
	out, err := fn(goja.Undefined(), args...)
	if err != nil {
		return nil, err
	}
	if (out == nil || goja.IsUndefined(out)) && ctx.resultSet {
		out = ctx.result
	}
	decoded, err := jsExportValue(rt, out)
	if err != nil {
		return nil, err
	}
	if text, ok := decoded.(string); ok {
		trimmed := strings.TrimSpace(text)
		if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
			var parsed interface{}
			if err := json.Unmarshal([]byte(trimmed), &parsed); err == nil {
				decoded = parsed
			} else {
				return nil, errors.New("JS spider returned invalid JSON text")
			}
		} else {
			return nil, errors.New("JS spider returned plain text instead of a result object")
		}
	}
	if list, ok := decoded.([]interface{}); ok {
		return map[string]interface{}{"list": list}, nil
	}
	if result, ok := decoded.(map[string]interface{}); ok {
		return result, nil
	}
	return nil, errors.New("JS spider returned an unsupported result shape")
}

func jsSpiderPage(input nativeInput) (int, error) {
	if input.Page > 0 {
		return input.Page, nil
	}
	return 1, nil
}

func jsSpiderDispatch(input nativeInput) (map[string]interface{}, error) {
	page, _ := jsSpiderPage(input)
	vodID := input.Drama.SourceID
	if vodID == "" {
		vodID = input.Drama.ID
	}
	playID := input.PlayID
	if playID == "" {
		playID = input.Chapter.ID
	}
	// 调用方筛选入参（nativeInput.Filters）组装成 category 的 extend
	// 透传；其中 quick 键是 search 的快速搜索标志（nativeInput 没有
	// 独立的 quick 字段，借筛选入参通道传），不进 extend。
	extend := map[string]interface{}{}
	quick := false
	for key, value := range input.Filters {
		if key == "quick" {
			quick = value == "1" || strings.EqualFold(strings.TrimSpace(value), "true")
			continue
		}
		extend[key] = value
	}
	return jsSpiderRunArgs(input.Content, input.Command, input.Category, page, input.Query, vodID, input.Flag, playID, extend, quick)
}
