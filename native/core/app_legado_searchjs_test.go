package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

func TestLegadoExploreJSONCategories(t *testing.T) {
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  "http://x.example",
		"exploreUrl":     `[{"title":"全部","url":"/shuku/a-{{page}}/"},{"title":"男生","url":"/shuku/0-{{page}}/"}]`,
		"ruleExplore": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "exploreCategories", "")
	if err != nil {
		t.Fatalf("json exploreCategories failed: %v", err)
	}
	var cats []map[string]string
	if err := json.Unmarshal([]byte(out), &cats); err != nil || len(cats) != 2 || cats[1]["title"] != "男生" || cats[1]["url"] != "/shuku/0-{{page}}/" {
		t.Fatalf("json exploreCategories wrong, out %q err %v", out, err)
	}
}

func TestLegadoSearchURLJS(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api" {
			w.Write([]byte(`{"data":[{"t":"JsBook","u":"/b9"}]}`))
			return
		}
		w.Write([]byte(`<div class="item"><a href="/b1">PlainBook</a></div>`))
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      "@js:'" + srv.URL + "/list'",
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("search url js failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "PlainBook" {
		t.Fatalf("search url js wrong, out %q err %v", out, err)
	}
	srcJSON2, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      "@js:java.ajax('" + srv.URL + "/api')",
		"ruleSearch": map[string]string{
			"bookList": "$.data[*]",
			"name":     "t",
			"bookUrl":  "u",
		},
	})
	out, err = LegadoRunJSON(string(srcJSON2), "search", "kw")
	if err != nil {
		t.Fatalf("search url js ajax failed: %v", err)
	}
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "JsBook" {
		t.Fatalf("search url js ajax wrong, out %q err %v", out, err)
	}
}

func TestLegadoGBKDecode(t *testing.T) {
	enc, _, _ := transform.String(simplifiedchinese.GB18030.NewEncoder(), "中文测试")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(enc))
	}))
	defer srv.Close()
	got, err := legadoRequest(srv.URL, "GET", "", nil)
	if err != nil || got != "中文测试" {
		t.Fatalf("gbk decode failed, got %q err %v", got, err)
	}
}

func TestLegadoRelativeSearchURL(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`<div class="item"><a href="/b1">RelBook</a></div>`))
	}))
	defer srv.Close()
	srcJSON, _ := json.Marshal(map[string]interface{}{
		"bookSourceName": "T",
		"bookSourceUrl":  srv.URL,
		"searchUrl":      "/s?q={{key}}",
		"ruleSearch": map[string]string{
			"bookList": "class.item",
			"name":     "a@text",
			"bookUrl":  "a@href",
		},
	})
	out, err := LegadoRunJSON(string(srcJSON), "search", "kw")
	if err != nil {
		t.Fatalf("relative search url failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 1 || books[0]["title"] != "RelBook" {
		t.Fatalf("relative search url wrong, out %q err %v", out, err)
	}
}
