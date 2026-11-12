package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

const sourceHGTV = "hgtv"

type hgtvCategory struct {
	id    string
	name  string
	genre string
	sort  string
}

var hgtvCategories = []hgtvCategory{
	{id: "home", name: "首页推荐", genre: "", sort: "hot_score"},
	{id: "real", name: "真人剧", genre: "short_play", sort: "hot_score"},
	{id: "comic", name: "漫剧", genre: "comic_series", sort: "hot_score"},
	{id: "ai", name: "AI剧", genre: "ai_series", sort: "hot_score"},
	{id: "latest", name: "最新上架", genre: "", sort: "online_time"},
}

func hgtvCategoryFor(category string) (hgtvCategory, bool) {
	key := strings.TrimSpace(category)
	switch key {
	case "", "all", "ALL", "全部", "home", "首页推荐":
		return hgtvCategories[0], true
	case "real", "short_play", "真人剧":
		return hgtvCategories[1], true
	case "comic", "comic_series", "漫剧":
		return hgtvCategories[2], true
	case "ai", "ai_series", "AI剧", "AI 剧":
		return hgtvCategories[3], true
	case "latest", "online_time", "最新上架":
		return hgtvCategories[4], true
	}
	return hgtvCategory{}, false
}

func hgtvRewriteDrama(drama Drama, sourceID string) Drama {
	drama.ID = providerDramaID(sourceHGTV, sourceID)
	drama.Source = sourceHGTV
	drama.SourceID = sourceID
	drama.ChannelName = "HGTV"
	return drama
}

func landpageFilterGroups(data map[string]any) []nativeFilterGroup {
	groups := []nativeFilterGroup{}
	for _, row := range anyList(data["selector_rows"]) {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		key := mapString(item, "type")
		if key == "" || key == "genre" {
			continue
		}
		name := mapString(item, "row_name")
		if key == "sort" {
			name = "排序"
		} else {
			name = strings.TrimPrefix(name, "全部")
		}
		if name == "" {
			continue
		}
		group := nativeFilterGroup{Key: key, Name: name}
		for _, option := range anyList(item["items"]) {
			optionMap, _ := option.(map[string]any)
			if optionMap == nil {
				continue
			}
			id := mapString(optionMap, "selector_item_id")
			optionName := mapString(optionMap, "show_name")
			if id == "" || optionName == "" {
				continue
			}
			group.Options = append(group.Options, nativeFilterOption{ID: id, Name: optionName})
		}
		if len(group.Options) > 0 {
			groups = append(groups, group)
		}
	}
	return groups
}

func (d *Downloader) hgtvLandpage(ctx context.Context, cat hgtvCategory, appPage int, filters map[string]string) ([]Drama, bool, []nativeFilterGroup, error) {
	var offset, limit int
	if appPage <= 1 {
		offset, limit = 0, 20
	} else {
		offset, limit = (appPage-2)*100+20, 100
	}
	genre := []string{}
	if cat.genre != "" {
		genre = []string{cat.genre}
	}
	selectItems := map[string]any{
		"genre": genre, "sort": []string{cat.sort},
	}
	for key, id := range filters {
		key = strings.TrimSpace(key)
		id = strings.TrimSpace(id)
		if key == "" || key == "genre" || id == "" {
			continue
		}
		selectItems[key] = []string{id}
	}
	payload := map[string]any{
		"filter_ids": "", "req_scene": "default", "offset": offset,
		"need_selector_panel": appPage == 1, "limit": limit,
		"select_items": selectItems,
		"session_id":   "", "req_type": "only_content", "client_req_type": 3,
	}
	if appPage == 1 {
		payload["req_type"] = "default"
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/reading/distribution/category/landpage/v/", nil, payload)
	if err != nil {
		return nil, false, nil, err
	}
	data := nestedMap(result, "data")
	rows := anyList(data["video_data"])
	items := make([]Drama, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		drama := hongguoDramaFromAny(row, cat.name)
		if drama.ID == "" || drama.SourceID == "" || seen[drama.SourceID] {
			continue
		}
		seen[drama.SourceID] = true
		items = append(items, hgtvRewriteDrama(drama, drama.SourceID))
	}
	hasMore, _ := data["has_more"].(bool)
	var groups []nativeFilterGroup
	if appPage == 1 {
		groups = landpageFilterGroups(data)
	}
	return items, hasMore, groups, nil
}

func (d *Downloader) fetchHGTVCatalogPage(ctx context.Context, category string, page int, filters map[string]string) ([]Drama, bool, []nativeFilterGroup, error) {
	cat, ok := hgtvCategoryFor(category)
	if !ok {
		return nil, false, nil, errors.New("HGTV 分类无效")
	}
	if page < 1 {
		page = 1
	}
	appPages := []int{page + 1}
	if page == 1 {
		appPages = []int{1, 2}
	}
	var items []Drama
	seen := map[string]bool{}
	hasMore := false
	var groups []nativeFilterGroup
	for _, appPage := range appPages {
		pageItems, pageHasMore, pageGroups, err := d.hgtvLandpage(ctx, cat, appPage, filters)
		if err != nil {
			return items, hasMore, groups, err
		}
		hasMore = pageHasMore
		if pageGroups != nil {
			groups = pageGroups
		}
		for _, item := range pageItems {
			if seen[item.SourceID] {
				continue
			}
			seen[item.SourceID] = true
			items = append(items, item)
		}
	}
	return items, hasMore, groups, nil
}

func hgtvStillsFromDetail(detail map[string]any, seriesCover string, max int) (string, []string) {
	seen := map[string]bool{}
	if seriesCover != "" {
		seen[seriesCover] = true
	}
	stills := []string{}
	for _, row := range anyList(detail["video_list"]) {
		item, _ := row.(map[string]any)
		if item == nil {
			continue
		}
		cover := mapString(item, "episode_cover", "cover")
		if cover == "" || seen[cover] {
			continue
		}
		seen[cover] = true
		stills = append(stills, cover)
		if len(stills) >= max {
			break
		}
	}
	backdrop := seriesCover
	if len(stills) > 0 {
		backdrop = stills[0]
	}
	return backdrop, stills
}

func hongguoAnyID(value any) string {
	switch item := value.(type) {
	case string:
		return strings.TrimSpace(item)
	case json.Number:
		return item.String()
	case float64:
		if item == float64(int64(item)) {
			return strconv.FormatInt(int64(item), 10)
		}
		return strconv.FormatFloat(item, 'f', -1, 64)
	case int:
		return strconv.Itoa(item)
	}
	return ""
}

func parseHGTVWebDetail(body, seriesID string) (Drama, []Chapter, error) {
	page := routerLoaderMap(parseRouterData(body), "detail_page")
	series := nestedMap(page, "seriesDetail")
	if len(series) == 0 {
		return Drama{}, nil, errors.New("HGTV 网页详情未返回剧集")
	}
	vidList := anyList(series["vid_list"])
	if len(vidList) == 0 {
		return Drama{}, nil, errors.New("HGTV 网页详情未返回分集")
	}
	title := mapString(series, "series_title", "series_name", "title")
	cover := mapString(series, "series_cover", "cover", "img")
	drama := hgtvRewriteDrama(hongguoDramaFromAny(map[string]any{
		"series_id_str": seriesID,
		"series_title":  title,
		"series_cover":  cover,
	}, "短剧"), seriesID)
	chapters := []Chapter{}
	seen := map[string]bool{}
	for index, raw := range vidList {
		videoID := hongguoAnyID(raw)
		if !hongguoNumericID.MatchString(videoID) || seen[videoID] {
			continue
		}
		seen[videoID] = true
		chapters = append(chapters, Chapter{
			ID: providerChapterID(sourceHGTV, seriesID, videoID), Source: sourceHGTV,
			Title: fmt.Sprintf("第%d集", index+1), VideoURL: "hongguo-cenc://" + videoID,
			CurrentEpisode: rawEpisode(index + 1),
		})
	}
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("HGTV 网页详情未返回有效分集")
	}
	return drama, chapters, nil
}

func (d *Downloader) fetchHGTVWebDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/detail?series_id="+url.QueryEscape(sourceID), hongguoBaseURL+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	return parseHGTVWebDetail(body, sourceID)
}

func (d *Downloader) fetchHGTVDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}, nil, errors.New("HGTV 剧集 ID 无效")
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": sourceID})
	if err != nil {
		if drama, chapters, webErr := d.fetchHGTVWebDetail(ctx, sourceID); webErr == nil {
			return drama, chapters, nil
		}
		return Drama{}, nil, err
	}
	detail := nestedMap(result, "data", "video_data")
	if mapString(detail, "series_id_str", "series_id") != sourceID {
		return Drama{}, nil, errors.New("HGTV App 未返回所请求的剧集")
	}
	drama := hgtvRewriteDrama(hongguoDramaFromAny(detail, "短剧"), sourceID)
	seriesCover := mapString(detail, "series_cover", "cover")
	backdrop, stills := hgtvStillsFromDetail(detail, seriesCover, 12)
	drama.Backdrop = backdrop
	drama.Stills = stills
	seenVideo := map[string]bool{}
	seenIndex := map[int]bool{}
	chapters := []Chapter{}
	for _, row := range anyList(detail["video_list"]) {
		video, _ := row.(map[string]any)
		if video == nil {
			continue
		}
		videoID := mapString(video, "vid")
		index, err := strconv.Atoi(mapString(video, "vid_index"))
		if err != nil || index < 1 || !hongguoNumericID.MatchString(videoID) {
			return Drama{}, nil, errors.New("HGTV App 分集编号或视频 ID 无效")
		}
		if identifier := mapString(video, "series_id"); identifier != "" && identifier != sourceID {
			return Drama{}, nil, errors.New("HGTV App 返回了其他剧集的分集")
		}
		if seenVideo[videoID] || seenIndex[index] {
			return Drama{}, nil, errors.New("HGTV App 返回了重复分集")
		}
		seenVideo[videoID], seenIndex[index] = true, true
		chapter := Chapter{
			ID: providerChapterID(sourceHGTV, sourceID, videoID), Source: sourceHGTV,
			Title: fmt.Sprintf("第%d集", index), VideoURL: "hongguo-cenc://" + videoID,
			CurrentEpisode: rawEpisode(index),
		}
		if vertical, ok := video["vertical"].(bool); ok {
			chapter.Vertical = &vertical
		}
		chapters = append(chapters, chapter)
	}
	total, _ := strconv.Atoi(mapString(detail, "episode_cnt"))
	if len(chapters) == 0 || total > len(chapters) {
		if drama, chapters, webErr := d.fetchHGTVWebDetail(ctx, sourceID); webErr == nil {
			return drama, chapters, nil
		}
		return Drama{}, nil, errors.New("HGTV App 未返回完整分集")
	}
	sort.Slice(chapters, func(i, j int) bool {
		left, _ := strconv.Atoi(chapters[i].EpisodeString(i + 1))
		right, _ := strconv.Atoi(chapters[j].EpisodeString(j + 1))
		return left < right
	})
	for index, chapter := range chapters {
		if chapter.EpisodeString(index+1) != strconv.Itoa(index+1) {
			return Drama{}, nil, errors.New("HGTV 分集列表不连续")
		}
	}
	return drama, chapters, nil
}

func (d *Downloader) searchHGTVDramas(ctx context.Context, keyword string) ([]Drama, error) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		return nil, errors.New("请输入搜索词")
	}
	query := url.Values{"aid": {"8662"}, "query": {keyword}, "page": {"1"}}
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/api/search/result?"+query.Encode(), hongguoBaseURL+"/")
	if err != nil {
		return nil, err
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		return nil, errors.New("HGTV 搜索返回了无效数据")
	}
	items := []Drama{}
	seen := map[string]bool{}
	for _, row := range anyList(decoded["searchList"]) {
		drama := hongguoDramaFromAny(row, "短剧")
		if drama.ID == "" || drama.SourceID == "" || seen[drama.SourceID] {
			continue
		}
		seen[drama.SourceID] = true
		items = append(items, hgtvRewriteDrama(drama, drama.SourceID))
	}
	return items, nil
}

func (d *Downloader) resolveHGTVMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceHGTV {
		return providerMedia{}, fmt.Errorf("HGTV 章节缺少剧 ID，请刷新剧库后重新加入队列")
	}
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, "hongguo-cenc://")
	if !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("HGTV 章节 ID 无效，请重新获取章节")
	}
	lines := []providerMedia{}
	add := func(media providerMedia) {
		flat := media
		flat.Variants = nil
		lines = append(lines, flat)
		for _, variant := range media.Variants {
			variant.Variants = nil
			lines = append(lines, variant)
		}
	}
	if !d.hongguoPlayerSuspended() {
		if media, err := d.resolveHongguoAppMedia(ctx, videoID); err == nil {
			add(media)
		} else if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
	}
	if media, err := d.resolveHongguoWebMedia(ctx, seriesID, videoID); err == nil {
		add(media)
	} else if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	// 备用播放接口（修仙版 playSource 同款修法）：站方改版后播放页
	// video_player_info 恒为空，上面一步拿不到地址；此时先调 POST
	// /api/video/protected/fallback-play-info 取 main_url 作主地址，
	// 360p 只留最后兜底。镜像站 resolveHGTVMirrorMedia 已有同样一
	// 步，直接复用同一函数（接口与配方完全相同）。
	if fallbackURL, err := d.fetchHGTVMirrorFallbackURL(ctx, videoID); err == nil {
		lines = append(lines, providerMedia{URL: fallbackURL, Referer: hongguoBaseURL + "/"})
	} else if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	lines = append(lines, providerMedia{
		URL:     hongguoBaseURL + "/video/public/" + videoID + "/360p.mp4",
		Referer: hongguoBaseURL + "/",
	})
	media := lines[0]
	media.Variants = lines
	return media, nil
}
