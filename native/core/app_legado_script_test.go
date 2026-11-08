package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLegadoJSScalarTransform(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	got := ctx.evalScalar(`<a href="/x">Hi</a>`, `@js:result.toUpperCase()`)
	if got != `<A HREF="/X">HI</A>` {
		t.Fatalf("js upper failed, got %q", got)
	}
}

func TestLegadoJSAjax(t *testing.T) {
	var gotMethod, gotBody, gotHeader string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotHeader = r.Header.Get("X-T")
		buf := make([]byte, 1024)
		n, _ := r.Body.Read(buf)
		gotBody = string(buf[:n])
		fmt.Fprint(w, "ajax-ok")
	}))
	defer srv.Close()
	ctx := newLegadoJSCtx(srv.URL)
	got := ctx.evalScalar("", "@js:java.ajax('"+srv.URL+"/a')")
	if got != "ajax-ok" || gotMethod != "GET" {
		t.Fatalf("ajax get failed, got %q method %q", got, gotMethod)
	}
	opts := `{"method":"POST","body":"x=1","headers":{"X-T":"v"}}`
	got = ctx.evalScalar("", "@js:java.ajax('"+srv.URL+"/b,"+opts+"')")
	if got != "ajax-ok" || gotMethod != "POST" || gotBody != "x=1" || gotHeader != "v" {
		t.Fatalf("ajax post failed, got %q method %q body %q header %q", got, gotMethod, gotBody, gotHeader)
	}
}

func TestLegadoJSAjaxAll(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "R"+strings.TrimPrefix(r.URL.Path, "/"))
	}))
	defer srv.Close()
	ctx := newLegadoJSCtx(srv.URL)
	got := ctx.evalScalar("", "@js:java.ajaxAll(['"+srv.URL+"/a','"+srv.URL+"/b']).join('|')")
	if got != "Ra|Rb" {
		t.Fatalf("ajaxAll failed, got %q", got)
	}
}

func TestLegadoJsoupSelect(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	doc := `<div class="x"><a href="/p1">T1</a><a href="/p2">T2</a></div>`
	got := ctx.evalScalar(doc, `@js:org.jsoup.Jsoup.parse(result).select('a').toArray().map(e=>e.text()).join(',')`)
	if got != "T1,T2" {
		t.Fatalf("jsoup text failed, got %q", got)
	}
	got = ctx.evalScalar(doc, `@js:org.jsoup.Jsoup.parse(result).select('a').toArray().map(e=>e.attr('href')).join(',')`)
	if got != "/p1,/p2" {
		t.Fatalf("jsoup attr failed, got %q", got)
	}
}

func TestLegadoGetStringListRecursive(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	doc := `{"data":[{"items":[{"url":"u1"},{"url":"u2"}]},{"items":[{"url":"u3"}]}]}`
	ctx.setBlock(doc)
	got := ctx.evalScalar(doc, `@js:java.getStringList("$.data..url").toArray().join(",")`)
	if got != "u1,u2,u3" {
		t.Fatalf("getStringList recursive failed, got %q", got)
	}
}

func TestLegadoPutGetFlow(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	block := `{"comic_id":"42","title":"T"}`
	got := ctx.evalScalar(block, `@put:{bid:$.comic_id}@get:{bid}`)
	if got != "42" {
		t.Fatalf("put/get flow failed, got %q", got)
	}
	ctx2 := newLegadoJSCtx("http://example.com")
	got = ctx2.evalScalar(block, `@js:java.put('k','v1');java.get('k')`)
	if got != "v1" {
		t.Fatalf("java put/get failed, got %q", got)
	}
}

func TestLegadoJSTagBlock(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	got := ctx.evalScalar("hello", `<js>result + "!"</js>`)
	if got != "hello!" {
		t.Fatalf("js tag block failed, got %q", got)
	}
}

func TestLegadoTemplates(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	got := ctx.evalScalar(`{"title":"MyBook"}`, `{{$.title}}`)
	if got != "MyBook" {
		t.Fatalf("json template failed, got %q", got)
	}
	ctx.page = 3
	got = ctx.expandURLTemplate("http://x/list?page={{page}}")
	if got != "http://x/list?page=3" {
		t.Fatalf("page template failed, got %q", got)
	}
	got = ctx.expandURLTemplate("http://x/list?page={{page-1==0?'first':'p'+page}}")
	if got != "http://x/list?page=p3" {
		t.Fatalf("js url template failed, got %q", got)
	}
}

func TestLegadoRecursiveJSONPathField(t *testing.T) {
	got := legadoField(`{"data":{"items":[{"url":"u9"}]}}`, "$.data..url")
	if got != "u9" {
		t.Fatalf("recursive jsonpath field failed, got %q", got)
	}
}

func TestLegadoMultiStageSelectorJS(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	block := `<div><a href="/c/1">Ch1</a></div>`
	got := ctx.evalScalar(block, "a@href\n@js:'http://example.com/api'+result")
	if got != "http://example.com/api/c/1" {
		t.Fatalf("multi stage failed, got %q", got)
	}
}

func TestLegadoDialect(t *testing.T) {
	doc := `<div class="media"><h4><a href="/b1">Book1</a><a href="/b2">Book2</a></h4></div><div class="media"><h4><a href="/b3">Book3</a></h4></div>`
	got := legadoField(doc, "class.media@tag.h4@tag.a.0@text")
	if got != "Book1" {
		t.Fatalf("dialect index0 failed, got %q", got)
	}
	got = legadoField(doc, "class.media@tag.h4@tag.a.-1@text")
	if got != "Book3" {
		t.Fatalf("dialect index -1 failed, got %q", got)
	}
	ctx := newLegadoJSCtx("http://example.com")
	blocks := ctx.evalList(doc, "class.media@tag.a")
	if len(blocks) != 3 {
		t.Fatalf("dialect list failed, got %d blocks", len(blocks))
	}
	doc2 := `<table><tr><td>head</td></tr><tr><td>row1</td></tr><tr><td>row2</td></tr></table>`
	got = legadoField(doc2, "tag.tr!0@tag.td@text")
	if got != "row1\nrow2" {
		t.Fatalf("dialect exclude failed, got %q", got)
	}
	doc3 := `<div class="a">A</div><div class="b">B</div>`
	got = legadoField(doc3, "class.a&&class.b@text")
	if got != "A\nB" {
		t.Fatalf("dialect union failed, got %q", got)
	}
}

func TestLegadoReplace(t *testing.T) {
	got := legadoField(`<div class="n">《Book》</div>`, `class.n@text##《|》`)
	if got != "Book" {
		t.Fatalf("replace delete failed, got %q", got)
	}
	got = legadoField(`<a href="/old/x">t</a>`, `a@href##old##new`)
	if got != "/new/x" {
		t.Fatalf("replace pair failed, got %q", got)
	}
	got = legadoField(`<img src="style: url(pic.jpg)">`, `img@src##.*\(([^\)]+)\)##$1`)
	if got != "pic.jpg" {
		t.Fatalf("replace group failed, got %q", got)
	}
}

func TestLegadoXPath(t *testing.T) {
	doc := `<div class="container"><a class="group" href="/g1"><div><div><div>NM</div></div></div></a></div><div id="details"><img src="/c.jpg"></div>`
	got := legadoField(doc, `//div[contains(@class,'container')]//a[contains(@class,'group')]/div[1]/div[1]/div[1]/text()`)
	if got != "NM" {
		t.Fatalf("xpath child index failed, got %q", got)
	}
	got = legadoField(doc, `//div[@id='details']//img/@src`)
	if got != "/c.jpg" {
		t.Fatalf("xpath attr failed, got %q", got)
	}
}

func TestLegadoOwnText(t *testing.T) {
	doc := `<div>direct <span>inner</span> tail</div>`
	got := legadoField(doc, `div@ownText`)
	if got != "direct tail" {
		t.Fatalf("ownText failed, got %q", got)
	}
	got = legadoField(doc, `div@textNodes`)
	if got != "direct\ninner\ntail" {
		t.Fatalf("textNodes failed, got %q", got)
	}
}

func TestLegadoImageExtraction(t *testing.T) {
	images, text := legadoExtractImages(`<div><img src="/p1.jpg"><img src="http://x/p2.png,{"headers":{"Referer":"http://x/"}}"></div>`, "http://base/c/1")
	if len(images) != 2 || images[0].URL != "http://base/p1.jpg" || images[1].URL != "http://x/p2.png" || images[1].Headers["Referer"] != "http://x/" {
		t.Fatalf("img extraction failed, got %+v text %q", images, text)
	}
	images, rest := legadoExtractBareImageLines("http://a/1.jpg\nhttp://a/2.jpg\n", "http://base/", true)
	if len(images) != 2 || rest != "" {
		t.Fatalf("bare full lines failed, got %+v rest %q", images, rest)
	}
	images, rest = legadoExtractBareImageLines("see http://a/1.jpg\nhttp://a/3.png\n", "http://base/", false)
	if len(images) != 1 || images[0].URL != "http://a/3.png" {
		t.Fatalf("bare ext lines failed, got %+v rest %q", images, rest)
	}
}

func TestLegadoExploreEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `<div class="item"><a href="/b1">B1</a></div><div class="item"><a href="/b2">B2</a></div>`)
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"exploreUrl":     "Latest::" + srv.URL + "/list?page={{page}}\nHot::" + srv.URL + "/hot",
		"ruleExplore": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "exploreCategories", "")
	if err != nil {
		t.Fatalf("exploreCategories failed: %v", err)
	}
	var cats []map[string]string
	if err := json.Unmarshal([]byte(out), &cats); err != nil || len(cats) != 2 || cats[0]["title"] != "Latest" {
		t.Fatalf("exploreCategories wrong, out %q err %v", out, err)
	}
	out, err = LegadoRunJSON(string(srcJSON), "explore", cats[0]["url"]+"\x011")
	if err != nil {
		t.Fatalf("explore failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 2 || books[0]["title"] != "B1" {
		t.Fatalf("explore wrong, out %q err %v", out, err)
	}
}

func TestLegadoSearchJSEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":[{"t":"Hello","u":"/b1"}]}`)
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      srv.URL + "/s?k={{key}}",
		"ruleSearch": map[string]string{
			"bookList": "$.data[*]",
			"name":     "@js:result.t.toLowerCase()",
			"bookUrl":  "u",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "hello")
	if err != nil {
		t.Fatalf("search js failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "hello" {
		t.Fatalf("search js wrong, out %q err %v", out, err)
	}
}

func TestLegadoTocPagination(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "p2") {
			fmt.Fprint(w, `<div class="c"><a href="/ch3">C3</a></div>`)
			return
		}
		fmt.Fprint(w, `<div class="c"><a href="/ch1">C1</a></div><div class="c"><a href="/ch2">C2</a></div><a class="next" href="/p2">next</a>`)
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"ruleToc": map[string]string{
			"tocList":     "class.c",
			"chapterName": "a@text",
			"chapterUrl":  "a@href",
			"nextTocUrl":  "a.next@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "toc", srv.URL+"/book")
	if err != nil {
		t.Fatalf("toc pagination failed: %v", err)
	}
	var chapters []map[string]string
	if err := json.Unmarshal([]byte(out), &chapters); err != nil || len(chapters) != 3 || chapters[2]["title"] != "C3" {
		t.Fatalf("toc pagination wrong, out %q err %v", out, err)
	}
}

func TestLegadoJSErrorSoft(t *testing.T) {
	ctx := newLegadoJSCtx("http://example.com")
	got := ctx.evalScalar("x", "@js:throw new Error('boom')")
	if got != "" {
		t.Fatalf("js error should yield empty, got %q", got)
	}
	got = ctx.evalScalar("x", "@js:noSuchFn()")
	if got != "" {
		t.Fatalf("js undefined fn should yield empty, got %q", got)
	}
}
