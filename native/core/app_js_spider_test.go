package core

import (
	"strings"
	"testing"
)

const jsSpiderFixture = `
function homeContent() {
  return {class: [{type_id: "1", type_name: "电影"}, {type_id: "2", type_name: "剧集"}], list: []};
}
function categoryContent(tid, pg, filter, extend) {
  return {page: pg, pagecount: 2, list: [{vod_id: "100", vod_name: "测试片", vod_pic: "https://example.com/a.jpg", vod_remarks: "更新至1集"}]};
}
function detailContent(ids) {
  return {list: [{vod_id: ids[0], vod_name: "测试片", vod_pic: "https://example.com/a.jpg", vod_play_from: "线路1", vod_play_url: "第1集$https://example.com/1.m3u8#第2集$https://example.com/2.m3u8"}]};
}
function searchContent(key, quick, pg) {
  return {page: pg, pagecount: 1, list: [{vod_id: "200", vod_name: "搜到" + key, vod_pic: "", vod_remarks: ""}]};
}
function playerContent(flag, id, vipFlags) {
  return {parse: 0, url: id, header: {}};
}
`

func TestJsSpiderFixture(t *testing.T) {
	home, err := jsSpiderRun(jsSpiderFixture, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("home: %v", err)
	}
	classes, ok := home["class"].([]interface{})
	if !ok || len(classes) != 2 {
		t.Fatalf("home class = %v", home["class"])
	}
	cat, err := jsSpiderRun(jsSpiderFixture, "category", "1", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("category: %v", err)
	}
	items, ok := cat["list"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("category list = %v", cat["list"])
	}
	detail, err := jsSpiderRun(jsSpiderFixture, "detail", "", 1, "", "100", "", "")
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	detailItems, ok := detail["list"].([]interface{})
	if !ok || len(detailItems) != 1 {
		t.Fatalf("detail list = %v", detail["list"])
	}
	search, err := jsSpiderRun(jsSpiderFixture, "search", "", 1, "测试", "", "", "")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	searchItems, ok := search["list"].([]interface{})
	if !ok || len(searchItems) != 1 {
		t.Fatalf("search list = %v", search["list"])
	}
	player, err := jsSpiderRun(jsSpiderFixture, "player", "", 1, "", "", "线路1", "https://example.com/1.m3u8")
	if err != nil {
		t.Fatalf("player: %v", err)
	}
	if player["url"] != "https://example.com/1.m3u8" {
		t.Fatalf("player url = %v", player["url"])
	}
}

func TestJsSpiderPdfHelpers(t *testing.T) {
	script := `
function homeContent() {
  var html = '<div class="list"><div class="item"><a href="/v/1">片名一</a></div><div class="item"><a href="/v/2">片名二</a></div></div>';
  var items = pdfa(html, "div.item");
  var names = [];
  for (var i = 0; i < items.length; i++) {
    names.push(pdfh(items[i], "a&&Text"));
  }
  return {class: [], list: [{vod_id: "1", vod_name: names.join(","), vod_pic: pdfh(html, "div.item a&&href")}]};
}
`
	out, err := jsSpiderRun(script, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("pdf home: %v", err)
	}
	items, ok := out["list"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("pdf list = %v", out["list"])
	}
	row, ok := items[0].(map[string]interface{})
	if !ok {
		t.Fatalf("pdf row = %v", items[0])
	}
	if row["vod_name"] != "片名一,片名二" {
		t.Fatalf("pdf names = %v", row["vod_name"])
	}
	if row["vod_pic"] != "/v/1" {
		t.Fatalf("pdf href = %v", row["vod_pic"])
	}
}

func TestJsSpiderMissingFunction(t *testing.T) {
	_, err := jsSpiderRun(`function homeContent() { return {}; }`, "detail", "", 1, "", "1", "", "")
	if err == nil || !strings.Contains(err.Error(), "detailContent") {
		t.Fatalf("expected detailContent error, got %v", err)
	}
}
