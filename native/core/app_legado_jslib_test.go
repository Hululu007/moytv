package core

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

// legadoRequest must percent-encode a raw (unescaped) query: rule-built
// URLs carry the raw keyword (key=斗破苍穹) and strict servers answer
// 400 to raw non-ASCII on the wire.
func TestLegadoRequestEscapesRawQuery(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`ok`))
	}))
	defer srv.Close()
	body, err := legadoRequest(srv.URL+"/s?key=斗破苍穹&x=1", "GET", "", nil)
	if err != nil || body != "ok" {
		t.Fatalf("request with raw query failed: body %q err %v", body, err)
	}
	if gotQ.Get("key") != "斗破苍穹" || gotQ.Get("x") != "1" {
		t.Fatalf("query wrong after escape: %v", gotQ)
	}
}

// legadoFetchSrc must honour a ,{...} options suffix on book/chapter
// URLs (POST + body), the same suffix search URLs already split
// (6873 Lofter book URLs are POSTs; without the split the toc fetch
// returns nothing usable).
func TestLegadoFetchSrcPostSuffix(t *testing.T) {
	var gotMethod, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Write([]byte(`{"ok":1}`))
	}))
	defer srv.Close()
	src := LegadoSource{URL: srv.URL}
	body, err := legadoFetchSrc(src, srv.URL+"/d?x=1,"+`{"method":"POST","body":"a=1&b=2"}`)
	if err != nil || body != `{"ok":1}` {
		t.Fatalf("fetch failed: body %q err %v", body, err)
	}
	if gotMethod != "POST" || gotBody != "a=1&b=2" {
		t.Fatalf("expected POST a=1&b=2, got %s %s", gotMethod, gotBody)
	}
	// A plain URL still goes out as a GET.
	body2, err := legadoFetchSrc(src, srv.URL+"/d?x=1")
	if err != nil || body2 != `{"ok":1}` || gotMethod != "GET" {
		t.Fatalf("plain fetch failed: body %q method %s err %v", body2, gotMethod, err)
	}
}

// book.putCustomVariable/getCustomVariable: Legado's per-book
// annotation store (6873 Lofter intro, 1751 chapterList, 8019 init).
func TestLegadoBookCustomVariable(t *testing.T) {
	ctx := newLegadoJSCtx("https://example.com")
	out, err := ctx.evalJSCur(`book.putCustomVariable("k","v"); book.getCustomVariable("k")`, `{}`)
	if err != nil || out == nil || out.String() != "v" {
		t.Fatalf("two-arg form failed: out %v err %v", out, err)
	}
	out2, err := ctx.evalJSCur(`book.putCustomVariable("solo"); book.getCustomVariable()`, `{}`)
	if err != nil || out2 == nil || out2.String() != "solo" {
		t.Fatalf("one-arg form failed: out %v err %v", out2, err)
	}
}

// The pre-parsed `result` must also behave like the raw string real
// Legado hands rules: JSON.parse(String(result)) (8146 墨阅·起点） and
// result.length on an object body (6873 chapterList), while
// JSON.stringify(result) stays clean.
func TestLegadoEvalJSCurStringIdioms(t *testing.T) {
	ctx := newLegadoJSCtx("https://example.com")
	out, err := ctx.evalJSCur(`JSON.parse(String(result)).x`, `{"x": 7}`)
	if err != nil || out == nil || out.String() != "7" {
		t.Fatalf("JSON.parse(String(result)) failed: out %v err %v", out, err)
	}
	out2, err := ctx.evalJSCur(`result.length`, `{"x": 7}`)
	if err != nil || out2 == nil || out2.String() != "8" {
		t.Fatalf("result.length failed: out %v err %v", out2, err)
	}
	out3, err := ctx.evalJSCur(`JSON.stringify(result)`, `{"x": 7}`)
	if err != nil || out3 == nil || out3.String() != `{"x":7}` {
		t.Fatalf("JSON.stringify(result) polluted: out %v err %v", out3, err)
	}
}

// A `&&` chain in a JSON rule is a union of branches: merge the
// matches of every branch, skipping branches that match nothing
// (6873 Lofter bookList: $.data.collections[*]&&$.data.posts[*]&&...).
func TestLegadoJSONPathUnion(t *testing.T) {
	body := `{"data":{"collections":[],"posts":[{"title":"a"},{"title":"b"}],"blogs":[]}}`
	blocks := legadoJSONListBlocks(body, `$.data.collections[*]&&$.data.posts[*]&&$.data.blogs[*]`)
	if len(blocks) != 2 {
		t.Fatalf("expected 2 blocks, got %d: %v", len(blocks), blocks)
	}
	strs := legadoJSONPathStrings(body, `$.data.posts[*].title&&$.data.missing[*].title`)
	if len(strs) != 2 || strs[0] != "a" || strs[1] != "b" {
		t.Fatalf("expected [a b], got %v", strs)
	}
}

// JSON.parse(result) must work when result is a pre-parsed JSON object:
// evalJSCur hands rules the parsed object, real Legado hands the raw
// string; the rule idiom JSON.parse(result) must work in both worlds
// (6873 Lofter, 7939 墨阅）. A genuine string argument still goes
// through the real parser.
func TestLegadoJSONParseOfObject(t *testing.T) {
	ctx := newLegadoJSCtx("https://example.com")
	out, err := ctx.evalJSCur(`let a = JSON.parse(result); a.data.posts.length`, `{"data":{"posts":[1,2,3]}}`)
	if err != nil {
		t.Fatalf("JSON.parse(result) failed: %v", err)
	}
	if out == nil || out.String() != "3" {
		t.Fatalf("expected 3, got %v", out)
	}
	out2, err := ctx.evalJSCur(`JSON.parse('{"x": 42}').x`, `{}`)
	if err != nil {
		t.Fatalf("JSON.parse(string) failed: %v", err)
	}
	if out2 == nil || out2.String() != "42" {
		t.Fatalf("expected 42, got %v", out2)
	}
}

// jsLib loading: helpers defined in a source's jsLib must be visible to
// the searchUrl script (this is what 墨阅 / 七猫 / 大灰狼 style sources
// rely on; without it they fail with "X is not defined").
func TestLegadoJsLibHelpers(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`<div class="item"><a href="/b1">JsLibBook</a></div>`))
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"jsLib":          "var host = '" + srv.URL + "';\nfunction HELLO(){ return 'hi'; }",
		"searchUrl":      "@js:host + '/s?q=' + encodeURIComponent(key) + '&h=' + HELLO()",
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("jslib search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "JsLibBook" {
		t.Fatalf("jslib search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("h") != "hi" || gotQ.Get("q") != "kw" {
		t.Fatalf("jslib query wrong: %v", gotQ)
	}
}

// A jsLib whose top-level code throws after the function definitions
// must not block the rule: hoisted functions stay usable.
func TestLegadoJsLibThrowDoesNotBlock(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`<div class="item"><a href="/b1">ThrowBook</a></div>`))
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"jsLib":          "function OK(){ return 'ok'; }\nthrow new Error('boom');",
		"searchUrl":      "@js:'" + srv.URL + "/s?x=' + OK()",
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("jslib throw search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "ThrowBook" {
		t.Fatalf("jslib throw search wrong, out %q err %v", out, err)
	}
}

// {{...}} blocks with JS in a plain searchUrl template must be evaluated
// ({{java.put("key",key);key}} and {{page;java.put("page",page)}}), and
// java.put must yield the stored value so the block evaluates to it.
func TestLegadoSearchURLTemplatePut(t *testing.T) {
	var gotQ url.Values
	var gotRaw string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		gotRaw = r.URL.RawQuery
		w.Write([]byte(`<div class="item"><a href="/b1">TplBook</a></div>`))
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      srv.URL + `/s?k={{java.put("key",key);key}}&p={{page;java.put("page",page)}}`,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "斗破苍穹")
	if err != nil {
		t.Fatalf("template put search failed: %v (raw %q)", err, gotRaw)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "TplBook" {
		t.Fatalf("template put search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("k") != "斗破苍穹" {
		t.Fatalf("template put keyword wrong: %v (raw %q)", gotQ, gotRaw)
	}
	if gotQ.Get("p") != "1" {
		t.Fatalf("template put page wrong: %v", gotQ)
	}
}

// A whole-URL {{(function(){...})()}} template contains braces in its
// body; the template scanner must treat it as one span.
func TestLegadoSearchURLTemplateIIFE(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		w.Write([]byte(`<div class="item"><a href="/b1">IIFEBook</a></div>`))
	}))
	defer srv.Close()
	js := `{{(function(){var L='';try{L=String(source.get('ijLine')||'')}catch(e){} if(!L) L='` + srv.URL + `'; return L+'/s?q='+encodeURIComponent(key);})()}}`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      js,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("template iife search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "IIFEBook" {
		t.Fatalf("template iife search wrong, out %q err %v", out, err)
	}
	if gotPath != "/s" {
		t.Fatalf("template iife path wrong: %q", gotPath)
	}
}

// Rule maps accept the array form (merged first-wins) and the empty
// array form (empty map), instead of failing to parse the source.
func TestLegadoRuleMapArray(t *testing.T) {
	raw := `{"bookSourceName":"T","bookSourceUrl":"http://x.example",
		"ruleSearch":[{"bookList":"class.item","name":"a@text"}],
		"ruleBookInfo":[{"tocUrl":"/toc"},{"author":"x"}],
		"ruleExplore":[],"ruleToc":[],"ruleContent":[]}`
	src, err := legadoParseSource([]byte(raw))
	if err != nil {
		t.Fatalf("array rule maps failed to parse: %v", err)
	}
	if src.BookList != "class.item" || src.NameRule != "a@text" {
		t.Fatalf("array ruleSearch wrong: bookList %q name %q", src.BookList, src.NameRule)
	}
	if src.TocURL != "/toc" {
		t.Fatalf("array ruleBookInfo tocUrl wrong: %q", src.TocURL)
	}
	if src.BookInfo["author"] != "x" {
		t.Fatalf("array ruleBookInfo merge wrong: %v", src.BookInfo)
	}
	if src.ExploreBookList != "" {
		t.Fatalf("empty array ruleExplore should be empty, got %q", src.ExploreBookList)
	}
	// Boolean / numeric values inside a rule map must not fail the
	// whole parse (legado_8050_0 ruleBookInfo, legado_8116_0 ruleToc).
	rawBool := `{"bookSourceName":"T","bookSourceUrl":"http://x.example",
		"ruleToc":{"chapterList":"div li","isVolume":false,"page":2}}`
	srcBool, err := legadoParseSource([]byte(rawBool))
	if err != nil {
		t.Fatalf("bool-valued rule map failed to parse: %v", err)
	}
	if srcBool.TocList != "div li" {
		t.Fatalf("bool rule value broke toc parse: %q", srcBool.TocList)
	}
}

// source.getVariable/setVariable round trip, java.put return value,
// java.encodeURI (+gbk), device id, t2s identity, cache get/put.
func TestLegadoSourceVariableAndJavaHelpers(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`<div class="item"><a href="/b1">VarBook</a></div>`))
	}))
	defer srv.Close()
	script := `@js:
var did = java.androidId();
var did2 = java.deviceID();
source.setVariable(JSON.stringify({mode:'x'}));
var m = JSON.parse(source.getVariable()||'{}').mode;
cache.put('ck','cv');
var cv = cache.get('ck');
java.put('bk','bv');
var bv = getVariable('bk');
var t = java.t2s('書');
'` + srv.URL + `/s?did='+did+'&did2='+did2+'&m='+m+'&cv='+cv+'&bv='+bv+'&t='+encodeURIComponent(t)+'&e='+java.encodeURI(key)`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      script,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("source variable search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 {
		t.Fatalf("source variable search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("did") == "" || gotQ.Get("did") != gotQ.Get("did2") {
		t.Fatalf("device id wrong: %v", gotQ)
	}
	if gotQ.Get("m") != "x" || gotQ.Get("cv") != "cv" || gotQ.Get("bv") != "bv" {
		t.Fatalf("variable/cache helpers wrong: %v", gotQ)
	}
	if gotQ.Get("t") != "書" {
		t.Fatalf("t2s identity wrong: %q", gotQ.Get("t"))
	}
	if gotQ.Get("e") != "kw" {
		t.Fatalf("encodeURI wrong: %q", gotQ.Get("e"))
	}
}

func TestLegadoEncodeURI(t *testing.T) {
	if got := legadoEncodeURI("a b&c", ""); got != "a+b%26c" && got != "a%20b%26c" {
		t.Fatalf("encodeURI utf8 wrong: %q", got)
	}
	gbk, _, err := transform.String(simplifiedchinese.GBK.NewEncoder(), "斗破苍穹")
	if err != nil {
		t.Fatalf("gbk fixture failed: %v", err)
	}
	var want strings.Builder
	for i := 0; i < len(gbk); i++ {
		fmt.Fprintf(&want, "%%%02X", gbk[i])
	}
	if got := legadoEncodeURI("斗破苍穹", "gbk"); got != want.String() {
		t.Fatalf("encodeURI gbk wrong: got %q want %q", got, want.String())
	}
	if id := legadoDeviceID(); id == "" || legadoDeviceID() != id {
		t.Fatalf("device id not stable: %q", id)
	}
}

// Packages bridge: MessageDigest MD5, String.getBytes, DigestUtil.md5Hex,
// HashMap, Base64 round trip, Thread.sleep.
func TestLegadoPackagesMD5(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`<div class="item"><a href="/b1">PkgBook</a></div>`))
	}))
	defer srv.Close()
	script := `@js:
var b = Packages.java.security.MessageDigest.getInstance('MD5').digest(new Packages.java.lang.String('abc').getBytes('UTF-8'));
var h = '';
for (var i = 0; i < b.length; i++) { var x = (b[i] & 0xff).toString(16); h += (x.length < 2 ? '0' : '') + x; }
var h2 = Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('abc');
var m = new Packages.java.util.HashMap();
m.put('k', 'v');
var mv = m.get('k');
var enc = Packages.android.util.Base64.encodeToString(new Packages.java.lang.String('hi').getBytes('UTF-8'), 0);
var dec = Packages.java.util.Base64.getDecoder().decode(enc);
var ds = '';
for (var i = 0; i < dec.length; i++) { ds += String.fromCharCode(dec[i]); }
Packages.java.lang.Thread.sleep(1);
'` + srv.URL + `/s?h='+h+'&h2='+h2+'&mv='+mv+'&ds='+ds`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      script,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("packages search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 {
		t.Fatalf("packages search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("h") != "900150983cd24fb0d6963f7d28e17f72" {
		t.Fatalf("packages md5 wrong: %q", gotQ.Get("h"))
	}
	if gotQ.Get("h2") != "900150983cd24fb0d6963f7d28e17f72" {
		t.Fatalf("packages md5Hex wrong: %q", gotQ.Get("h2"))
	}
	if gotQ.Get("mv") != "v" || gotQ.Get("ds") != "hi" {
		t.Fatalf("packages hashmap/base64 wrong: %v", gotQ)
	}
}

// An @js: script may emit a URL that still carries a {{...}} block
// (6873 builds the literal text {{(page-1) *20}}); the final URL must
// be template-expanded like any other search URL.
func TestLegadoSearchURLTemplateAfterJS(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`<div class="item"><a href="/b1">AfterJsBook</a></div>`))
	}))
	defer srv.Close()
	script := `@js:
var offset = '{' + '{(page-1) *' + '20}' + '}';
'` + srv.URL + `/s?offset=' + offset`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      script,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("after-js template search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 {
		t.Fatalf("after-js template search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("offset") != "0" {
		t.Fatalf("after-js template offset wrong: %v", gotQ)
	}
}

// source.putLoginHeader returns the stored value and getLoginHeader
// reads it back (8011 stores a bearer token this way).
func TestLegadoSourceLoginHeader(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`<div class="item"><a href="/b1">LoginBook</a></div>`))
	}))
	defer srv.Close()
	script := `@js:
var tok = source.putLoginHeader(JSON.stringify({authorization: 'Bearer x'}));
var back = String(source.getLoginHeader()).replace(/^#/,'');
var hdr = JSON.parse(back === '' ? '{}' : back);
'` + srv.URL + `/s?tok='+encodeURIComponent(tok)+'&auth='+encodeURIComponent(hdr.authorization || '')`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      script,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("login header search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 {
		t.Fatalf("login header search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("auth") != "Bearer x" {
		t.Fatalf("login header round trip wrong: %v", gotQ)
	}
}

// cookie global: getCookie returns "" and removeCookie is a no-op, so
// the rule falls through to its no-cookie branch instead of throwing.
func TestLegadoCookieGlobal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`<div class="item"><a href="/b1">CookieBook</a></div>`))
	}))
	defer srv.Close()
	script := `@js:
var cm = null;
try { cm = this.cookie; } catch (e) {}
if (!cm) { try { if (typeof cookie !== 'undefined') cm = cookie; } catch (e) {} }
var ck = '';
if (cm && typeof cm.getCookie === 'function') { ck = cm.getCookie('` + srv.URL + `'); cm.removeCookie('` + srv.URL + `'); }
'` + srv.URL + `/s?ck='+encodeURIComponent(ck)`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      script,
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("cookie search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 {
		t.Fatalf("cookie search wrong, out %q err %v", out, err)
	}
}

// 墨阅-shaped source: jsLib provides host/SRCFG/PLATNAME, the @js:
// searchUrl builds the API url from them.
func TestLegadoMoyueShapedSource(t *testing.T) {
	var gotQ url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQ = r.URL.Query()
		w.Write([]byte(`[{"name":"MoyueBook","url":"/b1","author":"A"}]`))
	}))
	defer srv.Close()
	jsLib := `var host = '` + srv.URL + `';
function PLATNAME(p){ return String(p||'').replace(/\(VIP\)$/,''); }
function SRCFG(src){ var v={}; try{ v=JSON.parse(src.getVariable()||'{}')||{}; }catch(e){ v={}; } return { host: host, gender: '男频', platform: '全部', mode: '小说' }; }`
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"jsLib":          jsLib,
		"searchUrl": `@js:
var cfg = SRCFG(source);
var tab = cfg.mode || '小说';
host + '/legado/search?key=' + encodeURIComponent(key) + '&page=' + page + '&tab=' + encodeURIComponent(tab) + '&source=' + encodeURIComponent(PLATNAME(cfg.platform));`,
		"ruleSearch": map[string]string{
			"bookList": "$.[*]",
			"name":     "name",
			"author":   "author",
			"bookUrl":  "url",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("moyue shaped search failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "MoyueBook" {
		t.Fatalf("moyue shaped search wrong, out %q err %v", out, err)
	}
	if gotQ.Get("tab") != "小说" || gotQ.Get("source") != "全部" || gotQ.Get("key") != "kw" {
		t.Fatalf("moyue shaped query wrong: %v", gotQ)
	}
}
