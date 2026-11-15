package core

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestJsStripModuleSyntax(t *testing.T) {
	cases := []struct {
		name     string
		script   string
		wantHas  []string
		wantMiss []string
	}{
		{
			name:     "single line import removed",
			script:   "import {_, load} from \"assets://js/lib/cat.js\";\nfunction home(){return {};}",
			wantHas:  []string{"function home"},
			wantMiss: []string{"import", "assets://"},
		},
		{
			name:     "multiline import removed",
			script:   "import {\n  a,\n  b\n} from './lib.js';\nconst x = 1;",
			wantHas:  []string{"const x = 1"},
			wantMiss: []string{"import", "from"},
		},
		{
			name:     "side effect import without semicolon",
			script:   "import './polyfill.js'\nfunction home(){return {};}",
			wantHas:  []string{"function home"},
			wantMiss: []string{"import"},
		},
		{
			name:     "export default becomes module.exports",
			script:   "export default { home: home };\nfunction home(){return {};}",
			wantHas:  []string{"module.exports =", "function home"},
			wantMiss: []string{"export default"},
		},
		{
			name:     "export function keeps declaration",
			script:   "export function home(){return {};}",
			wantHas:  []string{"function home"},
			wantMiss: []string{"export"},
		},
		{
			name:     "export const keeps declaration",
			script:   "export const rule = {a: 1};",
			wantHas:  []string{"const rule"},
			wantMiss: []string{"export"},
		},
		{
			name:     "named export list removed",
			script:   "function home(){return {};}\nexport { home };",
			wantHas:  []string{"function home"},
			wantMiss: []string{"export"},
		},
		{
			name:     "dynamic import untouched",
			script:   "const m = import('./x.js');",
			wantHas:  []string{"import('./x.js')"},
			wantMiss: []string{},
		},
		{
			name:     "import inside string untouched",
			script:   "const s = \"import x from 'y'\";\nfunction home(){return {};}",
			wantHas:  []string{"import x from"},
			wantMiss: []string{},
		},
		{
			name:     "import inside comment untouched",
			script:   "// import {a} from 'b';\nfunction home(){return {};}",
			wantHas:  []string{"// import"},
			wantMiss: []string{},
		},
		{
			name:     "export inside nested block untouched",
			script:   "function f(){ const s = 'export default'; return s; }",
			wantHas:  []string{"export default"},
			wantMiss: []string{"module.exports"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := jsStripModuleSyntax(tc.script).script
			for _, want := range tc.wantHas {
				if !strings.Contains(got, want) {
					t.Fatalf("expected %q in %q", want, got)
				}
			}
			for _, miss := range tc.wantMiss {
				if strings.Contains(got, miss) {
					t.Fatalf("did not expect %q in %q", miss, got)
				}
			}
			if strings.Count(got, "\n") != strings.Count(tc.script, "\n") {
				t.Fatalf("line count changed: %q -> %q", tc.script, got)
			}
		})
	}
}

func TestJsClassifyScript(t *testing.T) {
	drpyRule := `
var rule = {
    title: '样本规则',
    host: 'https://example.com',
    url: '/fyclass/fypage.html',
    searchUrl: '/search/wd/**/page/fypage.html',
    class_name: '电影&电视剧',
    class_url: '1&2',
    一级: '.list;a&&title;img&&src',
    二级: '*',
    搜索: '.list;a&&title',
}
`
	if got := jsClassifyScript(drpyRule); got != jsShapeDrpyRule {
		t.Fatalf("drpy rule shape = %v", got)
	}
	if title, ok := jsDescribeDrpyRule(drpyRule); !ok || title != "样本规则" {
		t.Fatalf("drpy describe = %q %v", title, ok)
	}
	cat := "/*\n@header({\n  title: '猫测试',\n  lang: 'cat'\n})\n*/\nfunction home(filter){return '{}';}\nfunction detail(v){return '{}';}"
	if got := jsClassifyScript(cat); got != jsShapeCat {
		t.Fatalf("cat shape = %v", got)
	}
	module := "module.exports = { homeContent: function(){ return {}; } };"
	if got := jsClassifyScript(module); got != jsShapeModule {
		t.Fatalf("module shape = %v", got)
	}
	fn := "function homeContent(){ return {}; }"
	if got := jsClassifyScript(fn); got != jsShapeFunctionSpider {
		t.Fatalf("function shape = %v", got)
	}
	if got := jsClassifyScript("1 + 1"); got != jsShapeUnknown {
		t.Fatalf("unknown shape = %v", got)
	}
}

const jsModuleExportsFixture = `
module.exports = {
  homeContent: function() {
    return {class: [{type_id: "1", type_name: "电影"}], list: []};
  },
  categoryContent: function(tid, pg) {
    return {page: pg, pagecount: 1, list: [{vod_id: "7", vod_name: "模块片", vod_pic: ""}]};
  },
  detailContent: function(ids) {
    return {list: [{vod_id: ids[0], vod_name: "模块片", vod_play_from: "线1", vod_play_url: "第1集$https://example.com/1.m3u8"}]};
  },
  searchContent: function(key) {
    return {list: [{vod_id: "8", vod_name: "搜" + key, vod_pic: ""}]};
  },
  playerContent: function(flag, id) {
    return {parse: 0, url: id, header: {}};
  }
};
`

func TestJsSpiderModuleExports(t *testing.T) {
	home, err := jsSpiderRun(jsModuleExportsFixture, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("home: %v", err)
	}
	if classes, ok := home["class"].([]interface{}); !ok || len(classes) != 1 {
		t.Fatalf("home class = %v", home["class"])
	}
	cat, err := jsSpiderRun(jsModuleExportsFixture, "category", "1", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("category: %v", err)
	}
	if items, ok := cat["list"].([]interface{}); !ok || len(items) != 1 {
		t.Fatalf("category list = %v", cat["list"])
	}
	detail, err := jsSpiderRun(jsModuleExportsFixture, "detail", "", 1, "", "7", "", "")
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	if items, ok := detail["list"].([]interface{}); !ok || len(items) != 1 {
		t.Fatalf("detail list = %v", detail["list"])
	}
	player, err := jsSpiderRun(jsModuleExportsFixture, "player", "", 1, "", "", "线1", "https://example.com/1.m3u8")
	if err != nil {
		t.Fatalf("player: %v", err)
	}
	if player["url"] != "https://example.com/1.m3u8" {
		t.Fatalf("player url = %v", player["url"])
	}
}

// CatVod cat 形态样本：结构仿 spider/catvod/猫测试.js（@header、import、
// 短函数名、detail 单字符串参数、JSON 字符串返回、export default），
// 不含真实站址与猫库调用。
const jsCatFixture = `
/*
@header({
  searchable: 1,
  filterable: 1,
  quickSearch: 1,
  title: '猫样本',
  lang: 'cat'
})
*/

import {_, load} from "assets://js/lib/cat.js";

function init(cfg) {
    return;
}

function home(filter) {
    return JSON.stringify({class: [{type_id: 'test', type_name: '测试分类'}]});
}

function homeVod(params) {
    return JSON.stringify({list: [{vod_id: 'v1', vod_name: '首页片', vod_pic: '', vod_remarks: ''}]});
}

function category(tid, pg, filter, extend) {
    return JSON.stringify({page: pg, pagecount: 1, list: [{vod_id: 'v1', vod_name: '分类片:' + tid, vod_pic: '', vod_remarks: ''}]});
}

function detail(vod_url) {
    return JSON.stringify({list: [{vod_id: vod_url, vod_name: '详情:' + typeof vod_url, vod_play_from: '线1', vod_play_url: '第1集$https://example.com/1.m3u8'}]});
}

function play(flag, id, flags) {
    return JSON.stringify({parse: 0, url: id, header: {}});
}

function search(wd, quick) {
    return JSON.stringify({list: [{vod_id: 'v9', vod_name: '搜:' + wd, vod_pic: ''}]});
}

export default {
    init: init,
    home: home,
    homeVod: homeVod,
    category: category,
    detail: detail,
    play: play,
    search: search,
}
`

func TestJsSpiderCatFixture(t *testing.T) {
	home, err := jsSpiderRun(jsCatFixture, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("cat home: %v", err)
	}
	if classes, ok := home["class"].([]interface{}); !ok || len(classes) != 1 {
		t.Fatalf("cat home class = %v", home["class"])
	}
	cat, err := jsSpiderRun(jsCatFixture, "category", "test", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("cat category: %v", err)
	}
	items, ok := cat["list"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("cat category list = %v", cat["list"])
	}
	row := items[0].(map[string]interface{})
	if row["vod_name"] != "分类片:test" {
		t.Fatalf("cat category name = %v", row["vod_name"])
	}
	detail, err := jsSpiderRun(jsCatFixture, "detail", "", 1, "", "v1", "", "")
	if err != nil {
		t.Fatalf("cat detail: %v", err)
	}
	detailItems, ok := detail["list"].([]interface{})
	if !ok || len(detailItems) != 1 {
		t.Fatalf("cat detail list = %v", detail["list"])
	}
	detailRow := detailItems[0].(map[string]interface{})
	if detailRow["vod_name"] != "详情:string" {
		t.Fatalf("cat detail must receive a string vod_url, got name %v", detailRow["vod_name"])
	}
	if detailRow["vod_id"] != "v1" {
		t.Fatalf("cat detail vod_id = %v", detailRow["vod_id"])
	}
	search, err := jsSpiderRun(jsCatFixture, "search", "", 1, "关键字", "", "", "")
	if err != nil {
		t.Fatalf("cat search: %v", err)
	}
	if searchItems, ok := search["list"].([]interface{}); !ok || len(searchItems) != 1 {
		t.Fatalf("cat search list = %v", search["list"])
	}
	player, err := jsSpiderRun(jsCatFixture, "player", "", 1, "", "", "线1", "https://example.com/9.m3u8")
	if err != nil {
		t.Fatalf("cat player: %v", err)
	}
	if player["url"] != "https://example.com/9.m3u8" {
		t.Fatalf("cat player url = %v", player["url"])
	}
}

func TestJsSpiderDrpyRuleError(t *testing.T) {
	rule := `
var rule = {
    title: '样本规则',
    host: 'https://example.com',
    url: '/fyclass/fypage.html',
    class_name: '电影&电视剧',
    class_url: '1&2',
    一级: '.list;a&&title',
    二级: '*',
    搜索: '.list;a&&title',
    lazy: '',
}
`
	_, err := jsSpiderRun(rule, "home", "", 1, "", "", "", "")
	if err == nil {
		t.Fatal("expected drpy rule error")
	}
	if !strings.Contains(err.Error(), "drpy") || !strings.Contains(err.Error(), "样本规则") {
		t.Fatalf("drpy error should name the rule, got %v", err)
	}
}

func TestJsSpiderReqAndFetch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/page":
			w.Header().Set("X-Test", "yes")
			fmt.Fprint(w, `<div class="item"><a href="/v/1">片名</a></div>`)
		case "/echo":
			_ = r.ParseForm()
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"method":%q,"img":%q,"ua":%q}`, r.Method, r.FormValue("img"), r.Header.Get("X-Custom"))
		case "/bin":
			w.Write([]byte{0x00, 0x01, 0x02, 0xff})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	script := fmt.Sprintf(`
function homeContent() {
  var res = req(%q + "/page");
  var name = pdfh(res.content, "a&&Text");
  var href = pdfh(res.content, "a&&href");
  var fetched = fetch(%q + "/page");
  var name2 = pdfh(fetched.text(), "a&&Text");
  var posted = req(%q + "/echo", {data: {img: "abc"}, method: "POST", headers: {"X-Custom": "cat1"}});
  var echoed = posted.json();
  var bin = req(%q + "/bin", {buffer: 2});
  return {class: [], list: [{vod_id: "1", vod_name: name + "|" + href + "|" + name2 + "|" + res.status + "|" + res.headers["X-Test"] + "|" + echoed.method + "|" + echoed.img + "|" + echoed.ua + "|" + bin.content}]};
}
`, server.URL, server.URL, server.URL, server.URL)
	out, err := jsSpiderRun(script, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("req home: %v", err)
	}
	items, ok := out["list"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("req list = %v", out["list"])
	}
	row := items[0].(map[string]interface{})
	want := "片名|/v/1|片名|200|yes|POST|abc|cat1|AAEC/w=="
	if row["vod_name"] != want {
		t.Fatalf("req vod_name = %q, want %q", row["vod_name"], want)
	}
}

func TestJsSpiderBufferAndBase64(t *testing.T) {
	script := `
function homeContent() {
  var decoded = Buffer.from("aGVsbG8=", "base64").toString();
  var encoded = Buffer.from("hello").toString("base64");
  var hexed = Buffer.from("hi").toString("hex");
  var back = Buffer.from("6869", "hex").toString();
  var b64 = btoa("hello");
  var plain = atob("aGVsbG8=");
  return {class: [], list: [{vod_id: "1", vod_name: [decoded, encoded, hexed, back, b64, plain].join(",")}]};
}
`
	out, err := jsSpiderRun(script, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("buffer home: %v", err)
	}
	items, ok := out["list"].([]interface{})
	if !ok || len(items) != 1 {
		t.Fatalf("buffer list = %v", out["list"])
	}
	row := items[0].(map[string]interface{})
	if row["vod_name"] != "hello,aGVsbG8=,6869,hi,aGVsbG8=,hello" {
		t.Fatalf("buffer vod_name = %v", row["vod_name"])
	}
}

func TestJsSpiderExportsAssignment(t *testing.T) {
	script := `
exports.homeContent = function() {
  return {class: [{type_id: "1", type_name: "电影"}], list: []};
};
exports.categoryContent = function(tid, pg) {
  return {list: [{vod_id: "3", vod_name: "导出片", vod_pic: ""}]};
};
`
	home, err := jsSpiderRun(script, "home", "", 1, "", "", "", "")
	if err != nil {
		t.Fatalf("exports home: %v", err)
	}
	if classes, ok := home["class"].([]interface{}); !ok || len(classes) != 1 {
		t.Fatalf("exports home class = %v", home["class"])
	}
}
