package core

// 红果(新)目录：首页 / 分类 / 榜单 / 头条精选 / 自检诊断。
//
// 对照 py（hongguo_full_177_5sc7.py）：
//   - 首页 _home：行 1324-1333（loaderData.page.homeSections[].video_list，60 条）
//   - 分类 _cat：行 1451-1459（/category/<ct>?page=&category_json_ids=，recommendList + totalPages）
//   - 榜单 _rank：行 1461-1471（/rank/<key>?page=，首个非 rank_layout loader 项的 content.rankList）
//   - 分发 categoryContent：行 1342-1383（t:jx / c:__diag__ / r: / c:）
//   - 映射 _item_cat/_item_home：行 525-545（hongguoDramaFromAny 已实现同一套字段回落，这里只改挂新槽）

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
)

// fetchHongguoNewCatalogPage：新槽目录入口，接线点见 LANDING.md（nativeCatalog 新 case）。
// 返回（剧集，有无下一页，筛选组，错误）；筛选组只在首页与 c: 分类返回，与 py 的 filters 口径一致。
func (downloader *Downloader) fetchHongguoNewCatalogPage(ctx context.Context, category string, page int, filters map[string]string) ([]Drama, bool, []nativeFilterGroup, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case category == "":
		items, err := downloader.fetchHongguoNewHome(ctx)
		if err != nil {
			return nil, false, nil, err
		}
		return items, false, hongguoNewFilterGroups(ctx, downloader), nil
	case category == "t:jx" || category == "t:" || category == "__tt__":
		items, err := downloader.hongguoNewToutiaoList(ctx, page > 1)
		if err != nil {
			return nil, false, nil, err
		}
		return items, false, nil, nil
	case category == "c:__diag__" || category == "__diag__":
		items, err := downloader.hongguoNewDiagItems(ctx)
		if err != nil {
			return nil, false, nil, err
		}
		return items, false, nil, nil
	case strings.HasPrefix(category, "r:"):
		items, pages, err := downloader.fetchHongguoNewRank(ctx, strings.TrimPrefix(category, "r:"), page)
		if err != nil {
			return nil, false, nil, err
		}
		return items, page < pages, nil, nil
	default:
		route := strings.TrimPrefix(category, "c:")
		topic := ""
		if filters != nil {
			topic = strings.TrimSpace(filters["topic"])
		}
		items, pages, err := downloader.fetchHongguoNewCategory(ctx, route, page, topic)
		if err != nil {
			return nil, false, nil, err
		}
		return items, page < pages, hongguoNewFilterGroups(ctx, downloader), nil
	}
}

// fetchHongguoNewHome：py _home。首页 SSR 的 homeSections 全部 video_list，去重后取 60 条。
func (downloader *Downloader) fetchHongguoNewHome(ctx context.Context) ([]Drama, error) {
	body, err := downloader.fetchProviderText(ctx, hongguoBaseURL+"/", hongguoBaseURL+"/")
	if err != nil {
		return nil, err
	}
	return hongguoNewHomeItems(parseRouterData(body)), nil
}

// hongguoNewHomeItems：py _home 的纯解析部分（便于用真站存页单测）。
// video_list 是列表（2026-11-17 真站实测：4 个区各 9 行，全蛇形字段），
// 须按列表走：nestedMap 遇列表会判空，旧写法首页恒 0 条，正是红果(新)
// 片库目录空态的根因。行映射用 _item_home 的 Go 等价物
// hongguoNewDramaFromRankRow（蛇形/驼峰 id 回落与 py 一致）。
func hongguoNewHomeItems(data map[string]any) []Drama {
	page := nestedMap(data, "loaderData", "page")
	var items []Drama
	for _, section := range anyList(page["homeSections"]) {
		sectionMap, _ := section.(map[string]any)
		if sectionMap == nil {
			continue
		}
		for _, row := range anyList(sectionMap["video_list"]) {
			if drama := hongguoNewDramaFromRankRow(row); drama.ID != "" {
				items = append(items, drama)
			}
		}
	}
	items = hongguoNewDedupDramas(items)
	if len(items) > 60 {
		items = items[:60]
	}
	return items
}

// fetchHongguoNewCategory：py _cat。topic 非空时追加 category_json_ids 服务端筛选。
func (downloader *Downloader) fetchHongguoNewCategory(ctx context.Context, route string, page int, topic string) ([]Drama, int, error) {
	address := hongguoBaseURL + "/category/" + route + "?page=" + strconv.Itoa(page)
	if topic != "" {
		address += "&category_json_ids=" + topic
	}
	body, err := downloader.fetchProviderText(ctx, address, hongguoBaseURL+"/")
	if err != nil {
		return nil, 0, err
	}
	pageData := routerLoaderMap(parseRouterData(body), "category_page", "category_$")
	if len(pageData) == 0 || pageData["isSuccess"] == false {
		return nil, 0, errors.New("红果(新)分类数据不可用，可能是页面结构或访问权限变化")
	}
	var items []Drama
	for _, row := range anyList(pageData["recommendList"]) {
		if drama := hongguoDramaFromAny(row, "短剧"); drama.ID != "" {
			items = append(items, drama)
		}
	}
	pages, _ := strconv.Atoi(mapString(nestedMap(pageData, "pagination"), "totalPages"))
	if pages < 1 {
		pages = 1
	}
	return hongguoNewDedupDramas(hongguoNewRelabelDramas(items)), pages, nil
}

// fetchHongguoNewRank：py _rank。取 loaderData 里首个非 rank_layout 的字典项，
// 读 content.rankList；页数读 content.pagination.totalPages，读不到时回落 py 口径
// （满 20 条算 2 页，否则 1 页）。
func (downloader *Downloader) fetchHongguoNewRank(ctx context.Context, key string, page int) ([]Drama, int, error) {
	body, err := downloader.fetchProviderText(ctx, hongguoBaseURL+"/rank/"+key+"?page="+strconv.Itoa(page), hongguoBaseURL+"/")
	if err != nil {
		return nil, 0, err
	}
	data := parseRouterData(body)
	loader, _ := data["loaderData"].(map[string]any)
	// py 按 JSON 顺序取首个非 rank_layout 项；Go map 无序，改按语义取：
	// 优先含 content.rankList 的项，否则取排序后首个非 rank_layout 字典项。
	names := make([]string, 0, len(loader))
	for name := range loader {
		names = append(names, name)
	}
	sort.Strings(names)
	var box map[string]any
	for _, name := range names {
		if name == "rank_layout" {
			continue
		}
		m, ok := loader[name].(map[string]any)
		if !ok {
			continue
		}
		if box == nil {
			box = m
		}
		// rankList 是列表，须按列表判有无：nestedMap 遇列表判空，
		// 旧守卫恒假、语义优先从未生效（与首页 video_list 同一根因）。
		if len(anyList(nestedMap(m, "content")["rankList"])) > 0 {
			box = m
			break
		}
	}
	content := nestedMap(box, "content")
	var items []Drama
	for _, row := range anyList(content["rankList"]) {
		if drama := hongguoNewDramaFromRankRow(row); drama.ID != "" {
			items = append(items, drama)
		}
	}
	items = hongguoNewDedupDramas(items)
	pages, _ := strconv.Atoi(mapString(nestedMap(content, "pagination"), "totalPages"))
	if pages < 1 {
		pages = 1
		if len(items) >= 20 {
			pages = 2
		}
	}
	return items, pages, nil
}

// hongguoNewDramaFromRankRow：榜单行映射，对照 py _item_home（_rank 行 1469 用它）。
// 榜单行是驼峰字段（seriesId/title/cover/episodeCount/description），与分类行的蛇形
// 字段不同；通用 hongguoDramaFromAny 只认蛇形 id，榜单行会全部落空（2026-11-17 活测
// 实证：py 20 条、Go 0 条），故单写。id 回落与 py 一致：series_id → seriesId → id。
func hongguoNewDramaFromRankRow(row any) Drama {
	m, ok := row.(map[string]any)
	if !ok {
		return Drama{}
	}
	sourceID := firstNonEmpty(mapString(m, "series_id", "seriesId", "id"))
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(m, "series_title", "title"), sourceID)
	cover := hongguoNewUnescapeURL(firstNonEmpty(mapString(m, "series_cover", "cover")))
	intro := firstNonEmpty(mapString(m, "series_intro", "description"))
	count := firstNonEmpty(mapString(m, "episode_cnt", "episodeCount"))
	remark := firstNonEmpty(mapString(m, "episode_right_text"))
	if remark == "" && count != "" {
		remark = "全" + count + "集"
	}
	return Drama{
		ID: providerDramaID(sourceHongguoNew, sourceID), Source: sourceHongguoNew, SourceID: sourceID,
		Title: title, Name: title, Desc: intro, Intro: intro, Cover: cover, CoverURL: cover,
		CategoryName: "短剧", ChannelName: hongguoNewChannelName, Remark: remark,
		TotalEpisode: count, EpisodeCount: count, Tags: mapStringSlice(m, "tags"),
		Score: mapString(m, "scoreText"), Heat: mapString(m, "heatText"),
	}
}
