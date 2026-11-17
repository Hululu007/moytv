package core

import (
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

// a_bogus 向量：由 py _ABogus 纯函数直接算出（见 COMPARISON.md 记录），Go 版须逐字相同。
func TestAbogusResultVectors(t *testing.T) {
	cases := []struct {
		data []byte
		s4   string
		s3   string
	}{
		{[]byte("abc"), "RIsN", "RIsN"},
		{[]byte("hello world"), "52Xu-2SEU9tn-2f=", "54Xu+4SEQ9tn+4f="},
		{[]byte("A"), "ff==", "ff=="},
		{[]byte("AB"), "f6m=", "f6K="},
		{[]byte{0, 1, 254, 255, 16, 32, 48}, "DDZCeJDE8D==", "ccZCeJcE8c=="},
	}
	for _, tc := range cases {
		if got := abogusResult(tc.data, abogusTableS4); got != tc.s4 {
			t.Fatalf("s4 %q: got %q want %q", tc.data, got, tc.s4)
		}
		if got := abogusResult(tc.data, abogusTableS3); got != tc.s3 {
			t.Fatalf("s3 %q: got %q want %q", tc.data, got, tc.s3)
		}
	}
}

func TestAbogusRC4Vectors(t *testing.T) {
	if got := hex.EncodeToString(abogusRC4([]byte("test-ua-string"), []byte{0, 1, 14})); got != "ac8c9de0eefd10a577449b652b70" {
		t.Fatalf("rc4 ua/key: got %s", got)
	}
	if got := hex.EncodeToString(abogusRC4([]byte{44, 1, 0, 24, 200, 255, 7, 19}, []byte("y"))); got != "6985a45a4c184e26" {
		t.Fatalf("rc4 y: got %s", got)
	}
}

func TestAbogusUACodeAndSM3(t *testing.T) {
	if got := hex.EncodeToString(abogusUACode(toutiaoFeedUA)); got != "46a9c0946c48073d64f9b26facdfd630a1f4b1b85466ce75ac7ac7604fab1ab6" {
		t.Fatalf("ua code: got %s", got)
	}
	if got := hex.EncodeToString(abogusSM3([]byte("GETcus"))); got != "17d6bf820b4a1c5410400a0df5cd7f93f3bbd5419135246f6e61692ae1e1b685" {
		t.Fatalf("sm3: got %s", got)
	}
}

func TestAbogusList4(t *testing.T) {
	got := abogusList4(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17)
	want := []int{44, 1, 0, 0, 0, 0, 24, 2, 13, 0, 3, 4, 0, 0, 0, 1, 0, 239, 5, 14, 6, 7, 0, 0, 0, 0, 8, 0, 0, 14, 9, 10, 0, 11, 12, 3, 15, 1, 16, 1, 17, 0, 0, 0}
	if len(got) != len(want) {
		t.Fatalf("len %d want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("index %d: got %d want %d", i, got[i], want[i])
		}
	}
}

func TestAbogusGenerateShape(t *testing.T) {
	sign := newToutiaoABogus(toutiaoFeedUA, "Win32").generate("min_behot_time=0&offset=0&channel_id=94349560412")
	if sign == "" {
		t.Fatal("empty signature")
	}
	for _, r := range sign {
		if !strings.ContainsRune(abogusTableS4+"=", r) {
			t.Fatalf("signature char %q outside s4 alphabet: %q", r, sign)
		}
	}
}

func TestToutiaoCleanTitle(t *testing.T) {
	cases := map[string]string{
		"#重生之门# 豪门弃妇了短剧":   "豪门弃妇",
		"  霸道总裁爱上我 | 短剧  ": "霸道总裁爱上我 |",
		"":                 "",
	}
	for in, want := range cases {
		if got := toutiaoCleanTitle(in); got != want {
			t.Fatalf("clean %q: got %q want %q", in, got, want)
		}
	}
}

func TestToutiaoFirstURLAndPlay(t *testing.T) {
	video := map[string]any{
		"play_addr":  map[string]any{"url_list": []any{map[string]any{"url": "https://v/1.mp4"}}},
		"url_expire": json.Number("999"),
		"duration":   json.Number("95"),
	}
	item := map[string]any{"video": video}
	rawURL, expire, dur := toutiaoPlay(item)
	if rawURL != "https://v/1.mp4" || expire != 999 || dur != 95 {
		t.Fatalf("play: %q %d %d", rawURL, expire, dur)
	}
	if got := toutiaoFirstURL("https://direct/x.mp4"); got != "https://direct/x.mp4" {
		t.Fatalf("first url string: %q", got)
	}
}

func TestHongguoNewCategories(t *testing.T) {
	if len(hongguoNewCategories) != 10 {
		t.Fatalf("categories=%d want 10", len(hongguoNewCategories))
	}
	for _, id := range []string{"", "c:real-drama", "r:hot-ai-drama", "t:jx", "c:__diag__"} {
		if !validHongguoNewCategory(id) {
			t.Fatalf("category %q should be valid", id)
		}
	}
	for _, id := range []string{"short_play", "c:nope", "x:y"} {
		if validHongguoNewCategory(id) {
			t.Fatalf("category %q should be rejected", id)
		}
	}
}

func TestParseHongguoNewSearchAPIResponse(t *testing.T) {
	body := `{"searchList":[
		{"video_data":{"series_id":"111","series_title":"重生之门","series_cover":"https://x/1.jpg","episode_cnt":80,"episode_right_text":"全80集","series_intro":"简介A"},"keyword":"kw1"},
		{"series_id":"222","series_title":"无嵌套","series_cover":"https://x/2.jpg","episode_cnt":12},
		{"video_data":{"series_id":"111","series_title":"重生之门重复","series_cover":"https://x/1.jpg"}},
		{"video_data":{"series_title":"无 id 行"}},
		{"keyword":"333","name":"只要 keyword"}
	],"totalCount":30}`
	entry, err := parseHongguoNewSearchAPIResponse(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(entry.Dramas) != 3 {
		t.Fatalf("dramas=%d want 3", len(entry.Dramas))
	}
	first := entry.Dramas[0]
	if first.SourceID != "111" || first.Source != sourceHongguoNew || first.ID != "hongguo_new:111" || first.ChannelName != hongguoNewChannelName {
		t.Fatalf("first=%+v", first)
	}
	if entry.Dramas[2].SourceID != "333" {
		t.Fatalf("keyword fallback: %+v", entry.Dramas[2])
	}
	if entry.Total != 30 || !entry.Limited {
		t.Fatalf("total=%d limited=%v want 30/true", entry.Total, entry.Limited)
	}
	if _, err := parseHongguoNewSearchAPIResponse(`not json`); err == nil {
		t.Fatal("want error for non-JSON body")
	}
}

func TestHongguoNewVidList(t *testing.T) {
	rows := []any{[]any{json.Number("100"), "200", "x"}, "300"}
	got := hongguoNewVidList(rows)
	if len(got) != 2 || got[0] != "100" || got[1] != "200" {
		t.Fatalf("nested vid_list: %v", got)
	}
	if got := hongguoNewVidList([]any{"1", "2"}); len(got) != 2 {
		t.Fatalf("flat vid_list: %v", got)
	}
	if got := hongguoNewVidList(nil); len(got) != 0 {
		t.Fatalf("nil vid_list: %v", got)
	}
}

func TestHongguoNewWalkDetail(t *testing.T) {
	data := map[string]any{"loaderData": map[string]any{"page": map[string]any{
		"series_name": "剧名", "vid_list": []any{"11", "22"},
		"nested": map[string]any{"series_name": "后来的名", "series_intro": "简介"},
	}}}
	box := hongguoNewWalkDetail(data)
	if mapString(box, "series_name") != "剧名" || mapString(box, "series_intro") != "简介" {
		t.Fatalf("walk: %+v", box)
	}
	if len(hongguoNewVidList(box["vid_list"])) != 2 {
		t.Fatalf("walk vid_list: %+v", box["vid_list"])
	}
}

func TestHongguoNewUnescapeURL(t *testing.T) {
	if got := hongguoNewUnescapeURL(`https:\/\/x\/a\u002Fb.jpg`); got != "https://x/a/b.jpg" {
		t.Fatalf("unescape: %q", got)
	}
}

func TestHongguoNewDiagSignCheck(t *testing.T) {
	// 离线：不发网络请求。跑 100 次（nonce 随机），确认不 panic 且签名头齐全。
	for i := 0; i < 100; i++ {
		if ok, detail := hongguoNewDiagSignCheck(); !ok {
			t.Fatalf("iteration %d: %s", i, detail)
		}
	}
}

func TestHongguoNewRankRow(t *testing.T) {
	// 实测行形：/rank/hot-drama 的 rankList[0]（2026-11-17 抓包），驼峰字段。
	row := map[string]any{
		"id": "7704532495357725721", "seriesId": "7704532495357725721", "rank": 1,
		"title": "持械入宋：第十一季", "cover": "https://p3-novel.byteimg.com/novel-pic/x.image",
		"episodeCount": 113, "description": "简介", "tags": []any{"AI剧", "宫廷"},
		"scoreText": "9.5分", "heatText": "9119万热度",
	}
	drama := hongguoNewDramaFromRankRow(row)
	if drama.SourceID != "7704532495357725721" || drama.Source != sourceHongguoNew ||
		drama.ID != "hongguo_new:7704532495357725721" || drama.Title != "持械入宋：第十一季" ||
		drama.Remark != "全113集" || drama.Score != "9.5分" || drama.Heat != "9119万热度" ||
		len(drama.Tags) != 2 || drama.Cover == "" || drama.Intro != "简介" {
		t.Fatalf("rank row: %+v", drama)
	}
	// 蛇形行也要通（py _item_home 同款回落）。
	snake := map[string]any{"series_id": "222", "series_title": "蛇形", "series_cover": "https://x/2.jpg", "episode_cnt": 12}
	if got := hongguoNewDramaFromRankRow(snake); got.SourceID != "222" || got.Title != "蛇形" || got.Remark != "全12集" {
		t.Fatalf("snake row: %+v", got)
	}
	// 无数字 id 的行落空。
	if got := hongguoNewDramaFromRankRow(map[string]any{"title": "无 id"}); got.ID != "" {
		t.Fatalf("no-id row should be empty: %+v", got)
	}
}

func TestHongguoNewTopicOptionsFromPage(t *testing.T) {
	// 实测行形：/category/real-drama 的 selectorList（2026-11-17 抓包）。
	page := map[string]any{"selectorList": []any{map[string]any{
		"row_id": "theme", "row_name": "主题",
		"items": []any{
			map[string]any{"selector_item_id": "romance", "show_name": "爱情", "category_json_ids": []any{"5000"}},
			map[string]any{"selector_item_id": "city", "show_name": "都市", "category_json_ids": []any{"5001"}},
			map[string]any{"selector_item_id": "empty", "show_name": "", "category_json_ids": []any{"5002"}},
			map[string]any{"selector_item_id": "noids", "show_name": "无编号"},
		},
	}}}
	options := hongguoNewTopicOptionsFromPage(page)
	if len(options) != 2 || options[0].ID != "5000" || options[0].Name != "爱情" || options[1].ID != "5001" {
		t.Fatalf("topic options: %+v", options)
	}
	if got := hongguoNewTopicOptionsFromPage(map[string]any{}); len(got) != 0 {
		t.Fatalf("empty page: %+v", got)
	}
}

func TestHongguoNewHomeItems(t *testing.T) {
	// 实测行形：首页 SSR 的 homeSections（2026-11-17 真站存页 hg_home_real_20261117.html，
	// 4 个区各 9 行，全蛇形字段）；video_list 是列表，旧 nestedMap 写法恒 0 条。
	// 行 1/2 取自“热播短剧”区前两行（逐字），行 3 取自“热播真人剧”区首行（逐字），
	// 另加一行重复（去重）与一行驼峰（py _item_home 回落）。
	row1 := map[string]any{"series_id": "7704532495357725721", "series_title": "持械入宋：第十一季", "series_cover": "https://p3-novel.byteimg.com/novel-pic/a5d74075608a35b1f34ca608f8e98ba8~tplv-shrink:640:0.image", "episode_cnt": 113, "episode_right_text": "全113集"}
	row2 := map[string]any{"series_id": "7705824595416190014", "series_title": "穿越八零，我把娘俩宠成宝", "series_cover": "https://p6-novel.byteimg.com/novel-pic/898c39547d16b1ddb3c5ab399559ecc1~tplv-shrink:640:0.image", "episode_cnt": 317, "episode_right_text": "全317集"}
	row3 := map[string]any{"series_id": "7706512650816982040", "series_title": "少夫人来自东北3", "series_cover": "https://p3-novel.byteimg.com/novel-pic/899ba52ee34a534d9be948a093468ed1~tplv-shrink:640:0.image", "episode_cnt": 96, "episode_right_text": "全96集"}
	camel := map[string]any{"seriesId": "7700000000000000001", "title": "驼峰行", "cover": "https://x/camel.jpg", "episodeCount": 20}
	data := map[string]any{"loaderData": map[string]any{"page": map[string]any{"homeSections": []any{
		map[string]any{"tab_name": "热播短剧", "video_list": []any{row1, row2}},
		map[string]any{"tab_name": "热播真人剧", "video_list": []any{row3, row1, camel}},
		map[string]any{"tab_name": "无列表区"},
	}}}}
	items := hongguoNewHomeItems(data)
	if len(items) != 4 {
		t.Fatalf("home items: got %d want 4: %+v", len(items), items)
	}
	if items[0].Title != "持械入宋：第十一季" || items[1].Title != "穿越八零，我把娘俩宠成宝" ||
		items[2].Title != "少夫人来自东北3" || items[3].Title != "驼峰行" {
		t.Fatalf("home titles: %+v", items)
	}
	for _, item := range items {
		if item.Source != sourceHongguoNew || item.Cover == "" || item.SourceID == "" {
			t.Fatalf("home item not relabelled: %+v", item)
		}
	}
	if items[0].Remark != "全113集" || items[3].Remark != "全20集" {
		t.Fatalf("home remarks: %+v", items)
	}
	if got := hongguoNewHomeItems(nil); len(got) != 0 {
		t.Fatalf("nil data: %+v", got)
	}
	if got := hongguoNewHomeItems(map[string]any{}); len(got) != 0 {
		t.Fatalf("empty data: %+v", got)
	}
}
