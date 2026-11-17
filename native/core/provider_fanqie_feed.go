package core

// 番茄发现流路：plan 取种 → cell/change 合并（修仙版 fanqie_video_feed 的 Go 版）。
//
// 链路（与 Rust 实现逐项对应）：
//   1. 首屏：GET plan/v 取排行榜视频 cell（cell_id_str + session_id），再按 App
//      首页面形状打 cell/change（VideoFlow=2、LoadMore=2、ChangeFilter=2）；
//      change 回了视频就用 change，change 为空时回 plan 自带的首屏（data[0]
//      本身含 10 条真视频），不再出空白页。
//   2. 翻页：跳过 plan，直打 change（ChangeFilter 改 GetMore=1），offset 取上页
//      的 next_offset；游标存在 Feeds["fanqie"]（SessionID/LastID/Offset）。
//
// 恢复环（与刚落树的红果取流修复合流，不重复造轮子）：空回包/设备被拒时标记
// 受限、换设备身份重试，轮换间退避（hongguoAppMediaRotationBackoff），全程包
// 在总预算里（fanqieFeedBudget）；设备注册与渐进退避复用 ensureHongguoDevice。
// 单次请求走 hongguoSingleAttemptKey，不让 hongguoAppRequest 内部再重试——
// 重试策略只由本循环控制，避免同一设备上重复撞墙。

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// fanqiePlanPath / fanqieCellChangePath：发现流路的两条接口路径。
// 注意 cell/change 用 /v（无 v1、无尾斜杠），与旧槽书城的
// hongguoBookmallCellChangePath（/v1/）不同——活站探针实证 /v 通 code 0。
const fanqiePlanPath = "/reading/bookapi/plan/v"
const fanqieCellChangePath = "/reading/bookapi/bookmall/cell/change/v"

// fanqieFeedTabType：change 的 tab_type，Rust fanqie_video_feed 缺省值 "8"。
const fanqieFeedTabType = "8"

// fanqieFeedBudget：一次发现请求（plan + change 含轮换）的总预算；测试可覆盖。
var fanqieFeedBudget = 60 * time.Second

// fanqiePlanParams：Rust fanqie_plan_params 的 video 参数部分。身份袋由
// hongguoAppRequest 的凤凰袋提供，这里只叠加 video 参数。
//
// 关键（Rust 注释原样）：from 是必填项（无 from → 101116），且绝不能再加
// source（重加 source 即回 101116）。from=video_ranklist +
// bookstore_tab_type=26（ranklist_landpage）一次即回真视频 cell。
func fanqiePlanParams(sessionUUID string) url.Values {
	return url.Values{
		"scene":              {"10"},
		"from":               {"video_ranklist"},
		"bookstore_tab_type": {"26"},
		"selected_items":     {""},
		"sub_selected_items": {""},
		"session_uuid":       {sessionUUID},
		"stick_ids":          {""},
	}
}

// fanqieCellChangeParams：Rust cell_change_params 的 Go 版（参数逐项对应）。
// selectorChangeType：首屏 ChangeFilter="2"，翻页 GetMore="1"。
// selectedItems/subSelectedItems 取 plan 种子里 is_selected 的 all / ranklist_hot_sc。
func fanqieCellChangeParams(cellID, sessionID, tabType, offset, selectorChangeType string) url.Values {
	values := url.Values{
		"cell_id":                            {cellID},
		"last_search_query_from_rec":         {"false"},
		"ClickedContent":                     {""},
		"client_template":                    {"2"},
		"last_tab_index":                     {"0"},
		"screen_width_px":                    {"1281"},
		"classic_tab_style":                  {"v3"},
		"tab_type":                           {tabType},
		"first_use_category_select":          {"false"},
		"last_session_video_tab_type":        {"0"},
		"current_name":                       {""},
		"disable_digg_stat":                  {"false"},
		"ecom_refresh_type":                  {"0"},
		"pad_column_cover":                   {"0"},
		"last_tab_type":                      {"0"},
		"req_rank_category_id":               {"0"},
		"video_tab_cold_start":               {"0"},
		"offset":                             {offset},
		"selected_items":                     {"all"},
		"sub_selected_items":                 {"ranklist_hot_sc"},
		"video_type_preferences_str":         {"[]"},
		"auth_aweme":                         {"false"},
		"cold_start_is_double_gd":            {"false"},
		"page_entry_time":                    {"0"},
		"cold_start_session":                 {"1"},
		"tab_index":                          {"0"},
		"lore_tab_style":                     {"v5"},
		"device_level":                       {"3"},
		"unlimited_short_series_change_type": {"0"},
		"unlimited_selector_change_type":     {selectorChangeType},
		"book_id":                            {"0"},
		"ecom_impression_start_time":         {"0"},
		"enable_search_box_collapse":         {"false"},
		"landing_bottom_tab_type":            {"0"},
		"bottom_tab_type":                    {"0"},
		"top_tab_extra":                      {""},
		"migration_top_tab_enable":           {"false"},
		"auth_backward":                      {"true"},
		"pad_column_detail":                  {"0"},
		"after_genre_preference_popup":       {"0"},
		"client_req_type":                    {"2"},
		"req_rank_algo":                      {"101"},
		"unlimited_short_series_next_offset": {"0"},
		"normal_session_cnt_in_day":          {"6"},
		"cold_start_session_cnt_in_day":      {"2"},
		"sys_mini_window":                    {"1"},
		"app_mini_window":                    {"0"},
		"har_status":                         {"0"},
		"cold_start_session_cnt_in_life":     {"2"},
		"charging":                           {"0"},
		"normal_session_cnt_in_life":         {"6"},
		"is_power_save_mode":                 {"0"},
		"app_dark_mode":                      {"0"},
		"screen_brightness":                  {"36"},
		"battery_pct":                        {"10"},
		"down_speed":                         {"51430"},
		"sys_dark_mode":                      {"0"},
		"font_scale":                         {"100"},
		"network_type":                       {"4"},
		"current_volume":                     {"0"},
	}
	if sessionID != "" {
		values.Set("session_id", sessionID)
	}
	return values
}

// fanqieHasVideoItems：递归找任意一处非空 video_data 数组（plan / change
// 两种回包都适用）。Rust has_video_items 的 Go 版。
func fanqieHasVideoItems(value any) bool {
	return fanqieHasVideoItemsDepth(value, 0)
}

func fanqieHasVideoItemsDepth(value any, depth int) bool {
	if depth > 14 {
		return false
	}
	switch item := value.(type) {
	case []any:
		for _, child := range item {
			if fanqieHasVideoItemsDepth(child, depth+1) {
				return true
			}
		}
	case map[string]any:
		if videos := anyList(item["video_data"]); len(videos) > 0 {
			return true
		}
		for _, child := range item {
			if fanqieHasVideoItemsDepth(child, depth+1) {
				return true
			}
		}
	}
	return false
}

// fanqieCollectVideoRows：递归收集全部 video_data 行。遍历键序与修仙版 Dart
// parseMediaItems 一致（video_data 优先，再进 tab_item/cell_data/cell_view 等）。
func fanqieCollectVideoRows(value any, out *[]map[string]any) {
	fanqieCollectVideoRowsDepth(value, out, 0)
}

func fanqieCollectVideoRowsDepth(value any, out *[]map[string]any, depth int) {
	if depth > 14 {
		return
	}
	switch item := value.(type) {
	case []any:
		for _, child := range item {
			fanqieCollectVideoRowsDepth(child, out, depth+1)
		}
	case map[string]any:
		for _, row := range anyList(item["video_data"]) {
			if rowMap, ok := row.(map[string]any); ok {
				*out = append(*out, rowMap)
			}
		}
		for _, key := range []string{"tab_item", "cell_data", "cell_view", "book_data", "search_tabs", "data", "items", "lists", "item_data_list", "recommend_list"} {
			if child, ok := item[key]; ok {
				fanqieCollectVideoRowsDepth(child, out, depth+1)
			}
		}
	}
}

// fanqieDramaFromRow：video_data 行 → 番茄槽 Drama。短剧模板卡把标题/封面/
// 简介放在更深一层的 video_detail（series_title/series_cover/series_intro），
// 扁平卡直接放在行上——与 Dart parseMediaItems 同款，先把 detail 提上来再映射。
// 行里没有数字 series_id 时返回空 Drama（详情要 series_id，无之不可播）。
func fanqieDramaFromRow(row map[string]any) Drama {
	merged := make(map[string]any, len(row)+4)
	if detail, ok := row["video_detail"].(map[string]any); ok {
		for key, value := range detail {
			merged[key] = value
		}
	}
	for key, value := range row {
		merged[key] = value
	}
	drama := hongguoDramaFromAny(merged, "短剧")
	if drama.SourceID == "" {
		return Drama{}
	}
	return fanqieRelabelDrama(drama)
}

// fanqieDramasFromPayload：回包 → 番茄槽剧集列表（收集 + 映射 + 去重）。
func fanqieDramasFromPayload(payload map[string]any) []Drama {
	var rows []map[string]any
	fanqieCollectVideoRows(payload["data"], &rows)
	dramas := make([]Drama, 0, len(rows))
	for _, row := range rows {
		if drama := fanqieDramaFromRow(row); drama.ID != "" {
			dramas = append(dramas, drama)
		}
	}
	return fanqieDedupDramas(dramas)
}

// fanqieFeedRequest：带恢复环的单次发现请求。空回包/设备被拒时标记受限、
// 换设备身份重试（有界 hongguoDeviceRotations 轮），轮换间退避；其它错误
// 直接返回。成功时清除受限标记。
func (downloader *Downloader) fanqieFeedRequest(ctx context.Context, path string, extra url.Values) (map[string]any, error) {
	budgetCtx, cancel := context.WithTimeout(ctx, fanqieFeedBudget)
	defer cancel()
	ctx = budgetCtx
	if err := downloader.ensureHongguoDevice(ctx, ""); err != nil {
		return nil, err
	}
	singleCtx := context.WithValue(ctx, hongguoSingleAttemptKey{}, true)
	var lastErr error
	for attempt := 0; attempt <= hongguoDeviceRotations; attempt++ {
		if attempt > 0 {
			if err := hongguoSleepContext(ctx, hongguoAppMediaRotationBackoff(attempt)); err != nil {
				return nil, err
			}
			if err := downloader.ensureHongguoDevice(ctx, downloader.hongguoDeviceID()); err != nil {
				return nil, err
			}
		}
		result, err := downloader.hongguoAppRequestInternal(singleCtx, http.MethodGet, path, extra, nil, true)
		if err == nil {
			downloader.clearHongguoDeviceLimited()
			return result, nil
		}
		if errors.Is(err, errHongguoAppEmptyBody) || errors.Is(err, errHongguoDeviceRejected) {
			downloader.markHongguoDeviceLimited()
			lastErr = err
			continue
		}
		return nil, err
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errHongguoAppEmptyBody
}

// fanqiePlanSeed：打 plan/v 取排行榜视频 cell。返回首个 cell、cell_id_str、
// session_id；三者缺一即报错（Rust fanqie_video_feed 同款门禁）。
func (downloader *Downloader) fanqiePlanSeed(ctx context.Context) (map[string]any, string, string, error) {
	result, err := downloader.fanqieFeedRequest(ctx, fanqiePlanPath, fanqiePlanParams(uuidLike()))
	if err != nil {
		return nil, "", "", err
	}
	rows := anyList(result["data"])
	if len(rows) == 0 {
		return nil, "", "", errors.New("番茄 plan 未回视频 cell")
	}
	first, _ := rows[0].(map[string]any)
	if first == nil {
		return nil, "", "", errors.New("番茄 plan 未回视频 cell")
	}
	cellID := mapString(first, "cell_id_str")
	sessionID := mapString(first, "session_id")
	if cellID == "" || sessionID == "" {
		return nil, "", "", errors.New("番茄 plan 的视频 cell 缺 cell_id/session_id")
	}
	return first, cellID, sessionID, nil
}

// fanqieChange：打 cell/change/v。firstPage 为真用 ChangeFilter=2（首屏），
// 否则 GetMore=1（翻页）。返回原始回包，由调用方判断有无视频。
func (downloader *Downloader) fanqieChange(ctx context.Context, cellID, sessionID string, offset int, firstPage bool) (map[string]any, error) {
	selector := "1"
	if firstPage {
		selector = "2"
	}
	return downloader.fanqieFeedRequest(ctx, fanqieCellChangePath, fanqieCellChangeParams(cellID, sessionID, fanqieFeedTabType, strconv.Itoa(offset), selector))
}

// fanqieChangeCursor：从 change 回包的 data 里取下一页游标（next_offset /
// session_id / has_more）。next_offset 缺失或不进位时返回 -1，调用方按耗尽处理。
func fanqieChangeCursor(result map[string]any, offset int) (nextOffset int, sessionID string, hasMore bool) {
	data := nestedMap(result, "data")
	nextOffset = -1
	if raw := mapString(data, "next_offset"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > offset {
			nextOffset = parsed
		}
	}
	sessionID = mapString(data, "session_id")
	switch flag := data["has_more"].(type) {
	case bool:
		hasMore = flag
	case string:
		hasMore = strings.EqualFold(strings.TrimSpace(flag), "true")
	}
	return nextOffset, sessionID, hasMore
}

// fanqieReadCursor / fanqieWriteCursor：Feeds["fanqie"] 游标的读写。
// 调用方须已持 catalogMu（与旧槽 fetchHongguoAppCatalogCategory 同款）；
// 读写 state 本身另持 client.mu。
func (downloader *Downloader) fanqieReadCursor() hongguoCatalogCursor {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.state.Feeds[fanqieFeedKey]
}

func (downloader *Downloader) fanqieWriteCursor(cursor hongguoCatalogCursor) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.state.Feeds == nil {
		client.state.Feeds = map[string]hongguoCatalogCursor{}
	}
	client.state.Feeds[fanqieFeedKey] = cursor
}

// fetchFanqieFeed：番茄流合并入口（Rust fanqie_video_feed 的 Go 版）。
// more 为假（第 1 页）：plan 取种 → change 首屏；change 无视频时回 plan 首屏。
// more 为真（翻页）：游标续 change；游标未初始化时退化成首屏链路。
// 返回（剧集，有无下一页，错误）。全程持 catalogMu，与旧槽目录互斥、游标不竞写。
func (downloader *Downloader) fetchFanqieFeed(ctx context.Context, more bool) ([]Drama, bool, error) {
	client := downloader.hongguoClient()
	client.catalogMu.Lock()
	defer client.catalogMu.Unlock()

	cursor := downloader.fanqieReadCursor()
	if !more || !cursor.Initialized {
		return downloader.fetchFanqieFeedFirst(ctx)
	}
	result, err := downloader.fanqieChange(ctx, cursor.LastID, cursor.SessionID, cursor.Offset, false)
	if err != nil {
		return nil, false, err
	}
	if !fanqieHasVideoItems(result) {
		// 翻页 change 回空：按流耗尽处理（下一页不再请求），下拉刷新重取种子。
		cursor.Exhausted = true
		downloader.fanqieWriteCursor(cursor)
		return nil, false, nil
	}
	items := fanqieDramasFromPayload(result)
	nextOffset, sessionID, hasMore := fanqieChangeCursor(result, cursor.Offset)
	if nextOffset < 0 {
		cursor.Exhausted = true
		downloader.fanqieWriteCursor(cursor)
		return items, false, nil
	}
	if sessionID != "" {
		cursor.SessionID = sessionID
	}
	cursor.Offset = nextOffset
	cursor.Exhausted = !hasMore
	downloader.fanqieWriteCursor(cursor)
	return items, hasMore, nil
}

// fetchFanqieFeedFirst：首屏链路。change 有视频用 change，否则回 plan 首屏
// （data[0] 本身含真视频）；游标按实际采用的回包写。
func (downloader *Downloader) fetchFanqieFeedFirst(ctx context.Context) ([]Drama, bool, error) {
	first, cellID, sessionID, err := downloader.fanqiePlanSeed(ctx)
	if err != nil {
		return nil, false, err
	}
	result, err := downloader.fanqieChange(ctx, cellID, sessionID, 0, true)
	if err != nil {
		return nil, false, err
	}
	if fanqieHasVideoItems(result) {
		items := fanqieDramasFromPayload(result)
		nextOffset, changeSession, hasMore := fanqieChangeCursor(result, 0)
		if changeSession != "" {
			sessionID = changeSession
		}
		if nextOffset < 0 {
			nextOffset = 0
			hasMore = false
		}
		downloader.fanqieWriteCursor(hongguoCatalogCursor{
			Offset: nextOffset, SessionID: sessionID, LastID: cellID,
			Initialized: true, Exhausted: !hasMore, UpdatedAt: time.Now(),
		})
		return items, hasMore, nil
	}
	// change 为空：回 plan 自带的首屏（Rust 同款回落），游标取 plan 的 next_offset。
	items := fanqieDramasFromPayload(map[string]any{"data": first})
	nextOffset := 0
	hasMore := false
	if raw := mapString(first, "next_offset"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			nextOffset = parsed
		}
	}
	if flag, ok := first["has_more"].(bool); ok {
		hasMore = flag
	}
	if nextOffset <= 0 {
		hasMore = false
	}
	downloader.fanqieWriteCursor(hongguoCatalogCursor{
		Offset: nextOffset, SessionID: sessionID, LastID: cellID,
		Initialized: true, Exhausted: !hasMore, UpdatedAt: time.Now(),
	})
	return items, hasMore, nil
}
