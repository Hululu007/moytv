package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

func hongguoDecodeJSONMap(text string) (map[string]any, error) {
	var out map[string]any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if err := decoder.Decode(&out); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, errors.New("JSON 为空")
	}
	return out, nil
}

func hongguoDecodeJSONArray(text string) ([]any, error) {
	var out []any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if err := decoder.Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// 红果账号接口客户端（Go 核一半，供 Dart 登录组接线；Dart 侧只改 lib/*.dart）。
// 端点与作用见 ~/workspace/moyi_haikuo/hongguo_inventory.md 第二组；只借结构，
// 设备参数（aid 8662 / 版本 74332 / 7.4.3.32）用魔蚁自己的。
// 未登录时账号接口直接报“未登录”，不发请求；写接口（收藏/预约/进度）不自动重试，
// 调用方按对照仓口径回读确认。

var errHongguoAccountNotLoggedIn = errors.New("红果账号未登录，请先登录")

// hongguoSingleAttemptKey：ctx 标记——写接口单次尝试，不自动重试。
type hongguoSingleAttemptKey struct{}

type hongguoAccountFavorite struct {
	SeriesID string `json:"seriesId"`
	Title    string `json:"title"`
	Cover    string `json:"cover"`
	Badge    string `json:"badge"`
}

type hongguoAccountHistoryItem struct {
	SeriesID     string `json:"seriesId"`
	Title        string `json:"title"`
	Cover        string `json:"cover"`
	EpisodeID    string `json:"episodeId"`
	EpisodeIndex int    `json:"episodeIndex"`
	PositionMS   int64  `json:"positionMs"`
	DurationMS   int64  `json:"durationMs"`
	UpdatedAtMS  int64  `json:"updatedAtMs"`
	EpisodeCount int    `json:"episodeCount"`
}

type hongguoAccountReservation struct {
	SeriesID string `json:"seriesId"`
	Title    string `json:"title"`
	Cover    string `json:"cover"`
	Online   bool   `json:"online"`
	Badge    string `json:"badge"`
}

type hongguoAccountRelated struct {
	SeriesID    string `json:"seriesId"`
	Title       string `json:"title"`
	Cover       string `json:"cover"`
	Description string `json:"description"`
	Badge       string `json:"badge"`
	Season      string `json:"season"`
	SeasonIndex int    `json:"seasonIndex"`
	Upcoming    bool   `json:"upcoming"`
}

type hongguoAccountFilterItem struct {
	SeriesID string `json:"seriesId"`
	Title    string `json:"title"`
	Cover    string `json:"cover"`
	Desc     string `json:"desc"`
	Badge    string `json:"badge"`
	Tags     string `json:"tags"`
}

type hongguoAccountFilterGroup struct {
	Type    string `json:"type"`
	Label   string `json:"label"`
	Options []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"options"`
}

type hongguoCloudProgress struct {
	SeriesID     string
	EpisodeID    string
	EpisodeIndex int
	PositionMS   int64
	DurationMS   int64
	UpdatedAtMS  int64
	EpisodeCount int
}

// hongguoAccountRequestError：账号接口错误收紧（修仙版 _guard/_checkStatus
// 同款口径，只收账号层这一层）：超时→请求超时、断网→网络连接失败、
// 非 200→账号接口返回 HTTP X；空响应/格式异常沿用内层文案。
func hongguoAccountRequestError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return errors.New("请求超时")
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		if netErr.Timeout() {
			return errors.New("请求超时")
		}
		return errors.New("网络连接失败")
	}
	if message := err.Error(); strings.HasPrefix(message, "红果 App 接口 HTTP ") {
		return errors.New("账号接口返回 HTTP " + strings.TrimPrefix(message, "红果 App 接口 HTTP "))
	}
	return err
}

// hongguoAccountRequest：账号接口请求总入口。未登录直接报错；走账号域名，
// 用账号设备号签名、用账号 Cookie 发请求。
func (downloader *Downloader) hongguoAccountRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return downloader.hongguoAccountRequestGzip(ctx, method, path, extra, payload, false)
}

func (downloader *Downloader) hongguoAccountRequestGzip(ctx context.Context, method, path string, extra url.Values, payload any, gzipBody bool) (map[string]any, error) {
	session := downloader.hongguoAccountSessionSnapshot()
	if !session.loggedIn() {
		return nil, errHongguoAccountNotLoggedIn
	}
	ctx = context.WithValue(ctx, hongguoAccountOverrideKey{}, session)
	ctx = context.WithValue(ctx, hongguoBaseURLOverrideKey{}, hongguoAccountAppBaseURL)
	result, err := downloader.hongguoAppRequestInternalOpts(ctx, method, path, extra, payload, false, gzipBody)
	return result, hongguoAccountRequestError(err)
}

// hongguoAccountRequestSingle：写接口单次尝试（不自动重试）。
func (downloader *Downloader) hongguoAccountRequestSingle(ctx context.Context, method, path string, extra url.Values, payload any, gzipBody bool) (map[string]any, error) {
	session := downloader.hongguoAccountSessionSnapshot()
	if !session.loggedIn() {
		return nil, errHongguoAccountNotLoggedIn
	}
	ctx = context.WithValue(ctx, hongguoAccountOverrideKey{}, session)
	ctx = context.WithValue(ctx, hongguoBaseURLOverrideKey{}, hongguoAccountAppBaseURL)
	ctx = context.WithValue(ctx, hongguoSingleAttemptKey{}, true)
	result, err := downloader.hongguoAppRequestInternalOpts(ctx, method, path, extra, payload, false, gzipBody)
	return result, hongguoAccountRequestError(err)
}

func hongguoEpisodeBadge(row map[string]any) string {
	for _, key := range []string{"episode_cnt", "episode_count", "drama_chapter_number"} {
		if count := hongguoAnyInt(row[key]); count > 0 {
			return fmt.Sprintf("全 %d 集", count)
		}
	}
	return ""
}

// hongguoAccountFavorites：读账号视频收藏。
func (downloader *Downloader) hongguoAccountFavorites(ctx context.Context) ([]hongguoAccountFavorite, error) {
	result, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/bookapi/bookshelf/video/info/v1/", nil, nil)
	if err != nil {
		return nil, err
	}
	return parseHongguoAccountFavorites(result)
}

func parseHongguoAccountFavorites(result map[string]any) ([]hongguoAccountFavorite, error) {
	data := nestedMap(result, "data")
	rows := anyList(data["video_shelf_info"])
	if len(rows) == 0 {
		if _, has := data["video_shelf_info"]; !has {
			return nil, errors.New("账户收藏列表格式已变化")
		}
		return []hongguoAccountFavorite{}, nil
	}
	out := make([]hongguoAccountFavorite, 0, len(rows))
	for _, row := range rows {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		video := nestedMap(item, "video_data")
		if len(video) == 0 {
			video = item
		}
		id := firstNonEmpty(mapString(video, "series_id"), mapString(item, "series_id"), mapString(item, "book_id"))
		title := firstNonEmpty(mapString(item, "series_title"), mapString(video, "title"), mapString(item, "book_name"))
		if !hongguoNumericID.MatchString(id) || title == "" {
			continue
		}
		cover := firstNonEmpty(mapString(item, "series_cover_url"), mapString(video, "cover"), mapString(video, "cover_url"), mapString(video, "thumb_url"), mapString(item, "thumb_url"))
		out = append(out, hongguoAccountFavorite{SeriesID: id, Title: title, Cover: cover, Badge: hongguoEpisodeBadge(video)})
	}
	return out, nil
}

// hongguoAccountSetFavorite：写账号收藏，写后回读确认（不自动重试）。
func (downloader *Downloader) hongguoAccountSetFavorite(ctx context.Context, seriesID string, add bool) ([]hongguoAccountFavorite, error) {
	if !hongguoNumericID.MatchString(seriesID) {
		return nil, errors.New("红果剧集 ID 无效")
	}
	entry := map[string]any{
		"book_id":                  seriesID,
		"book_type":                2,
		"modify_time":              time.Now().UnixMilli(),
		"video_shelf_operate_type": 0,
	}
	if !add {
		entry["video_shelf_operate_type"] = 1
		entry["group_name"] = ""
	}
	body := map[string]any{
		"is_cancelled":                false,
		"update_bookshelf_video_list": []any{entry},
	}
	if add {
		body["shark_extra"] = map[string]any{
			"enter_from":         "MainFragmentActivity",
			"previous_page":      "",
			"page_list":          "MainFragmentActivity",
			"is_active_behavior": "true",
			"inactive_type":      "0",
		}
	}
	if _, err := downloader.hongguoAccountRequestSingle(ctx, http.MethodPost, "/reading/bookapi/bookshelf/video/update/v1/", nil, body, false); err != nil {
		return nil, err
	}
	return downloader.hongguoAccountFavorites(ctx)
}

// hongguoAccountHistory：读云端历史（最近 50 条），再批量补剧集资料。
func (downloader *Downloader) hongguoAccountHistory(ctx context.Context) ([]hongguoAccountHistoryItem, error) {
	result, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/bookapi/read_progress/list/v1/", url.Values{"book_types": {"2"}, "limit": {"50"}}, nil)
	if err != nil {
		return nil, err
	}
	data := nestedMap(result, "data")
	rows := anyList(data["video_data"])
	if len(rows) == 0 {
		if inner := nestedMap(result, "data", "data"); len(inner) > 0 {
			rows = anyList(inner["video_data"])
		}
	}
	items := parseHongguoAccountHistory(rows)
	if len(items) == 0 {
		return items, nil
	}
	ids := make([]string, 0, len(items))
	seen := map[string]bool{}
	for _, item := range items {
		if !seen[item.SeriesID] {
			seen[item.SeriesID] = true
			ids = append(ids, item.SeriesID)
		}
	}
	// 补资料失败不遮挡列表。
	if detail, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/bookapi/multi-detail/v1/", url.Values{"book_id": {strings.Join(ids, ",")}, "book_type": {"2"}}, nil); err == nil {
		meta := map[string]map[string]any{}
		for _, row := range anyList(detail["data"]) {
			item, _ := row.(map[string]any)
			if item == nil {
				continue
			}
			if id := mapString(item, "book_id"); id != "" {
				meta[id] = item
			}
		}
		for i, item := range items {
			if row, ok := meta[item.SeriesID]; ok {
				if title := mapString(row, "book_name"); title != "" {
					items[i].Title = title
				}
				if cover := mapString(row, "thumb_url"); cover != "" {
					items[i].Cover = cover
				}
				if count := hongguoAnyInt(row["episode_cnt"]); count > 0 {
					items[i].EpisodeCount = int(count)
				} else if count := hongguoAnyInt(row["episode_count"]); count > 0 {
					items[i].EpisodeCount = int(count)
				}
			}
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].UpdatedAtMS > items[j].UpdatedAtMS })
	return items, nil
}

func parseHongguoAccountHistory(rows []any) []hongguoAccountHistoryItem {
	seen := map[string]bool{}
	out := make([]hongguoAccountHistoryItem, 0, len(rows))
	for _, row := range rows {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		id := firstNonEmpty(mapString(item, "series_id"), mapString(item, "book_id"))
		episode := mapString(item, "vid")
		if !hongguoNumericID.MatchString(id) || !hongguoNumericID.MatchString(episode) {
			continue
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		stamp := hongguoAnyInt(item["last_watch_time"])
		if stamp > 0 && stamp <= 9999999999 {
			stamp *= 1000
		}
		index := int(hongguoAnyInt(item["vid_index"])) - 1
		if index < 0 {
			index = 0
		}
		out = append(out, hongguoAccountHistoryItem{
			SeriesID:     id,
			EpisodeID:    episode,
			EpisodeIndex: index,
			PositionMS:   hongguoAnyInt(item["current_play_time"]) * 1000,
			DurationMS:   hongguoAnyInt(item["current_total_time"]) * 1000,
			UpdatedAtMS:  stamp,
			EpisodeCount: int(hongguoAnyInt(item["episode_count"])),
		})
	}
	return out
}

// hongguoAccountUploadProgress：单次上传一条云端进度（桥接单位是毫秒，接口单位是秒，
// 这里换算；队列化由 Dart 侧做）。
func (downloader *Downloader) hongguoAccountUploadProgress(ctx context.Context, progress hongguoCloudProgress) error {
	if !hongguoNumericID.MatchString(progress.SeriesID) || !hongguoNumericID.MatchString(progress.EpisodeID) {
		return errors.New("红果剧集或分集 ID 无效")
	}
	position := progress.PositionMS / 1000
	if position < 0 {
		position = 0
	}
	duration := progress.DurationMS / 1000
	if duration < 0 {
		duration = 0
	}
	rate := "0"
	if duration > 0 {
		value := float64(position) / float64(duration)
		if value < 0 {
			value = 0
		}
		if value > 1 {
			value = 1
		}
		rate = strconv.FormatFloat(value, 'f', -1, 64)
	}
	entry := map[string]any{
		"book_id":                          progress.SeriesID,
		"item_id":                          progress.EpisodeID,
		"vid_index":                        progress.EpisodeIndex + 1,
		"current_play_time":                position,
		"current_total_time":               duration,
		"episode_count":                    progress.EpisodeCount,
		"read_timestamp_ms":                progress.UpdatedAtMS,
		"book_type":                        2,
		"progress_rate":                    rate,
		"player_cumulative_total_duration": position,
	}
	body := map[string]any{"books": []any{entry}, "write_mode": 1}
	_, err := downloader.hongguoAccountRequestSingle(ctx, http.MethodPost, "/reading/bookapi/read_progress/upload/v1/", nil, body, false)
	return err
}

// hongguoAccountReservations：读账号预约列表（online 已上线/待上线各最近 20 部）。
func (downloader *Downloader) hongguoAccountReservations(ctx context.Context, online bool) ([]hongguoAccountReservation, error) {
	extra := url.Values{
		"offset": {"0"}, "limit": {"20"}, "is_online": {strconv.FormatBool(online)},
		"tab_type": {"13"}, "subscribe_order_type": {"0"}, "swipe_type": {"0"},
		"need_calendar_schema": {"false"}, "subscribe_offset": {"0"},
	}
	result, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/user/subscribe/list/v0/", extra, nil)
	if err != nil {
		return nil, err
	}
	rows, err := parseHongguoAccountReservations(result, online)
	if err != nil {
		return nil, err
	}
	if !online {
		return rows, nil
	}
	// 已上线缺集数时批量补一次，失败不遮挡列表。
	var missing []string
	for _, row := range rows {
		if row.Badge == "" {
			missing = append(missing, row.SeriesID)
		}
	}
	if len(missing) == 0 {
		return rows, nil
	}
	if detail, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/bookapi/multi-detail/v1/", url.Values{"book_id": {strings.Join(missing, ",")}, "book_type": {"2"}}, nil); err == nil {
		badges := map[string]string{}
		for _, row := range anyList(detail["data"]) {
			item, _ := row.(map[string]any)
			if item == nil {
				continue
			}
			if id := mapString(item, "book_id"); id != "" {
				if badge := hongguoEpisodeBadge(item); badge != "" {
					badges[id] = badge
				}
			}
		}
		for i, row := range rows {
			if badge, ok := badges[row.SeriesID]; ok {
				rows[i].Badge = badge
			}
		}
	}
	return rows, nil
}

func parseHongguoAccountReservations(result map[string]any, online bool) ([]hongguoAccountReservation, error) {
	data := nestedMap(result, "data")
	if _, has := data["subscribe_items"]; !has {
		return nil, errors.New("预约列表格式已变化，请稍后重试")
	}
	rows := anyList(data["subscribe_items"])
	out := make([]hongguoAccountReservation, 0, len(rows))
	for _, row := range rows {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		video := nestedMap(item, "subscribe_data")
		if len(video) == 0 {
			video = nestedMap(item, "video_data")
		}
		if len(video) == 0 {
			video = item
		}
		seriesID := firstNonEmpty(mapString(video, "series_id"), mapString(item, "series_id"), mapString(item, "book_id"))
		title := firstNonEmpty(mapString(video, "series_title"), mapString(video, "title"), mapString(item, "book_name"))
		cover := firstNonEmpty(mapString(video, "series_cover_url"), mapString(video, "cover"), mapString(video, "cover_url"), mapString(video, "thumb_url"), mapString(item, "thumb_url"))
		id := seriesID
		if !hongguoNumericID.MatchString(seriesID) {
			// 未上线项用 reservation:{item_id} 做命名空间键，防止被误当成可播剧集 ID。
			if raw := mapString(item, "item_id"); raw != "" {
				id = "reservation:" + raw
			} else {
				continue
			}
		}
		if title == "" {
			title = id
		}
		out = append(out, hongguoAccountReservation{SeriesID: id, Title: title, Cover: cover, Online: online, Badge: hongguoEpisodeBadge(video)})
	}
	return out, nil
}

// hongguoAccountReserve：相关季预约写（仅对待上线季调用；code=0 只表示写操作被确认，
// 以账号预约列表读回为准）。请求体先 gzip 再签名。
func (downloader *Downloader) hongguoAccountReserve(ctx context.Context, seriesID string) error {
	if !hongguoNumericID.MatchString(seriesID) {
		return errors.New("红果剧集 ID 无效")
	}
	id, err := strconv.ParseInt(seriesID, 10, 64)
	if err != nil {
		return errors.New("预约编号无效")
	}
	body := map[string]any{"item_id": id, "item_type": 3, "op_type": 1, "subscribe_source": 0}
	_, err = downloader.hongguoAccountRequestSingle(ctx, http.MethodPost, "/reading/bookapi/search/uncover_subscribe/v1/", nil, body, true)
	return err
}

var hongguoPlanHosts = []string{
	"api5-normal-sinfonlinec.fqnovel.com",
	"api5-normal-hl.fqnovel.com",
	"api5-normal-lf.fqnovel.com",
}

// hongguoAccountRelated：相关作品（相关季信息，供下一季计算）；三域名依次试。
func (downloader *Downloader) hongguoAccountRelated(ctx context.Context, seriesID string) ([]hongguoAccountRelated, error) {
	if !hongguoNumericID.MatchString(seriesID) {
		return nil, errors.New("红果剧集 ID 无效")
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	deviceID, installID := client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	extra := hongguoAppQuery(deviceID, installID)
	extra.Set("scene", "10")
	extra.Set("from", "detail_page_more_related")
	extra.Set("book_id", seriesID)
	extra.Set("new_search_middle_page", "false")
	extra.Set("bookstore_tab_type", "0")
	extra.Set("query_history_removed", "false")
	extra.Set("user_is_login", "0")
	extra.Set("bookstore_tab", "0")
	extra.Set("search_middle_page_version", "0")
	extra.Set("pad_column_detail", "0")
	extra.Set("hot_word_exchange", "false")
	extra.Set("device_level", "3")
	extra.Set("limit", "0")
	extra.Set("offset", "0")
	extra.Set("is_horizontal_screen", "false")
	extra.Set("reader_single_col_from_ip_strategy", "false")
	var lastErr error
	for _, host := range hongguoPlanHosts {
		hostCtx := context.WithValue(ctx, hongguoBaseURLOverrideKey{}, "https://"+host)
		result, err := downloader.hongguoAppRequest(hostCtx, http.MethodGet, "/reading/bookapi/plan/v:version/", extra, nil)
		if err != nil {
			lastErr = err
			continue
		}
		return parseHongguoAccountRelated(result, seriesID), nil
	}
	if lastErr != nil {
		return nil, fmt.Errorf("相关作品暂时无法加载，请重试: %w", lastErr)
	}
	return nil, errors.New("相关作品暂时无法加载，请重试")
}

func parseHongguoAccountRelated(result map[string]any, currentID string) []hongguoAccountRelated {
	out := make([]hongguoAccountRelated, 0)
	seen := map[string]bool{}
	for _, cell := range anyList(result["data"]) {
		item, _ := cell.(map[string]any)
		if item == nil {
			continue
		}
		if hongguoAnyInt(item["show_type"]) != 547 && mapString(item, "cell_name") != "相关作品" {
			continue
		}
		for _, row := range anyList(item["video_data"]) {
			video, _ := row.(map[string]any)
			if video == nil {
				continue
			}
			id := mapString(video, "series_id")
			title := mapString(video, "title")
			contentType := int(hongguoAnyInt(video["content_type"]))
			if id == currentID || !hongguoNumericID.MatchString(id) || title == "" || (contentType != 1004 && contentType != 1007) {
				continue
			}
			upcoming := contentType == 1007
			if !upcoming && (video["disable_play"] == true || hongguoAnyInt(video["episode_cnt"]) <= 0) {
				continue
			}
			if seen[id] {
				continue
			}
			seen[id] = true
			season := mapString(nestedMap(video, "tag_info"), "text")
			seasonIndex := int(hongguoAnyInt(video["season_index"]))
			if season == "" && seasonIndex > 0 {
				season = fmt.Sprintf("第%d季", seasonIndex)
			}
			badge := "待上线"
			if !upcoming {
				badge = fmt.Sprintf("全 %d 集", hongguoAnyInt(video["episode_cnt"]))
			}
			out = append(out, hongguoAccountRelated{
				SeriesID:    id,
				Title:       title,
				Cover:       mapString(video, "cover"),
				Description: mapString(video, "video_desc"),
				Badge:       badge,
				Season:      season,
				SeasonIndex: seasonIndex,
				Upcoming:    upcoming,
			})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		left, right := out[i].SeasonIndex, out[j].SeasonIndex
		if left <= 0 {
			left = 1 << 30
		}
		if right <= 0 {
			right = 1 << 30
		}
		return left < right
	})
	return out
}

// hongguoAccountFilter：服务端多维筛选。bodyJSON 为筛选请求体
// （offset/limit/select_items/session_id/req_scene 等，由 Dart 分类筛选页拼）；
// cursorJSON 为游标 {"offset":N,"session":"..."}，为空表示首页。
// 返回条目、首屏筛选组、是否有更多、下一页游标。
func (downloader *Downloader) hongguoAccountFilter(ctx context.Context, bodyJSON, cursorJSON string) (map[string]any, error) {
	payload, err := hongguoDecodeJSONMap(bodyJSON)
	if err != nil {
		return nil, errors.New("筛选请求体无效")
	}
	cursorOffset := 0
	cursorSession := ""
	if strings.TrimSpace(cursorJSON) != "" {
		if cursor, err := hongguoDecodeJSONMap(cursorJSON); err == nil {
			cursorOffset = int(hongguoAnyInt(cursor["offset"]))
			cursorSession = mapString(cursor, "session")
			if cursorOffset > 0 {
				payload["offset"] = cursorOffset
				payload["session_id"] = cursorSession
				payload["req_type"] = "only_content"
			}
		}
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, "/reading/distribution/category/landpage/v/", nil, payload)
	if err != nil {
		return nil, err
	}
	data := nestedMap(result, "data")
	rows := anyList(data["video_data"])
	if len(rows) == 0 {
		return nil, errors.New("分类剧集列表缺失")
	}
	items := make([]hongguoAccountFilterItem, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		video, _ := row.(map[string]any)
		if video == nil {
			continue
		}
		id := mapString(video, "series_id")
		title := mapString(video, "title")
		if !hongguoNumericID.MatchString(id) || title == "" || seen[id] {
			continue
		}
		seen[id] = true
		tags := ""
		if schema := mapString(video, "category_schema"); schema != "" {
			if decoded, err := hongguoDecodeJSONArray(schema); err == nil {
				names := make([]string, 0, 8)
				for _, entry := range decoded {
					if item, ok := entry.(map[string]any); ok {
						if name := mapString(item, "name"); name != "" && len(names) < 8 {
							names = append(names, name)
						}
					}
				}
				tags = strings.Join(names, " · ")
			}
		}
		badge := ""
		if count := hongguoAnyInt(video["episode_cnt"]); count > 0 {
			badge = fmt.Sprintf("共 %d 集", count)
		}
		items = append(items, hongguoAccountFilterItem{
			SeriesID: id, Title: title, Cover: mapString(video, "cover"),
			Desc: mapString(video, "video_desc"), Badge: badge, Tags: tags,
		})
	}
	if len(items) == 0 {
		return nil, errors.New("分类剧集格式异常")
	}
	groups := []hongguoAccountFilterGroup{}
	if cursorOffset == 0 {
		labels := map[string]string{
			"genre": "类型", "category_dim_theme": "主题", "category_dim_role": "设定",
			"category_dim_epoch": "背景", "sort": "推荐", "gender": "受众",
			"online_time": "时间", "creation_status": "状态",
		}
		for _, row := range anyList(data["selector_rows"]) {
			group, _ := row.(map[string]any)
			if group == nil {
				continue
			}
			kind := mapString(group, "type")
			label, ok := labels[kind]
			if !ok {
				continue
			}
			entry := hongguoAccountFilterGroup{Type: kind, Label: label}
			for _, option := range anyList(group["items"]) {
				opt, _ := option.(map[string]any)
				if opt == nil {
					continue
				}
				id := mapString(opt, "selector_item_id")
				name := mapString(opt, "show_name")
				if id == "" || name == "" || len(name) > 40 || len(entry.Options) >= 128 {
					continue
				}
				entry.Options = append(entry.Options, struct {
					ID   string `json:"id"`
					Name string `json:"name"`
				}{ID: id, Name: name})
			}
			groups = append(groups, entry)
		}
	}
	hasMore := false
	if value, ok := data["has_more"].(bool); ok && value {
		hasMore = true
	}
	nextCursor := map[string]any{"offset": 0, "session": ""}
	if hasMore {
		nextOffset := int(hongguoAnyInt(data["offset"]))
		if nextOffset <= cursorOffset {
			nextOffset = cursorOffset + 24
		}
		nextSession := firstNonEmpty(mapString(data, "session_id"), mapString(data, "session"), cursorSession)
		nextCursor = map[string]any{"offset": nextOffset, "session": nextSession}
	}
	return map[string]any{
		"items": items, "groups": groups, "hasMore": hasMore, "nextCursor": nextCursor,
	}, nil
}

const hongguoLoginRewardInfoPath = "/luckycat/novel/v1/task/getLoginRewardInfo"
const hongguoLoginRewardDonePath = "/luckycat/novel/v1/task/done/login_reward"

func (downloader *Downloader) hongguoAccountLuckycatCall(ctx context.Context, deviceID, installID, cookie, path string, params map[string]string, body []byte) (map[string]any, error) {
	versionCode, versionName := "72232", "7.2.2.32"
	if body != nil {
		versionCode, versionName = "73932", "7.3.9.32"
	}
	call := func(playerOnly bool) (map[string]any, error) {
		query := hongguoAccountQuery(deviceID, installID, versionCode, versionName, true)
		for key, value := range params {
			if value != "" {
				query.Set(key, value)
			}
		}
		method := http.MethodGet
		if body != nil {
			method = http.MethodPost
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(hongguoAccountAppBaseURL, "/")+path+"?"+query.Encode(), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		request.Header.Set("Accept", "application/json")
		if cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
		if body != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		opts := hongguoSignOptions{Identity: hongguoSignerIdentity{DeviceID: deviceID, InstallID: installID}}
		if playerOnly {
			opts.PlayerOnly = true
		}
		hongguoSignRequest(request, body, time.Now(), opts)
		response, err := downloader.doPreparedCatalogRequest(request, hongguoAccountRequestTimeout, nil)
		if err != nil {
			return nil, err
		}
		return hongguoAccountReadJSON(response)
	}
	result, err := call(false)
	if errors.Is(err, errHongguoAccountEmptyBody) {
		return call(true)
	}
	return result, err
}

func (downloader *Downloader) hongguoAccountLuckycat(ctx context.Context, path string, params map[string]string, body []byte) (map[string]any, error) {
	session := downloader.hongguoAccountSessionSnapshot()
	if !session.loggedIn() {
		return nil, errHongguoAccountNotLoggedIn
	}
	deviceID, installID := session.DeviceID, session.InstallID
	if deviceID == "" || installID == "" {
		var err error
		deviceID, installID, err = downloader.hongguoAccountDevice(ctx)
		if err != nil {
			return nil, err
		}
	}
	return downloader.hongguoAccountLuckycatCall(ctx, deviceID, installID, session.Cookie, path, params, body)
}

func hongguoLoginRewardExtra(nodeIndex int) (string, error) {
	raw, err := json.Marshal(map[string]any{"cur_node_index": nodeIndex})
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func (downloader *Downloader) hongguoAccountLoginRewardInfo(ctx context.Context) (map[string]any, error) {
	extra, err := hongguoLoginRewardExtra(0)
	if err != nil {
		return nil, err
	}
	reply, err := downloader.hongguoAccountLuckycat(ctx, hongguoLoginRewardInfoPath, map[string]string{"271_extra_info": extra}, nil)
	if err != nil {
		return nil, err
	}
	if hongguoAccountInt(reply, "err_no", -1) != 0 {
		tips := mapString(reply, "err_tips")
		if tips == "" {
			tips = "登入奖励接口不可用"
		}
		return nil, fmt.Errorf("%s（错误码 %d）", tips, hongguoAccountInt(reply, "err_no", -1))
	}
	data, _ := reply["data"].(map[string]any)
	if data == nil {
		return nil, errors.New("登入奖励状态为空")
	}
	return map[string]any{
		"status":          mapString(data, "status"),
		"title":           mapString(data, "title"),
		"buttonTag":       mapString(data, "button_tag"),
		"rewardType":      mapString(data, "reward_type"),
		"rewardAmount":    hongguoAccountInt(data, "reward_amount", 0),
		"cooldownEndTime": hongguoAccountInt64(data, "cooldown_end_time", 0),
	}, nil
}

func (downloader *Downloader) hongguoAccountClaimLoginReward(ctx context.Context) (map[string]any, error) {
	body, err := json.Marshal(map[string]any{
		"271_extra_info": map[string]any{"cur_node_index": 0},
		"growth_novel_base": map[string]any{
			"path":      hongguoLoginRewardDonePath,
			"timestamp": time.Now().UnixMilli(),
		},
	})
	if err != nil {
		return nil, err
	}
	reply, err := downloader.hongguoAccountLuckycat(ctx, hongguoLoginRewardDonePath, nil, body)
	if err != nil {
		return nil, err
	}
	errNo := hongguoAccountInt(reply, "err_no", -1)
	data, _ := reply["data"].(map[string]any)
	if data == nil {
		data = map[string]any{}
	}
	return map[string]any{
		"claimed":         errNo == 0 && hongguoAccountInt(data, "reward_amount", 0) > 0,
		"errNo":           errNo,
		"errTips":         mapString(reply, "err_tips"),
		"rewardType":      mapString(data, "reward_type"),
		"rewardAmount":    hongguoAccountInt(data, "reward_amount", 0),
		"toast":           mapString(data, "toast"),
		"toastText":       mapString(data, "toast_text"),
		"cooldownEndTime": hongguoAccountInt64(data, "cooldown_end_time", 0),
	}, nil
}

func (downloader *Downloader) hongguoAccountClaimDailyCoins(ctx context.Context) (map[string]any, error) {
	info, err := downloader.hongguoAccountLoginRewardInfo(ctx)
	if err != nil {
		return map[string]any{"claimed": false, "reason": "info-failed"}, nil
	}
	status := mapString(info, "status")
	rewardType := strings.ToLower(mapString(info, "rewardType"))
	if !strings.EqualFold(status, "AVAILABLE") || (rewardType != "" && rewardType != "gold" && rewardType != "rmb" && rewardType != "rmb_cash") {
		return map[string]any{"claimed": false, "status": status, "reason": "not-available"}, nil
	}
	claimed, err := downloader.hongguoAccountClaimLoginReward(ctx)
	if err != nil {
		return map[string]any{"claimed": false, "status": status, "reason": "claim-failed"}, nil
	}
	claimed["status"] = status
	return claimed, nil
}
