package core

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLegadoSplitAttr(t *testing.T) {
	sel, attr := legadoSplitAttr("div.item a.title@href")
	if sel != "div.item a.title" || attr != "href" {
		t.Fatalf("want div.item a.title/href, got %s/%s", sel, attr)
	}
	sel, attr = legadoSplitAttr("div#content@text")
	if sel != "div#content" || attr != "text" {
		t.Fatalf("want div#content/text, got %s/%s", sel, attr)
	}
	if _, _ = legadoSplitAttr("//div"); true {
		sel, _ = legadoSplitAttr("//div")
		if sel != "" {
			t.Fatalf("xpath should be unsupported, got %s", sel)
		}
	}
}

func TestLegadoFieldAndText(t *testing.T) {
	block := `<div class="item"><a class="title" href="/b/1">BookA</a><span class="author">AuthA</span></div>`
	if got := legadoField(block, "a.title@text"); got != "BookA" {
		t.Fatalf("want BookA, got %q", got)
	}
	if got := legadoField(block, "a.title@href"); got != "/b/1" {
		t.Fatalf("want /b/1, got %q", got)
	}
	if got := legadoField(block, "span.author@text"); got != "AuthA" {
		t.Fatalf("want AuthA, got %q", got)
	}
	text := legadoHTMLToText(`<div id="c"><p>第一段</p><p>第二段<br>续行</p></div>`)
	if !strings.Contains(text, "第一段\n第二段\n续行") {
		t.Fatalf("want paragraph breaks, got %q", text)
	}
	src, err := legadoParseSource([]byte(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s?k={{key}}&p={{page}}","ruleSearch":{"bookList":"div.item","name":"a.title@text","bookUrl":"a.title@href"},"ruleToc":{"tocList":"dd a","chapterName":"@text","chapterUrl":"@href"},"ruleContent":{"content":"div#content@text"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if src.Name != "T" || src.BookList != "div.item" || src.TocList != "dd a" || src.ContentRule != "div#content@text" {
		t.Fatalf("bad parse: %+v", src)
	}
}

func TestLegadoCheck(t *testing.T) {
	css := LegadoSource{BookList: "div.item", NameRule: "a.title@text", BookURLRule: "a.title@href"}
	if got := legadoCheck(css); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("css source should be supported, got %+v", got)
	}
	xpath := LegadoSource{BookList: "//div[@class='item']"}
	if got := legadoCheck(xpath); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("xpath source should be supported by the xpath subset, got %+v", got)
	}
	js := LegadoSource{BookList: "div.item", NameRule: "@js:xxx"}
	if got := legadoCheck(js); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("js source should be supported by the js engine, got %+v", got)
	}
	jsonRule := LegadoSource{BookList: "$.data[*]"}
	if got := legadoCheck(jsonRule); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("json lite source should be supported, got %+v", got)
	}
	nth := LegadoSource{BookList: "div:nth-child(2)"}
	if got := legadoCheck(nth); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("nth-child source should be supported by the dialect walker, got %+v", got)
	}
	nthLast := LegadoSource{BookList: "div:nth-last-child(2)"}
	if got := legadoCheck(nthLast); got.Supported || len(got.UnsupportedFields) != 1 || got.UnsupportedFields[0].Reason != "nth" {
		t.Fatalf("nth-last-child source should be unsupported nth, got %+v", got)
	}
	child := LegadoSource{BookList: "div:first-child"}
	if got := legadoCheck(child); got.Supported || len(got.UnsupportedFields) != 1 || got.UnsupportedFields[0].Reason != "child" {
		t.Fatalf("first-child source should be unsupported child, got %+v", got)
	}
	attr := LegadoSource{BookList: `div.item[data-id="1"]`, NameRule: "a.title@text"}
	if got := legadoCheck(attr); !got.Supported {
		t.Fatalf("attr source should be supported after G1, got %+v", got)
	}
	eq := LegadoSource{BookList: "div.item", NameRule: "a:eq(1)@text"}
	if got := legadoCheck(eq); !got.Supported {
		t.Fatalf("eq source should be supported after G1, got %+v", got)
	}
	mixed := LegadoSource{BookList: "div.item||//div"}
	if got := legadoCheck(mixed); !got.Supported {
		t.Fatalf("mixed source with css alternative should be supported, got %+v", got)
	}
	allBad := LegadoSource{BookList: "//div||//span"}
	if got := legadoCheck(allBad); !got.Supported {
		t.Fatalf("all xpath source should be supported by the xpath subset, got %+v", got)
	}
	out, err := LegadoRunJSON(`{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","ruleSearch":{"bookList":"//div","name":"a@text"}}`, "check", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"supported":true`) {
		t.Fatalf("check action output missing supported xpath: %s", out)
	}
}

func TestLegadoSearchPostSuffixSpace(t *testing.T) {
	var gotMethod, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		_, _ = w.Write([]byte(`<html><body><div class="item"><a class="title" href="/b/1">BookA</a></div></body></html>`))
	}))
	defer srv.Close()
	base := LegadoSource{
		URL:         srv.URL,
		BookList:    "div.item",
		NameRule:    "a.title@text",
		BookURLRule: "a.title@href",
	}
	spaced := base
	spaced.SearchURL = srv.URL + `/s, {"method": "POST", "body": "k={{key}}"}`
	res, err := legadoSearch(spaced, "key", 1)
	if err != nil {
		t.Fatal(err)
	}
	if gotMethod != "POST" {
		t.Fatalf("want POST for spaced suffix, got %s", gotMethod)
	}
	if !strings.Contains(gotBody, "k=key") {
		t.Fatalf("want body k=key, got %q", gotBody)
	}
	books, ok := res.([]map[string]string)
	if !ok || len(books) != 1 || books[0]["title"] != "BookA" {
		t.Fatalf("want one BookA, got %#v", res)
	}
	tight := base
	tight.SearchURL = srv.URL + `/s,{"method": "POST", "body": "k={{key}}"}`
	if _, err := legadoSearch(tight, "key", 1); err != nil {
		t.Fatalf("tight suffix should still work: %v", err)
	}
	if gotMethod != "POST" {
		t.Fatalf("want POST for tight suffix, got %s", gotMethod)
	}
}

func TestLegadoSearchAttrAndEqEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<html><body><div class="item"><a class="title" href="/b/1">BookA</a></div><div class="item"><a class="title" href="/other/2">BookB</a></div></body></html>`))
	}))
	defer srv.Close()
	attr := LegadoSource{
		URL:         srv.URL,
		SearchURL:   srv.URL + "/s?k={{key}}",
		BookList:    "div.item",
		NameRule:    "a.title@text",
		BookURLRule: `a[href*="/b/"]@href`,
	}
	res, err := legadoSearch(attr, "key", 1)
	if err != nil {
		t.Fatal(err)
	}
	books, ok := res.([]map[string]string)
	if !ok || len(books) != 2 {
		t.Fatalf("want 2 books, got %#v", res)
	}
	if books[0]["url"] != srv.URL+"/b/1" {
		t.Fatalf("want attr selected url, got %q", books[0]["url"])
	}
	eq := attr
	eq.BookList = "div.item:eq(1)"
	eq.BookURLRule = "a.title@href"
	res, err = legadoSearch(eq, "key", 1)
	if err != nil {
		t.Fatal(err)
	}
	books, ok = res.([]map[string]string)
	if !ok || len(books) != 1 || books[0]["title"] != "BookB" {
		t.Fatalf("want only BookB for :eq bookList, got %#v", res)
	}
}
