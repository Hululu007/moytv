package core

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 缺口 1：category 的 filter/extend 必须透传调用方入参，而不是恒
// false/空 map。脚本把收到的 filter 与 extend 值回显到片名里断言。
func TestJsSpiderCategoryExtendFilterPassthrough(t *testing.T) {
	script := `
function categoryContent(tid, pg, filter, extend) {
  return {list: [{vod_id: "1", vod_name: (filter ? "F" : "N") + "|" + (extend.year || "") + "|" + (extend.area || "")}]};
}
`
	out, err := jsSpiderRunArgs(script, "category", "1", 1, "", "", "", "", map[string]interface{}{"year": "2024", "area": "大陆"}, false)
	if err != nil {
		t.Fatalf("category with extend: %v", err)
	}
	row := out["list"].([]interface{})[0].(map[string]interface{})
	if row["vod_name"] != "F|2024|大陆" {
		t.Fatalf("extend/filter not passed through: %v", row["vod_name"])
	}

	// 无筛选入参时保持旧口径：filter=false、extend 为空对象。
	out, err = jsSpiderRun(script, "category", "1", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("category without extend: %v", err)
	}
	row = out["list"].([]interface{})[0].(map[string]interface{})
	if row["vod_name"] != "N||" {
		t.Fatalf("empty extend should stay filter=false: %v", row["vod_name"])
	}

	// 经分发入口：nativeInput.Filters 组装成 extend。
	dispatched, err := jsSpiderDispatch(nativeInput{
		Content: script, Command: "category", Category: "1", Page: 1,
		Filters: map[string]string{"year": "2025"},
	})
	if err != nil {
		t.Fatalf("dispatch category: %v", err)
	}
	row = dispatched["list"].([]interface{})[0].(map[string]interface{})
	if row["vod_name"] != "F|2025|" {
		t.Fatalf("dispatch filters not passed through: %v", row["vod_name"])
	}
}

// 缺口 2：search 的 pg 必须传字符串、quick 必须透传调用方入参
// （旧实现 pg 为 int、quick 恒 false）。
func TestJsSpiderSearchPgStringAndQuick(t *testing.T) {
	script := `
function searchContent(key, quick, pg) {
  return {list: [{vod_id: "1", vod_name: key + "|" + quick + "|" + typeof pg + "|" + pg}]};
}
`
	out, err := jsSpiderRunArgs(script, "search", "", 2, "词", "", "", "", nil, true)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	row := out["list"].([]interface{})[0].(map[string]interface{})
	if row["vod_name"] != "词|true|string|2" {
		t.Fatalf("search args wrong: %v", row["vod_name"])
	}

	// 经分发入口：Filters 里的 quick 键透传为快速搜索标志。
	dispatched, err := jsSpiderDispatch(nativeInput{
		Content: script, Command: "search", Page: 3, Query: "剧",
		Filters: map[string]string{"quick": "true"},
	})
	if err != nil {
		t.Fatalf("dispatch search: %v", err)
	}
	row = dispatched["list"].([]interface{})[0].(map[string]interface{})
	if row["vod_name"] != "剧|true|string|3" {
		t.Fatalf("dispatch search args wrong: %v", row["vod_name"])
	}
}

// 缺口 3+6：req 返回对象带 code（与 status/statusCode 并存）；buffer
// 按 0–3 模式分流（0 文本、1 Base64 兼容、2 Base64、3 原始字节数组）。
func TestJsSpiderReqCodeAndBufferModes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "hello")
	}))
	defer server.Close()

	script := fmt.Sprintf(`
function homeContent() {
  var a = req(%q);
  var b = req(%q, {buffer: 2});
  var c = req(%q, {buffer: 1});
  var d = req(%q, {buffer: 3});
  var e = req(%q, {buffer: 0});
  return {class: [], list: [{vod_id: "1", vod_name: [a.code, a.status, a.statusCode, a.content, b.content, c.content, d.content.length, d.content[0], e.content].join("|")}]};
}
`, server.URL, server.URL, server.URL, server.URL, server.URL)
	out, err := jsSpiderRun(script, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("req home: %v", err)
	}
	row := out["list"].([]interface{})[0].(map[string]interface{})
	want := "200|200|200|hello|aGVsbG8=|aGVsbG8=|5|104|hello"
	if row["vod_name"] != want {
		t.Fatalf("req code/buffer = %q, want %q", row["vod_name"], want)
	}
}

func TestJsFetchBufferMode(t *testing.T) {
	cases := []struct {
		in   interface{}
		want int
	}{
		{nil, 0},
		{false, 0},
		{true, 2},
		{float64(0), 0},
		{float64(1), 1},
		{float64(2), 2},
		{float64(3), 3},
		{int64(2), 2},
		{"0", 0},
		{"3", 3},
		{"false", 0},
		{"true", 2},
	}
	for _, c := range cases {
		if got := jsFetchBufferMode(c.in); got != c.want {
			t.Fatalf("jsFetchBufferMode(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}
