package core

// 番茄槽单元测试：参数袋、行映射、游标翻页、恢复环，全部桩传输，不出网。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fanqieFixtureRowJSON：一条 change 形状的视频行（字段名与 2026-11-17 活站
// 探针实测一致；series_id 走 json.Number 解码，与生产解码器同款）。
func fanqieFixtureRowJSON(seriesID, vid, title string, episodeCnt int) string {
	return fmt.Sprintf(`{"series_id":%s,"vid":%s,"title":%q,"cover":"https://example.invalid/c.jpg","video_desc":"简介","episode_cnt":%d,"score":9.1,"play_cnt":12345,"disable_play":false,"pay_info":{}}`, seriesID, vid, title, episodeCnt)
}

func fanqieFixturePlanJSON(cellID, sessionID string, rows ...string) string {
	return fmt.Sprintf(`{"code":"0","data":[{"cell_id_str":%q,"session_id":%q,"cell_selector":{},"has_more":true,"next_offset":10,"show_type":505,"cell_data":[{"video_data":[%s]}]}]}`, cellID, sessionID, strings.Join(rows, ","))
}

func fanqieFixtureChangeJSON(sessionID string, nextOffset int, hasMore bool, rows ...string) string {
	return fmt.Sprintf(`{"code":"0","data":{"cell_view":{"cell_data":[{"video_data":[%s]}]},"has_more":%v,"next_offset":%d,"session_id":%q}}`, strings.Join(rows, ","), hasMore, nextOffset, sessionID)
}

// fanqieFixtureDeviceRegister：与 hongguoRotationFixture 同款设备注册桩：
// 每次注册返回递增 id（1001 起），顶层 device_id_str/install_id_str 键。
func fanqieFixtureDeviceRegister(nextID *int) func(*http.Request) (*http.Response, error) {
	return func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			*nextID++
			return sourceFixtureResponse(request, http.StatusOK, fmt.Sprintf(`{"device_id_str":%q,"install_id_str":%q}`, fmt.Sprintf("%d", *nextID), fmt.Sprintf("%d9", *nextID))), nil
		}
		return nil, nil
	}
}

// fanqieSeedDevice：预置一个已注册设备（与 hongguoRotationFixture 测试同款），
// 让恢复环的首次请求带设备 7 发出、轮换后换新 id。
func fanqieSeedDevice(d *Downloader) {
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
}

func TestFanqiePlanParams(t *testing.T) {
	params := fanqiePlanParams("uuid-1")
	if got := params.Get("from"); got != "video_ranklist" {
		t.Fatalf("from = %q, want video_ranklist", got)
	}
	if got := params.Get("bookstore_tab_type"); got != "26" {
		t.Fatalf("bookstore_tab_type = %q, want 26", got)
	}
	if got := params.Get("scene"); got != "10" {
		t.Fatalf("scene = %q, want 10", got)
	}
	if got := params.Get("session_uuid"); got != "uuid-1" {
		t.Fatalf("session_uuid = %q, want uuid-1", got)
	}
	if _, ok := params["source"]; ok {
		t.Fatal("plan 参数绝不能含 source（重加 source 即回 101116）")
	}
	if len(params) != 7 {
		t.Fatalf("plan 参数 %d 个，want 7", len(params))
	}
}

func TestFanqieCellChangeParams(t *testing.T) {
	params := fanqieCellChangeParams("cell-1", "sess-1", "8", "0", "2")
	checks := map[string]string{
		"cell_id": "cell-1", "session_id": "sess-1", "tab_type": "8", "offset": "0",
		"client_template": "2", "client_req_type": "2",
		"unlimited_selector_change_type": "2",
		"selected_items":                 "all", "sub_selected_items": "ranklist_hot_sc",
		"screen_width_px": "1281",
	}
	for key, want := range checks {
		if got := params.Get(key); got != want {
			t.Fatalf("%s = %q, want %q", key, got, want)
		}
	}
	paging := fanqieCellChangeParams("cell-1", "sess-1", "8", "6", "1")
	if got := paging.Get("unlimited_selector_change_type"); got != "1" {
		t.Fatalf("翻页 selector = %q, want 1 (GetMore)", got)
	}
	if got := paging.Get("offset"); got != "6" {
		t.Fatalf("翻页 offset = %q, want 6", got)
	}
	noSession := fanqieCellChangeParams("cell-1", "", "8", "0", "2")
	if _, ok := noSession["session_id"]; ok {
		t.Fatal("session_id 为空时不应出现在参数里")
	}
}

func TestFanqieHasVideoItems(t *testing.T) {
	decode := func(t *testing.T, body string) map[string]any {
		t.Helper()
		var value map[string]any
		if err := json.Unmarshal([]byte(body), &value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	plan := decode(t, `{"data":[{"cell_data":[{"video_data":[{"series_id":1}]}]}]}`)
	if !fanqieHasVideoItems(plan) {
		t.Fatal("plan 形回包应判有视频")
	}
	change := decode(t, `{"data":{"cell_view":{"cell_data":[{"video_data":[{"series_id":1}]}]}}}`)
	if !fanqieHasVideoItems(change) {
		t.Fatal("change 形回包应判有视频")
	}
	empty := decode(t, `{"data":{"cell_view":{"cell_data":[{"video_data":[]}]}}}`)
	if fanqieHasVideoItems(empty) {
		t.Fatal("空 video_data 应判无视频")
	}
	if fanqieHasVideoItems(map[string]any{"data": map[string]any{}}) {
		t.Fatal("无 video_data 应判无视频")
	}
}

func TestFanqieDramaFromRow(t *testing.T) {
	// 用生产同款 UseNumber 解码，series_id 必须一字不差（超 float64 精度）。
	var row map[string]any
	decoder := json.NewDecoder(strings.NewReader(fanqieFixtureRowJSON("7690961604636052505", "7690963410778868761", "军需处长的账本", 46)))
	decoder.UseNumber()
	if err := decoder.Decode(&row); err != nil {
		t.Fatal(err)
	}
	drama := fanqieDramaFromRow(row)
	if drama.ID != "fanqie:7690961604636052505" {
		t.Fatalf("ID = %q, want fanqie:7690961604636052505", drama.ID)
	}
	if drama.Source != sourceFanqie || drama.ChannelName != "番茄" {
		t.Fatalf("Source/ChannelName = %q/%q", drama.Source, drama.ChannelName)
	}
	if drama.Title != "军需处长的账本" {
		t.Fatalf("Title = %q", drama.Title)
	}
	if cover, ok := drama.Cover.(string); !ok || !strings.HasPrefix(cover, "https://example.invalid/") {
		t.Fatalf("Cover = %v", drama.Cover)
	}
	if drama.Remark != "共46集" {
		t.Fatalf("Remark = %q, want 共46集", drama.Remark)
	}
	// 短剧模板卡：标题/封面/简介在 video_detail 里，行上只有 id。
	detailRow := map[string]any{
		"series_id": json.Number("7671966197985856536"),
		"video_detail": map[string]any{
			"series_title": "持械入宋：第一季", "series_cover": "https://example.invalid/d.jpg", "series_intro": "简介二",
		},
	}
	drama = fanqieDramaFromRow(detailRow)
	if drama.Title != "持械入宋：第一季" {
		t.Fatalf("video_detail 未提上来：Title=%q", drama.Title)
	}
	if cover, ok := drama.Cover.(string); !ok || cover != "https://example.invalid/d.jpg" {
		t.Fatalf("video_detail 未提上来：Cover=%v", drama.Cover)
	}
	if drama.Intro != "简介二" {
		t.Fatalf("Intro = %q", drama.Intro)
	}
	// 无 series_id 的行不可播，跳过。
	if drama := fanqieDramaFromRow(map[string]any{"title": "无 id"}); drama.ID != "" {
		t.Fatalf("无 series_id 的行应返回空 Drama，得 %q", drama.ID)
	}
}

func TestFanqieCollectVideoRows(t *testing.T) {
	var payload map[string]any
	decoder := json.NewDecoder(strings.NewReader(fanqieFixturePlanJSON("c1", "s1",
		fanqieFixtureRowJSON("1", "11", "甲", 10),
		fanqieFixtureRowJSON("2", "22", "乙", 20))))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	fanqieCollectVideoRows(payload["data"], &rows)
	if len(rows) != 2 {
		t.Fatalf("plan 形收集 %d 行，want 2", len(rows))
	}
	var change map[string]any
	decoder = json.NewDecoder(strings.NewReader(fanqieFixtureChangeJSON("s1", 6, true,
		fanqieFixtureRowJSON("3", "33", "丙", 30))))
	decoder.UseNumber()
	if err := decoder.Decode(&change); err != nil {
		t.Fatal(err)
	}
	rows = nil
	fanqieCollectVideoRows(change["data"], &rows)
	if len(rows) != 1 {
		t.Fatalf("change 形收集 %d 行，want 1", len(rows))
	}
}

func TestFanqieRelabel(t *testing.T) {
	drama := fanqieRelabelDrama(Drama{ID: "hongguo_new:123", Source: sourceHongguoNew, SourceID: "123", Title: "剧"})
	if drama.ID != "fanqie:123" || drama.Source != sourceFanqie || drama.ChannelName != "番茄" {
		t.Fatalf("改挂后 ID/Source/ChannelName = %q/%q/%q", drama.ID, drama.Source, drama.ChannelName)
	}
	chapters := fanqieRelabelChapters([]Chapter{
		{ID: "hongguo_new:123:456", Source: sourceHongguoNew, Title: "第1集", VideoURL: hongguoNewCENCURLPrefix + "456"},
		{ID: "hongguo_new:123:789", Source: sourceHongguoNew, Title: "第2集", VideoURL: "hongguo-cenc://789"},
		{ID: "hongguo_new:123:x", Source: sourceHongguoNew, Title: "坏行", VideoURL: hongguoNewCENCURLPrefix + "x"},
	}, "123")
	if len(chapters) != 2 {
		t.Fatalf("分集改挂 %d 条，want 2（非数字 vid 丢弃）", len(chapters))
	}
	if chapters[0].ID != "fanqie:123:456" || chapters[0].VideoURL != fanqieCENCURLPrefix+"456" {
		t.Fatalf("分集 1 = %q/%q", chapters[0].ID, chapters[0].VideoURL)
	}
	if chapters[1].VideoURL != fanqieCENCURLPrefix+"789" {
		t.Fatalf("分集 2 VideoURL = %q", chapters[1].VideoURL)
	}
}

func TestFanqieCatalogValidation(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		t.Fatal("非法分类不应发出请求")
		return nil, nil
	})
	if _, _, _, err := d.fetchFanqieCatalogPage(context.Background(), "drama", 1); err == nil {
		t.Fatal("非空分类应报错")
	}
}

func TestFanqieDispatch(t *testing.T) {
	registered := false
	for _, descriptor := range nativeProviderRegistry {
		if descriptor.ID == sourceFanqie {
			registered = true
		}
	}
	if !registered {
		t.Fatal("番茄槽应在注册表里")
	}
	if providerSupportsFilters(sourceFanqie) {
		t.Fatal("番茄无筛选组，providerSupportsFilters 应为假")
	}
	if !validNativeCategory(sourceFanqie, "") || validNativeCategory(sourceFanqie, "drama") {
		t.Fatal("番茄分类校验：空放行、非空拒绝")
	}
	if !nativeSourceSupportsSearch(sourceFanqie) {
		t.Fatal("番茄槽应支持搜索")
	}
	if !isHuangguoProviderSource(sourceFanqie) {
		t.Fatal("番茄槽应进 isHuangguoProviderSource")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer engine.downloads.close()
	categories, err := engine.nativeCategories(context.Background(), sourceFanqie, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(categories) != 1 || categories[0].Name != "全部" {
		t.Fatalf("番茄分类 = %+v, want 仅全部", categories)
	}
	if base := engine.downloader.providerBaseURL(sourceFanqie); !strings.Contains(base, "hongguo") {
		t.Fatalf("番茄 providerBaseURL = %q", base)
	}
}

// TestFanqieFeedRecovery：空回包走恢复环——plan 首次回空正文，标记受限、
// 换设备身份重试后成功；断言设备 id 换了、plan 请求恰好 2 次、change 带上种子。
func TestFanqieFeedRecovery(t *testing.T) {
	nextID := 1000
	planCalls := 0
	var changeQueries []string
	transport := func(request *http.Request) (*http.Response, error) {
		if response, err := fanqieFixtureDeviceRegister(&nextID)(request); response != nil || err != nil {
			return response, err
		}
		switch {
		case strings.Contains(request.URL.Path, "/reading/bookapi/plan/v"):
			planCalls++
			if planCalls == 1 {
				return sourceFixtureResponse(request, http.StatusOK, ""), nil
			}
			return sourceFixtureResponse(request, http.StatusOK, fanqieFixturePlanJSON("cell-9", "sess-9",
				fanqieFixtureRowJSON("111", "1111", "种子剧", 12))), nil
		case strings.Contains(request.URL.Path, "/reading/bookapi/bookmall/cell/change/v"):
			changeQueries = append(changeQueries, request.URL.RawQuery)
			return sourceFixtureResponse(request, http.StatusOK, fanqieFixtureChangeJSON("sess-9", 6, true,
				fanqieFixtureRowJSON("222", "2222", "流剧", 24))), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, `{"code":"404"}`), nil
	}
	d := sourceFixtureDownloader(t, transport)
	fanqieSeedDevice(d)
	items, hasMore, err := d.fetchFanqieFeed(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Title != "流剧" {
		t.Fatalf("恢复后 items = %+v, want 1 条流剧", items)
	}
	if !hasMore {
		t.Fatal("hasMore 应为真")
	}
	if planCalls != 2 {
		t.Fatalf("plan 请求 %d 次，want 2（空回包 + 换设备重试）", planCalls)
	}
	if got := d.hongguoDeviceID(); got != "1001" {
		t.Fatalf("设备 id = %q, want 1001（轮换后）", got)
	}
	if len(changeQueries) != 1 {
		t.Fatalf("change 请求 %d 次，want 1", len(changeQueries))
	}
	if !strings.Contains(changeQueries[0], "cell_id=cell-9") || !strings.Contains(changeQueries[0], "unlimited_selector_change_type=2") {
		t.Fatalf("change 未带种子/首屏 selector：%s", changeQueries[0])
	}
}

// TestFanqieFeedPaging：首屏 + 翻页游标链——第 2 页 offset 取上页 next_offset，
// 耗尽后 hasMore 为假；两页剧集 id 不重叠。
func TestFanqieFeedPaging(t *testing.T) {
	nextID := 1000
	var changeOffsets []string
	transport := func(request *http.Request) (*http.Response, error) {
		if response, err := fanqieFixtureDeviceRegister(&nextID)(request); response != nil || err != nil {
			return response, err
		}
		switch {
		case strings.Contains(request.URL.Path, "/reading/bookapi/plan/v"):
			return sourceFixtureResponse(request, http.StatusOK, fanqieFixturePlanJSON("cell-9", "sess-9",
				fanqieFixtureRowJSON("111", "1111", "种子剧", 12))), nil
		case strings.Contains(request.URL.Path, "/reading/bookapi/bookmall/cell/change/v"):
			offset := request.URL.Query().Get("offset")
			changeOffsets = append(changeOffsets, offset)
			if offset == "0" {
				return sourceFixtureResponse(request, http.StatusOK, fanqieFixtureChangeJSON("sess-9", 6, true,
					fanqieFixtureRowJSON("201", "2011", "一页一", 10),
					fanqieFixtureRowJSON("202", "2022", "一页二", 20))), nil
			}
			return sourceFixtureResponse(request, http.StatusOK, fanqieFixtureChangeJSON("sess-9", 16, false,
				fanqieFixtureRowJSON("203", "2033", "二页一", 30))), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, `{"code":"404"}`), nil
	}
	d := sourceFixtureDownloader(t, transport)
	fanqieSeedDevice(d)
	page1, more1, _, err := d.fetchFanqieCatalogPage(context.Background(), "", 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page1) != 2 || !more1 {
		t.Fatalf("第 1 页 %d 条 hasMore=%v, want 2/true", len(page1), more1)
	}
	page2, more2, _, err := d.fetchFanqieCatalogPage(context.Background(), "", 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(page2) != 1 || more2 {
		t.Fatalf("第 2 页 %d 条 hasMore=%v, want 1/false", len(page2), more2)
	}
	if page2[0].ID == page1[0].ID || page2[0].ID == page1[1].ID {
		t.Fatalf("翻页剧集与首屏重叠：%q", page2[0].ID)
	}
	if len(changeOffsets) != 2 || changeOffsets[0] != "0" || changeOffsets[1] != "6" {
		t.Fatalf("change offsets = %v, want [0 6]", changeOffsets)
	}
}

// TestFanqieFeedChangeEmptyFallback：change 首屏回空时回 plan 首屏，
// 不出空白页；游标取 plan 的 next_offset。
func TestFanqieFeedChangeEmptyFallback(t *testing.T) {
	nextID := 1000
	transport := func(request *http.Request) (*http.Response, error) {
		if response, err := fanqieFixtureDeviceRegister(&nextID)(request); response != nil || err != nil {
			return response, err
		}
		switch {
		case strings.Contains(request.URL.Path, "/reading/bookapi/plan/v"):
			return sourceFixtureResponse(request, http.StatusOK, fanqieFixturePlanJSON("cell-9", "sess-9",
				fanqieFixtureRowJSON("301", "3011", "计划一", 10),
				fanqieFixtureRowJSON("302", "3022", "计划二", 20))), nil
		case strings.Contains(request.URL.Path, "/reading/bookapi/bookmall/cell/change/v"):
			return sourceFixtureResponse(request, http.StatusOK, `{"code":"0","data":{"cell_view":{"cell_data":[]},"has_more":false,"next_offset":0}}`), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, `{"code":"404"}`), nil
	}
	d := sourceFixtureDownloader(t, transport)
	fanqieSeedDevice(d)
	items, hasMore, err := d.fetchFanqieFeed(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("回落 items = %d 条，want 2（plan 首屏）", len(items))
	}
	if !hasMore {
		t.Fatal("plan has_more=true 且 next_offset=10，hasMore 应为真")
	}
	cursor := d.fanqieReadCursor()
	if cursor.Offset != 10 || cursor.LastID != "cell-9" || cursor.SessionID != "sess-9" {
		t.Fatalf("回落游标 = %+v", cursor)
	}
}

// TestFanqieFeedAllEmptyBounded：全空回包时轮换有界——恰好
// hongguoDeviceRotations+1 次 plan 请求后报空回包错误，不死循环。
func TestFanqieFeedAllEmptyBounded(t *testing.T) {
	nextID := 1000
	planCalls := 0
	transport := func(request *http.Request) (*http.Response, error) {
		if response, err := fanqieFixtureDeviceRegister(&nextID)(request); response != nil || err != nil {
			return response, err
		}
		if strings.Contains(request.URL.Path, "/reading/bookapi/plan/v") {
			planCalls++
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, `{"code":"404"}`), nil
	}
	d := sourceFixtureDownloader(t, transport)
	fanqieSeedDevice(d)
	start := time.Now()
	_, _, err := d.fetchFanqieFeed(context.Background(), false)
	if !errors.Is(err, errHongguoAppEmptyBody) {
		t.Fatalf("err = %v, want errHongguoAppEmptyBody", err)
	}
	if planCalls != hongguoDeviceRotations+1 {
		t.Fatalf("plan 请求 %d 次，want %d", planCalls, hongguoDeviceRotations+1)
	}
	if elapsed := time.Since(start); elapsed > fanqieFeedBudget {
		t.Fatalf("耗时 %v 超预算 %v", elapsed, fanqieFeedBudget)
	}
}

// TestFanqieFeedBudgetCutsRotation：预算耗尽时轮换被截断——
// 500ms 预算下只发 1 次 plan 请求就返回（退避睡眠被 ctx 截断）。
func TestFanqieFeedBudgetCutsRotation(t *testing.T) {
	oldBudget := fanqieFeedBudget
	fanqieFeedBudget = 500 * time.Millisecond
	defer func() { fanqieFeedBudget = oldBudget }()
	nextID := 1000
	planCalls := 0
	transport := func(request *http.Request) (*http.Response, error) {
		if response, err := fanqieFixtureDeviceRegister(&nextID)(request); response != nil || err != nil {
			return response, err
		}
		if strings.Contains(request.URL.Path, "/reading/bookapi/plan/v") {
			planCalls++
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, `{"code":"404"}`), nil
	}
	d := sourceFixtureDownloader(t, transport)
	fanqieSeedDevice(d)
	_, _, err := d.fetchFanqieFeed(context.Background(), false)
	if err == nil {
		t.Fatal("预算截断应返回错误")
	}
	if planCalls != 1 {
		t.Fatalf("plan 请求 %d 次，want 1（预算截断）", planCalls)
	}
}
