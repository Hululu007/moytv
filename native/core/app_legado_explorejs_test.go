package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func loadManwaSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("../../assets/legado_sources/legado_7621_0.json")
	if err != nil {
		t.Fatalf("read manwa json: %v", err)
	}
	return string(raw)
}

// 漫蛙的 exploreUrl 是 @js: 脚本：求值后返回分类 JSON 数组。
// 以前 legadoExploreCategories 不求值，脚本原文被按行拆成
// “分类”（@js:、var _o = {}; …），分类页全是垃圾行。
func TestLegadoExploreCategoriesJS(t *testing.T) {
	out, err := LegadoRunJSON(loadManwaSource(t), "exploreCategories", "")
	if err != nil {
		t.Fatalf("exploreCategories failed: %v", err)
	}
	var cats []map[string]string
	if err := json.Unmarshal([]byte(out), &cats); err != nil {
		t.Fatalf("exploreCategories not json: %v out %q", err, out)
	}
	if len(cats) < 5 {
		t.Fatalf("exploreCategories too few: %d out %q", len(cats), out)
	}
	for _, c := range cats {
		if strings.Contains(c["title"], "@js:") || strings.Contains(c["title"], "var ") {
			t.Fatalf("exploreCategories leaked script line: %q", c["title"])
		}
	}
	found := false
	for _, c := range cats {
		if c["title"] == "全部" && strings.HasPrefix(c["url"], "https://manwa.me/booklist/") {
			found = true
		}
	}
	if !found {
		t.Fatalf("exploreCategories missing 全部 category: %q", out)
	}
}

// 用漫蛙真实的 ruleExplore 选择器跑模拟书单页：分类地址取到数才算通。
func TestLegadoExploreManwaMock(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`<ul class="manga-list-2">
<li><div class="manga-list-2-cover"><a href="/book/11"><img class="manga-list-2-cover-img" src="https://img.test/11.jpg"></a></div><p class="manga-list-2-title"><a href="/book/11">TestBook</a></p><div class="manga-list-2-tip">intro one</div></li>
<li><div class="manga-list-2-cover"><a href="/book/22"><img class="manga-list-2-cover-img" src="https://img.test/22.jpg"></a></div><p class="manga-list-2-title"><a href="/book/22">SecondBook</a></p><div class="manga-list-2-tip">intro two</div></li>
</ul>`))
	}))
	defer srv.Close()
	out, err := LegadoRunJSON(loadManwaSource(t), "explore", srv.URL+"/booklist/?page={{page}}\x011")
	if err != nil {
		t.Fatalf("explore failed: %v", err)
	}
	var books []map[string]string
	if err := json.Unmarshal([]byte(out), &books); err != nil || len(books) != 2 {
		t.Fatalf("explore wrong, out %q err %v", out, err)
	}
	if books[0]["title"] != "TestBook" || books[0]["url"] != "https://manwa.me/book/11" {
		t.Fatalf("explore first book wrong: %v", books[0])
	}
	if books[1]["title"] != "SecondBook" || books[1]["cover"] != "https://img.test/22.jpg" {
		t.Fatalf("explore second book wrong: %v", books[1])
	}
}
