package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func httpAggPayload(t *testing.T, text string) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal([]byte(text), &payload); err != nil {
		t.Fatalf("fixture JSON invalid: %v", err)
	}
	return payload
}

func TestHTTPAggDecodeBody(t *testing.T) {
	payload, err := httpAggDecodeBody(`{"list": [], "code": 1}`)
	if err != nil || payload["code"] == nil {
		t.Fatalf("object decode: %v %+v", err, payload)
	}
	payload, err = httpAggDecodeBody(`[{"vod_id": "1", "vod_name": "A"}]`)
	if err != nil {
		t.Fatalf("array decode: %v", err)
	}
	if items := httpAggItems(payload); len(items) != 1 {
		t.Fatalf("array items = %v", items)
	}
	payload, err = httpAggDecodeBody(`cb({"list": [{"vod_id": "2", "vod_name": "B"}]});`)
	if err != nil {
		t.Fatalf("jsonp decode: %v", err)
	}
	if items := httpAggItems(payload); len(items) != 1 || httpAggFirstString(items[0], "vod_id") != "2" {
		t.Fatalf("jsonp items = %v", items)
	}
	if _, err := httpAggDecodeBody(`not json at all`); err == nil {
		t.Fatal("garbage should fail")
	}
	if _, err := httpAggDecodeBody(``); err == nil {
		t.Fatal("empty should fail")
	}
}

func TestHTTPAggItemsAndClasses(t *testing.T) {
	envelope := httpAggPayload(t, `{
		"code": 1, "msg": "ok",
		"data": {
			"class": [{"type_id": "1", "type_name": "电影"}, {"type_id": "interests", "type_name": "猜你喜欢"}],
			"list": [{"vod_id": "10", "vod_name": "信封片", "vod_pic": "https://example.com/a.jpg"}]
		}
	}`)
	if items := httpAggItems(envelope); len(items) != 1 || httpAggFirstString(items[0], "vod_name") != "信封片" {
		t.Fatalf("envelope items = %v", items)
	}
	if classes := httpAggClasses(envelope); len(classes) != 1 || classes[0].id != "1" {
		t.Fatalf("envelope classes = %v (interests must be skipped)", classes)
	}

	aliased := httpAggPayload(t, `{
		"types": [{"id": "5", "name": "剧集"}, {"tid": "6", "title": "综艺"}],
		"items": [{"id": 42, "title": "别名片", "cover": "https://example.com/b.jpg", "desc": "简介", "remarks": "完结"}]
	}`)
	if classes := httpAggClasses(aliased); len(classes) != 2 || classes[1].id != "6" || classes[1].name != "综艺" {
		t.Fatalf("aliased classes = %v", classes)
	}
	items := httpAggItems(aliased)
	if len(items) != 1 {
		t.Fatalf("aliased items = %v", items)
	}
	drama := httpAggDrama("custom:test", items[0])
	if drama.SourceID != "42" || drama.Title != "别名片" || drama.Cover != "https://example.com/b.jpg" || drama.Intro != "简介" || drama.Remark != "完结" {
		t.Fatalf("aliased drama = %+v", drama)
	}

	bare := httpAggPayload(t, `{"vod_id": "77", "vod_name": "裸对象片", "vod_pic": ""}`)
	if items := httpAggItems(bare); len(items) != 1 {
		t.Fatalf("bare object items = %v", items)
	}
	if drama := httpAggDrama("custom:test", map[string]any{"vod_name": "无 id"}); drama.SourceID != "" {
		t.Fatalf("missing id must yield empty drama, got %+v", drama)
	}
}

func TestHTTPAggRoutes(t *testing.T) {
	// 旧字符串形态与 T4 原解析一致。
	classic := httpAggPayload(t, `{"vod_play_from": "线1$$$线2", "vod_play_url": "第1集$https://a.test/1.m3u8#第2集$https://a.test/2.m3u8$$$第1集$https://b.test/1.mp4"}`)
	routes := t4ParseRoutes(classic)
	if len(routes) != 2 || routes[0].flag != "线1" || len(routes[0].episodes) != 2 || routes[1].episodes[0].playID != "https://b.test/1.mp4" {
		t.Fatalf("classic routes = %+v", routes)
	}

	// 换行分隔分集 + 裸地址。
	newlines := httpAggPayload(t, `{"vod_play_url": "第1集$https://a.test/1.m3u8\r\nhttps://a.test/2.m3u8"}`)
	routes = httpAggRoutes(newlines)
	if len(routes) != 1 || len(routes[0].episodes) != 2 || routes[0].episodes[1].playID != "https://a.test/2.m3u8" {
		t.Fatalf("newline routes = %+v", routes)
	}

	// 数组形态：字符串数组。
	arr := httpAggPayload(t, `{"vod_play_url": ["第1集$https://a.test/1.m3u8", "https://a.test/2.m3u8"]}`)
	routes = httpAggRoutes(arr)
	if len(routes) != 1 || len(routes[0].episodes) != 2 || routes[0].episodes[0].title != "第1集" {
		t.Fatalf("array routes = %+v", routes)
	}

	// 数组形态：对象数组。
	objArr := httpAggPayload(t, `{"vod_play_url": [{"name": "EP1", "url": "https://a.test/1.m3u8"}, {"title": "EP2", "play_url": "https://a.test/2.m3u8"}]}`)
	routes = httpAggRoutes(objArr)
	if len(routes) != 1 || len(routes[0].episodes) != 2 || routes[0].episodes[1].title != "EP2" {
		t.Fatalf("object array routes = %+v", routes)
	}

	// 分组数组 + 线路数组。
	grouped := httpAggPayload(t, `{"vod_play_from": ["线A", "线B"], "vod_play_url": [[{"name": "1", "url": "https://a.test/1"}], [{"name": "1", "url": "https://b.test/1"}]]}`)
	routes = httpAggRoutes(grouped)
	if len(routes) != 2 || routes[0].flag != "线A" || routes[1].flag != "线B" {
		t.Fatalf("grouped routes = %+v", routes)
	}

	// 映射形态。
	mapped := httpAggPayload(t, `{"vod_play_url": {"线甲": "第1集$https://a.test/1.m3u8", "线乙": "第1集$https://b.test/1.m3u8"}}`)
	routes = httpAggRoutes(mapped)
	if len(routes) != 2 || routes[0].flag != "线乙" || routes[1].flag != "线甲" {
		t.Fatalf("map routes must be sorted by flag, got %+v", routes)
	}

	// episodes 数组形态。
	eps := httpAggPayload(t, `{"episodes": [{"name": "第1集", "url": "https://a.test/1.m3u8"}, {"name": "第2集", "url": "https://a.test/2.m3u8"}]}`)
	routes = httpAggRoutes(eps)
	if len(routes) != 1 || len(routes[0].episodes) != 2 {
		t.Fatalf("episodes routes = %+v", routes)
	}

	// 无播放字段。
	if routes := httpAggRoutes(httpAggPayload(t, `{"vod_id": "1"}`)); len(routes) != 0 {
		t.Fatalf("empty routes = %+v", routes)
	}
}

func TestHTTPAggPlay(t *testing.T) {
	// 直链 + 对象 header（T4 旧实现只认 JSON 字符串 header，对象会被丢）。
	direct := httpAggPlay(httpAggPayload(t, `{"url": "https://a.test/1.m3u8", "header": {"Referer": "https://a.test/", "User-Agent": "UA1"}}`))
	if !direct.hasURL || direct.url != "https://a.test/1.m3u8" || direct.needsParse || direct.headers["Referer"] != "https://a.test/" {
		t.Fatalf("direct play = %+v", direct)
	}

	// JSON 字符串 header（旧形态仍认）。
	jsonHeader := httpAggPlay(httpAggPayload(t, `{"url": "https://a.test/1.m3u8", "header": "{\"Cookie\": \"a=b\"}"}`))
	if jsonHeader.headers["Cookie"] != "a=b" {
		t.Fatalf("json header = %+v", jsonHeader)
	}

	// 键值对列表 header。
	listHeader := httpAggPlay(httpAggPayload(t, `{"url": "https://a.test/1.m3u8", "headers": [["Referer", "https://a.test/"], {"key": "Cookie", "value": "x=y"}]}`))
	if listHeader.headers["Referer"] != "https://a.test/" || listHeader.headers["Cookie"] != "x=y" {
		t.Fatalf("list header = %+v", listHeader)
	}

	// parse=1 + playUrl 拼接（旧口径）。
	concat := httpAggPlay(httpAggPayload(t, `{"url": "https://a.test/play?id=1", "parse": 1, "playUrl": "https://jx.test/?url="}`))
	if concat.url != "https://jx.test/?url=https://a.test/play?id=1" || concat.needsParse {
		t.Fatalf("concat play = %+v", concat)
	}

	// parse=1 无 playUrl → 需要二次解析。
	needParse := httpAggPlay(httpAggPayload(t, `{"url": "https://a.test/play?id=1", "parse": "1"}`))
	if !needParse.needsParse || needParse.url != "https://a.test/play?id=1" {
		t.Fatalf("needParse play = %+v", needParse)
	}

	// jx 布尔旗标 + video_url 别名 + data 信封。
	envelope := httpAggPlay(httpAggPayload(t, `{"code": 0, "data": {"video_url": "https://a.test/2.m3u8", "jx": true}}`))
	if !envelope.hasURL || envelope.url != "https://a.test/2.m3u8" || !envelope.needsParse {
		t.Fatalf("envelope play = %+v", envelope)
	}

	// 无地址。
	if played := httpAggPlay(httpAggPayload(t, `{"msg": "no url"}`)); played.hasURL {
		t.Fatalf("empty play = %+v", played)
	}
}

func TestHTTPAggHasMore(t *testing.T) {
	if !httpAggHasMore(httpAggPayload(t, `{"pagecount": 5}`), 2, 10) {
		t.Fatal("pagecount 5 page 2 must have more")
	}
	if httpAggHasMore(httpAggPayload(t, `{"pagecount": 2}`), 2, 10) {
		t.Fatal("pagecount 2 page 2 must not have more")
	}
	if !httpAggHasMore(httpAggPayload(t, `{"total": 100}`), 1, 20) {
		t.Fatal("total 100 page 1 size 20 must have more")
	}
	if httpAggHasMore(httpAggPayload(t, `{"total": 20}`), 1, 20) {
		t.Fatal("total 20 page 1 size 20 must not have more")
	}
	if !httpAggHasMore(httpAggPayload(t, `{}`), 1, 30) {
		t.Fatal("30 items fallback must have more")
	}
	if httpAggHasMore(httpAggPayload(t, `{}`), 1, 5) {
		t.Fatal("5 items fallback must not have more")
	}
}

func TestDrpysRequestParams(t *testing.T) {
	category := drpysRequestParams("category", "7", 2, "", "", "", "")
	if category["ac"] != "1" || category["t"] != "7" || category["pg"] != "2" {
		t.Fatalf("drpys category params = %v (ac is required by /api/:module dispatch)", category)
	}
	detail := drpysRequestParams("detail", "", 0, "", "123", "", "")
	if detail["ac"] != "1" || detail["ids"] != "123" {
		t.Fatalf("drpys detail params = %v", detail)
	}
	search := drpysRequestParams("search", "", 0, "关键字", "", "", "")
	if search["wd"] != "关键字" {
		t.Fatalf("drpys search params = %v", search)
	}
	play := drpysRequestParams("play", "", 0, "", "", "线1", "play-id")
	if play["play"] != "play-id" || play["flag"] != "线1" {
		t.Fatalf("drpys play params = %v", play)
	}
	if home := drpysRequestParams("home", "", 0, "", "", "", ""); home != nil {
		t.Fatalf("drpys home params = %v", home)
	}
	if token := drpysPlayToken("线1", "abc"); token != t4PlayToken("线1", "abc") {
		t.Fatalf("drpys token must reuse t4 token format, got %q", token)
	}
	if flag, playID, ok := drpysParsePlayToken(drpysPlayToken("线1", "abc")); !ok || flag != "线1" || playID != "abc" {
		t.Fatalf("drpys token round trip = %q %q %v", flag, playID, ok)
	}
}

func TestDrpysSourceType(t *testing.T) {
	if normalizeCustomSourceType("drpys") != "drpys" {
		t.Fatal("drpys kind must survive normalization")
	}
	if normalizeCustomSourceType("DRPYS") != "drpys" {
		t.Fatal("drpys kind must normalize case")
	}
	if normalizeCustomSourceType("bogus") != "" {
		t.Fatal("unknown kind must normalize to empty")
	}
	if !customSourceAllowsQuery("drpys") {
		t.Fatal("drpys api urls may carry query params like t4")
	}
	if customSourceAllowsQuery("web") {
		t.Fatal("web kind must not allow query")
	}
}

func TestCustomSourceDraftsCompat(t *testing.T) {
	// data 信封里的 sites。
	drafts, _ := customSourceDrafts(`{"code": 1, "data": {"sites": [{"name": "信封站", "url": "https://env.example.com/api.php/provide/vod/"}]}}`)
	if len(drafts) != 1 || drafts[0].Name != "信封站" {
		t.Fatalf("envelope drafts = %+v", drafts)
	}

	// .js/.py/csp_ 条目明示跳过，不注册成坏站。
	drafts, notes := customSourceDrafts(`{"sites": [
		{"key": "js1", "name": "JS站", "api": "https://cdn.example.com/spider.js?v=2"},
		{"key": "py1", "name": "PY站", "api": "https://cdn.example.com/spider.py"},
		{"key": "jar1", "name": "Jar站", "api": "csp_Demo"},
		{"key": "ok1", "name": "好站", "api": "https://ok.example.com/api.php/provide/vod/"}
	]}`)
	if len(drafts) != 1 || drafts[0].Name != "好站" {
		t.Fatalf("script drafts = %+v notes=%v", drafts, notes)
	}
	joined := strings.Join(notes, "\n")
	if !strings.Contains(joined, "JS 蜘蛛") || !strings.Contains(joined, "py 蜘蛛") || !strings.Contains(joined, "jar") {
		t.Fatalf("skip notes must name each script shape: %v", notes)
	}

	// api.php 端点不被当成 PHP 蜘蛛文件跳过。
	drafts, _ = customSourceDrafts(`{"sites": [{"name": "采集站", "api": "https://c.example.com/api.php/provide/vod/at/json"}]}`)
	if len(drafts) != 1 {
		t.Fatalf("api.php drafts = %+v", drafts)
	}
}
