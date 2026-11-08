package core

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLegadoHeaderForms(t *testing.T) {
	obj, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","header":{"User-Agent":"UA-1","Referer":"https://r.example/"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if obj.Headers["User-Agent"] != "UA-1" || obj.Headers["Referer"] != "https://r.example/" {
		t.Fatalf("object header not parsed: %+v", obj.Headers)
	}
	str, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","header":"{\"User-Agent\":\"UA-2\"}"}`))
	if err != nil {
		t.Fatal(err)
	}
	if str.Headers["User-Agent"] != "UA-2" {
		t.Fatalf("json string header not parsed: %+v", str.Headers)
	}
	plain, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","header":"Mozilla/5.0 Plain"}`))
	if err != nil {
		t.Fatal(err)
	}
	if plain.Headers["User-Agent"] != "Mozilla/5.0 Plain" {
		t.Fatalf("plain header should become User-Agent: %+v", plain.Headers)
	}
	script, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","header":"@js:head={}"}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(script.Headers) != 0 {
		t.Fatalf("js header should stay unapplied: %+v", script.Headers)
	}
}

func TestLegadoSearchKeyPlaceholders(t *testing.T) {
	var gotQuery, gotBody string
	var gotUA string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		gotUA = r.Header.Get("User-Agent")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		_, _ = w.Write([]byte(`<html><body><div class="item"><a class="title" href="/b/1">BookA</a></div></body></html>`))
	}))
	defer srv.Close()
	src, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"` + srv.URL + `","header":{"User-Agent":"UA-SRC"},"searchUrl":"` + srv.URL + `/s?k=searchKey&p={{searchPage}}&p2={{searchPage+1}}&p0={{searchPage-1}}","ruleSearch":{"bookList":"div.item","name":"a.title@text","bookUrl":"a.title@href"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legadoSearch(src, "斗罗", 3); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gotQuery, "p=3") || !strings.Contains(gotQuery, "p2=4") || !strings.Contains(gotQuery, "p0=2") {
		t.Fatalf("searchPage placeholders wrong: %q", gotQuery)
	}
	if !strings.Contains(gotQuery, "k=") || strings.Contains(gotQuery, "searchKey") {
		t.Fatalf("literal searchKey not replaced: %q", gotQuery)
	}
	if gotUA != "UA-SRC" {
		t.Fatalf("source header not applied: %q", gotUA)
	}
	suffix, _ := json.Marshal(map[string]string{"method": "POST", "body": `{"title":"searchKey"}`})
	postJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      srv.URL + "/s," + string(suffix),
		"ruleSearch":     map[string]string{"bookList": "div.item", "name": "a.title@text", "bookUrl": "a.title@href"},
	})
	post, err := legadoParseSource(postJSON)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legadoSearch(post, "斗罗", 1); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(gotBody, `"title":"斗罗"`) {
		t.Fatalf("body searchKey should stay raw keyword: %q", gotBody)
	}
}

func TestLegadoJSErrorSurfaced(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<html><body><div class="item"><a class="title" href="/b/1">BookA</a></div></body></html>`))
	}))
	defer srv.Close()
	src, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"` + srv.URL + `","searchUrl":"` + srv.URL + `/s?k={{key}}","ruleSearch":{"bookList":"div.item@js:throw new Error('boom')","name":"a.title@text","bookUrl":"a.title@href"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legadoSearch(src, "key", 1); err == nil {
		t.Fatal("throwing js bookList should surface an error, not an empty list")
	} else if !strings.Contains(err.Error(), "boom") {
		t.Fatalf("want js error text, got %v", err)
	}
}

func TestLegadoChapterListKey(t *testing.T) {
	src, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","ruleToc":{"chapterList":"dd a","chapterName":"@text","chapterUrl":"@href"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if src.TocList != "dd a" {
		t.Fatalf("chapterList key not read, got %q", src.TocList)
	}
	legacy, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","ruleToc":{"tocList":"dd a"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if legacy.TocList != "dd a" {
		t.Fatalf("tocList fallback not read, got %q", legacy.TocList)
	}
}

func TestLegadoReplaceRegexSubset(t *testing.T) {
	got := legadoApplyReplaceRegex("正文尾巴穿越小说www.xxx", "##穿越小说.*www.*")
	if strings.Contains(got, "穿越小说") {
		t.Fatalf("single group regex not applied: %q", got)
	}
	if !strings.Contains(got, "正文尾巴") {
		t.Fatalf("real text removed: %q", got)
	}
	got = legadoApplyReplaceRegex("正文X本章完Y尾巴", "##.本章完.")
	if strings.Contains(got, "本章完") || !strings.Contains(got, "正文") || !strings.Contains(got, "尾巴") {
		t.Fatalf("dot pattern wrong: %q", got)
	}
	kept := legadoApplyReplaceRegex("正文《书名》后续", "##《{{book.name}}》.*")
	if kept != "正文《书名》后续" {
		t.Fatalf("template variant should be skipped: %q", kept)
	}
	bad := legadoApplyReplaceRegex("正文[未完", "##[unclosed")
	if bad != "正文[未完" {
		t.Fatalf("bad regex should be skipped: %q", bad)
	}
}

func TestLegadoTextSelector(t *testing.T) {
	page := `<html><body><div class="nav"><a href="/toc">目录</a><a href="/read">开始阅读</a></div></body></html>`
	ctx := newLegadoJSCtx("https://x.example")
	if got := ctx.evalScalar(page, "text.目录@href"); got != "/toc" {
		t.Fatalf("text selector toc href = %q", got)
	}
	if got := ctx.evalScalar(page, "text.开始阅读@href"); got != "/read" {
		t.Fatalf("text selector read href = %q", got)
	}
}

func TestLegadoBookJSVariable(t *testing.T) {
	ctx := newLegadoJSCtx("https://x.example")
	rt := ctx.runtime()
	v, err := ctx.evalJSCur(`book.getVariable("custom")`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := legadoJSValueString(rt, v); got != "" {
		t.Fatalf("unset book variable = %q", got)
	}
}

func TestLegadoFirstLineURL(t *testing.T) {
	if got := legadoFirstLine("/50050\n/50050"); got != "/50050" {
		t.Fatalf("first line = %q", got)
	}
	if got := legadoFirstLine(""); got != "" {
		t.Fatalf("empty first line = %q", got)
	}
}

func TestLegadoSingleBraceTemplate(t *testing.T) {
	ctx := newLegadoJSCtx("https://x.example")
	block := `{"wapBookId":"12345","bookName":"Test"}`
	got := ctx.evalScalar(block, "http://m.yueyouxs.com/b/{$.wapBookId}.html")
	if got != "http://m.yueyouxs.com/b/12345.html" {
		t.Fatalf("single brace template = %q", got)
	}
}

func TestLegadoComicURLLinesImages(t *testing.T) {
	imgs, ok := legadoAllURLLinesImages("https://a.example/x\n/b\nc/d.jpg", "https://site.example/ch")
	if !ok || len(imgs) != 3 {
		t.Fatalf("url lines images ok=%v count=%d", ok, len(imgs))
	}
	if imgs[1].URL != "https://site.example/b" || imgs[2].URL != "https://site.example/c/d.jpg" {
		t.Fatalf("resolved urls: %+v", imgs)
	}
	if _, ok := legadoAllURLLinesImages("第一章正文\n第二行还有空格", "https://site.example/ch"); ok {
		t.Fatal("prose should not be images")
	}
	if _, ok := legadoAllURLLinesImages("https://a.example/x\n第一章", "https://site.example/ch"); ok {
		t.Fatal("mixed lines should not be images")
	}
}

func TestLegadoComicContentEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/html":
			fmt.Fprint(w, `<html><body><div class="pics"><img src="/a.jpg"><img src="/b"><img src="https://cdn.example/c.png"></div></body></html>`)
		case "/json":
			fmt.Fprint(w, `{"images":["/x1","https://cdn.example/x2.jpg"]}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	check := func(rule, path string, want int) {
		src := LegadoSource{URL: srv.URL, ContentRule: rule}
		res, err := legadoContent(src, srv.URL+path)
		if err != nil {
			t.Fatal(err)
		}
		m, ok := res.(map[string]string)
		if !ok {
			t.Fatalf("content result type %T", res)
		}
		var imgs []legadoImage
		if err := json.Unmarshal([]byte(m["images"]), &imgs); err != nil {
			t.Fatalf("images decode: %v (%q)", err, m["images"])
		}
		if len(imgs) != want {
			t.Fatalf("rule %q got %d images: %+v", rule, len(imgs), imgs)
		}
	}
	check("div.pics@html", "/html", 3)
	check("$.images[*]", "/json", 2)
	check("$.images", "/json", 2)
}

func TestLegadoContentInlineReplace(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `<html><body><div id="content"><p>正文第一段</p><p>广告行请删除</p><p>正文第二段</p></div></body></html>`)
	}))
	defer srv.Close()
	src := LegadoSource{URL: srv.URL, ContentRule: `id.content@html##广告行请删除`}
	res, err := legadoContent(src, srv.URL+"/c")
	if err != nil {
		t.Fatal(err)
	}
	m, ok := res.(map[string]string)
	if !ok {
		t.Fatalf("content result type %T", res)
	}
	if !strings.Contains(m["content"], "正文第一段") || !strings.Contains(m["content"], "正文第二段") {
		t.Fatalf("content lost real text: %q", m["content"])
	}
	if strings.Contains(m["content"], "广告行") {
		t.Fatalf("inline replace not applied: %q", m["content"])
	}
}
