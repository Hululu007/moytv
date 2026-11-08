package core

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLegadoJSONPathParse(t *testing.T) {
	valid := []string{
		"$", "$.a", "$.data.list[*]", "$.data.list[0]", "$.data.list[*].title",
		"$.a[0][1]", "$[0]", "$[*]", "$.data.toc", "$..title", "$.data..list",
	}
	for _, r := range valid {
		if _, ok := legadoParseJSONPath(r); !ok {
			t.Fatalf("want %q supported, got unsupported", r)
		}
	}
	invalid := []string{
		"$.data[?(@.x==1)]", "$.data['name']", "$.data[0:2]",
		"$.data[]", "$a", "$.", "",
	}
	for _, r := range invalid {
		if _, ok := legadoParseJSONPath(r); ok {
			t.Fatalf("want %q unsupported, got supported", r)
		}
	}
}

func TestLegadoJSONFieldValues(t *testing.T) {
	block := `{"title":"T","count":42,"ok":true,"missing":null,"paras":["p1","p2"],"obj":{"x":1}}`
	if got := legadoJSONFieldAny(block, "$.title"); got != "T" {
		t.Fatalf("want T, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.count"); got != "42" {
		t.Fatalf("want 42, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.ok"); got != "true" {
		t.Fatalf("want true, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.nope"); got != "" {
		t.Fatalf("want empty for missing, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.paras"); got != "p1\np2" {
		t.Fatalf("want joined paras, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.obj"); got != "" {
		t.Fatalf("want empty for object, got %q", got)
	}
	if got := legadoJSONFieldAny(block, "$.nope||$.title"); got != "T" {
		t.Fatalf("want T via fallback, got %q", got)
	}
	if got := legadoJSONFieldAny(`<div>html</div>`, "$.title"); got != "" {
		t.Fatalf("want empty for html block, got %q", got)
	}
}

func TestLegadoJSONListBlocks(t *testing.T) {
	body := `{"data":{"list":[{"t":"A"},{"t":"B"}]},"single":{"t":"S"}}`
	blocks := legadoJSONListBlocks(body, "$.data.list[*]")
	if len(blocks) != 2 || !strings.Contains(blocks[0], `"A"`) {
		t.Fatalf("want 2 blocks, got %#v", blocks)
	}
	blocks = legadoJSONListBlocks(body, "$.data.list")
	if len(blocks) != 2 {
		t.Fatalf("want array path expanded to 2, got %#v", blocks)
	}
	blocks = legadoJSONListBlocks(body, "$.single")
	if len(blocks) != 1 || !strings.Contains(blocks[0], `"S"`) {
		t.Fatalf("want single object block, got %#v", blocks)
	}
	blocks = legadoJSONListBlocks(body, "$.nope||$.data.list[*]")
	if len(blocks) != 2 {
		t.Fatalf("want fallback alt to work, got %#v", blocks)
	}
	if blocks := legadoJSONListBlocks(body, "$..list"); len(blocks) != 2 {
		t.Fatalf("want recursive path to expand to 2, got %#v", blocks)
	}
}

func TestLegadoJSONSourceEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/s":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_, _ = w.Write([]byte(`{"code":0,"data":{"list":[{"title":"JsonBookA","author":"AuthJ","cover":"/c/a.jpg","url":"/book/a","intro":"introA"},{"title":"JsonBookB","author":"AuthK","cover":"/c/b.jpg","url":"/book/b","intro":"introB"}]}}`))
		case "/book/a":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_, _ = w.Write([]byte(`{"data":{"toc":[{"name":"第1章","link":"/book/a/c1"},{"name":"第2章","link":"/book/a/c2"}]}}`))
		case "/book/a/c1":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_, _ = w.Write([]byte(`{"data":{"content":"第一章正文。","next":""}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	srcJSON := `{"bookSourceName":"JsonApi","bookSourceUrl":"` + srv.URL + `","searchUrl":"` + srv.URL + `/s?key={{key}}","ruleSearch":{"bookList":"$.data.list[*]","name":"$.title","author":"$.author","coverUrl":"$.cover","bookUrl":"$.url","intro":"$.intro"},"ruleBookInfo":{},"ruleToc":{"tocList":"$.data.toc[*]","chapterName":"$.name","chapterUrl":"$.link"},"ruleContent":{"content":"$.data.content","nextContentUrl":"$.data.next"}}`
	src, err := legadoParseSource([]byte(srcJSON))
	if err != nil {
		t.Fatal(err)
	}
	if got := legadoCheck(src); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("json lite source should be supported, got %+v", got)
	}
	res, err := legadoSearch(src, "key", 1)
	if err != nil {
		t.Fatal(err)
	}
	books, ok := res.([]map[string]string)
	if !ok || len(books) != 2 || books[0]["title"] != "JsonBookA" || books[1]["title"] != "JsonBookB" {
		t.Fatalf("want 2 json books, got %#v", res)
	}
	if books[0]["url"] != srv.URL+"/book/a" || books[0]["cover"] != srv.URL+"/c/a.jpg" {
		t.Fatalf("want absolute url/cover, got %#v", books[0])
	}
	res, err = legadoToc(src, srv.URL+"/book/a")
	if err != nil {
		t.Fatal(err)
	}
	chapters, ok := res.([]map[string]string)
	if !ok || len(chapters) != 2 || chapters[0]["title"] != "第1章" {
		t.Fatalf("want 2 json chapters, got %#v", res)
	}
	res, err = legadoContent(src, srv.URL+"/book/a/c1")
	if err != nil {
		t.Fatal(err)
	}
	content, ok := res.(map[string]string)
	if !ok || content["content"] != "第一章正文。" {
		t.Fatalf("want chapter text, got %#v", res)
	}
}

func TestLegadoCheckJSONPathStillUnsupported(t *testing.T) {
	recursive := LegadoSource{BookList: "$..title"}
	if got := legadoCheck(recursive); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("recursive path should be supported now, got %+v", got)
	}
	filter := LegadoSource{BookList: "$.data[?(@.x==1)]"}
	if got := legadoCheck(filter); got.Supported || len(got.UnsupportedFields) != 1 || got.UnsupportedFields[0].Reason != "jsonpath" {
		t.Fatalf("filter path should stay unsupported jsonpath, got %+v", got)
	}
	lite := LegadoSource{BookList: "$.data[*]", NameRule: "$.title"}
	if got := legadoCheck(lite); !got.Supported || len(got.UnsupportedFields) != 0 {
		t.Fatalf("lite json source should be supported, got %+v", got)
	}
}
