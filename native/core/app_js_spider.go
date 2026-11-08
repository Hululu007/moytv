package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"regexp"
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
	return &http.Client{
		Jar:     jar,
		Timeout: 25 * time.Second,
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

func (c *jsSpiderCtx) request(call goja.FunctionCall) goja.Value {
	urlStr := ""
	method := "GET"
	body := ""
	headers := map[string]string{}
	if len(call.Arguments) > 0 {
		first := call.Arguments[0]
		if first.ExportType() != nil {
			if exported := first.Export(); exported != nil {
				switch val := exported.(type) {
				case string:
					urlStr = val
				case map[string]interface{}:
					if u, ok := val["url"].(string); ok {
						urlStr = u
					}
					if m, ok := val["method"].(string); ok && m != "" {
						method = strings.ToUpper(m)
					}
					if b, ok := val["body"].(string); ok {
						body = b
					}
					if h, ok := val["headers"].(map[string]interface{}); ok {
						for k, hv := range h {
							headers[k] = fmt.Sprint(hv)
						}
					}
				}
			}
		}
	}
	if len(call.Arguments) > 1 {
		if exported := call.Arguments[1].Export(); exported != nil {
			if h, ok := exported.(map[string]interface{}); ok {
				for k, hv := range h {
					headers[k] = fmt.Sprint(hv)
				}
			} else if s, ok := exported.(string); ok && s != "" {
				body = s
			}
		}
	}
	if urlStr == "" {
		return c.rt.ToValue("")
	}
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, urlStr, reader)
	if err != nil {
		return c.rt.ToValue("")
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36")
	req.Header.Set("Accept", "*/*")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return c.rt.ToValue("")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return c.rt.ToValue("")
	}
	return c.rt.ToValue(string(data))
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

var jsOperationFunctions = map[string]string{
	"home":     "homeContent",
	"category": "categoryContent",
	"detail":   "detailContent",
	"search":   "searchContent",
	"player":   "playerContent",
}

func jsSpiderRun(script, operation, tid string, page int, query, vodID, flag, playID string) (map[string]interface{}, error) {
	fnName, ok := jsOperationFunctions[operation]
	if !ok {
		return nil, fmt.Errorf("unsupported JS spider operation: %s", operation)
	}
	ctx := &jsSpiderCtx{client: jsSpiderHTTPClient()}
	rt := ctx.runtime()
	if _, err := rt.RunString(script); err != nil {
		return nil, err
	}
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
				found = true
				break
			}
		}
	}
	if !found {
		return nil, fmt.Errorf("JS spider does not provide %s", fnName)
	}
	var args []goja.Value
	switch operation {
	case "home":
		args = []goja.Value{}
	case "category":
		args = []goja.Value{rt.ToValue(tid), rt.ToValue(page), rt.ToValue(false), rt.ToValue(map[string]interface{}{})}
	case "detail":
		args = []goja.Value{rt.ToValue([]string{vodID})}
	case "search":
		args = []goja.Value{rt.ToValue(query), rt.ToValue(false), rt.ToValue(page)}
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
	return jsSpiderRun(input.Content, input.Command, input.Category, page, input.Query, vodID, input.Flag, playID)
}
