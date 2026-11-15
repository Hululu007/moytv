package core

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

// drpyS HTTP 客户端：drpyS（drpy 的服务端形态，PHP/Python/JS 蜘蛛都在
// 服务端执行）对外暴露的接口。
//
// 请求形态证据（只读样本）：drpy-node 解包样本
// controllers/api.js 的 /api/:module 分发——
//   - 分类：query 同时含 ac 与 t → category(t, pg, 1, extend)；
//   - 详情：query 同时含 ac 与 ids → detail(ids.split(','))；
//   - 搜索：query 含 wd → search(wd, quick, pg)；
//   - 播放：query 含 play → play(flag, play)；
//   - 其余 → home(filter)。
// 关键差别只在“分类/详情必须带 ac 参数”（只判存在，不判取值）；T4
// 客户端的分类请求不带 ac，打 drpyS 会落到 home。本客户端据此发参，
// 响应解析复用 provider_t4_compat.go 的共享层，不另写一套。
//
// 源类型 kind 为 "drpys"，与 "t4" 并列分发（见各 dispatch 点的
// isDrpysCustomSource 分支）。PHP 蜘蛛文件本身不在设备上执行，
// 本客户端只认 HTTP 接口；真 drpyS 服务未联调，见测试说明。

func isDrpysCustomSource(source string) bool {
	return isCustomMaccmsSource(source) && customSourceTypeFor(source) == customSourceTypeDrpys
}

func drpysAPIURL(source string) string {
	if record, found := customSourceRecordOf(source); found {
		return strings.TrimSpace(record.Base)
	}
	return ""
}

func drpysCall(ctx context.Context, d *Downloader, apiURL string, params map[string]string) (map[string]any, error) {
	address, err := t4RequestURL(apiURL, params)
	if err != nil {
		return nil, errors.New("drpyS 服务地址无效")
	}
	body, err := d.fetchProviderText(ctx, address, address)
	if err != nil {
		return nil, err
	}
	payload, err := httpAggDecodeBody(body)
	if err != nil {
		if errors.Is(err, errHTTPAggNotJSON) {
			return nil, errors.New("drpyS 服务未返回 JSON")
		}
		return nil, errors.New("drpyS 服务响应无法解析")
	}
	return payload, nil
}

// drpysRequestParams 返回各操作的查询参数（供测试断言请求形态；
// 真正发请求走 drpysCall + t4RequestURL）。
func drpysRequestParams(operation, category string, page int, query, sourceID, flag, playID string) map[string]string {
	switch operation {
	case "home":
		return nil
	case "category":
		return map[string]string{"ac": "1", "t": category, "pg": strconv.Itoa(max(1, page))}
	case "detail":
		return map[string]string{"ac": "1", "ids": sourceID}
	case "search":
		return map[string]string{"wd": query}
	case "play":
		return map[string]string{"play": playID, "flag": flag}
	default:
		return nil
	}
}

func drpysHomePayload(ctx context.Context, d *Downloader, source string) (map[string]any, error) {
	apiURL := drpysAPIURL(source)
	if apiURL == "" {
		return nil, errors.New("站源地址不可用")
	}
	return drpysCall(ctx, d, apiURL, nil)
}

func drpysCategories(ctx context.Context, d *Downloader, source string) ([]nativeCategory, error) {
	payload, err := drpysHomePayload(ctx, d, source)
	if err != nil {
		return nil, err
	}
	classes := httpAggClasses(payload)
	categories := make([]nativeCategory, 0, len(classes))
	for _, entry := range classes {
		categories = append(categories, nativeCategory{ID: entry.id, Name: entry.name})
	}
	return categories, nil
}

func drpysCatalogPage(ctx context.Context, d *Downloader, source string, page int, category string) ([]Drama, bool, error) {
	category = strings.TrimSpace(category)
	if category == "" {
		if page > 1 {
			return nil, false, nil
		}
		payload, err := drpysHomePayload(ctx, d, source)
		if err != nil {
			return nil, false, err
		}
		return t4Dramas(source, payload), false, nil
	}
	apiURL := drpysAPIURL(source)
	if apiURL == "" {
		return nil, false, errors.New("站源地址不可用")
	}
	if page < 1 {
		page = 1
	}
	payload, err := drpysCall(ctx, d, apiURL, drpysRequestParams("category", category, page, "", "", "", ""))
	if err != nil {
		return nil, false, err
	}
	items := t4Dramas(source, payload)
	return items, httpAggHasMore(payload, page, len(items)), nil
}

func drpysSearch(ctx context.Context, d *Downloader, source, query string) ([]Drama, error) {
	apiURL := drpysAPIURL(source)
	if apiURL == "" {
		return nil, errors.New("站源地址不可用")
	}
	payload, err := drpysCall(ctx, d, apiURL, drpysRequestParams("search", "", 0, query, "", "", ""))
	if err != nil {
		return nil, err
	}
	return t4Dramas(source, payload), nil
}

// drpysPlayToken 复用 T4 的章节令牌格式（flag + playID），分发按源类型
// 走 drpysResolveMedia，不会与 T4 源串线。
func drpysPlayToken(flag, playID string) string {
	return t4PlayToken(flag, playID)
}

func drpysParsePlayToken(token string) (string, string, bool) {
	return t4ParsePlayToken(token)
}

func drpysDetail(ctx context.Context, d *Downloader, source, sourceID string) (Drama, []Chapter, error) {
	apiURL := drpysAPIURL(source)
	if apiURL == "" {
		return Drama{}, nil, errors.New("站源地址不可用")
	}
	payload, err := drpysCall(ctx, d, apiURL, drpysRequestParams("detail", "", 0, "", sourceID, "", ""))
	if err != nil {
		return Drama{}, nil, err
	}
	items := t4Items(payload)
	if len(items) == 0 {
		return Drama{}, nil, errors.New("未找到该剧")
	}
	drama := t4Drama(source, items[0])
	if drama.SourceID == "" {
		return Drama{}, nil, errors.New("未找到该剧")
	}
	routes := t4ParseRoutes(items[0])
	if len(routes) == 0 {
		return drama, nil, nil
	}
	primary := routes[0]
	chapters := make([]Chapter, 0, len(primary.episodes))
	for index, episode := range primary.episodes {
		number := duanjuEpisodeNumber(episode.title, index+1)
		chapter := duanjuChapter(source, sourceID, number, episode.title, drpysPlayToken(primary.flag, episode.playID), "", "")
		for _, route := range routes[1:] {
			if index >= len(route.episodes) {
				continue
			}
			chapter.Routes = append(chapter.Routes, drpysPlayToken(route.flag, route.episodes[index].playID))
		}
		chapters = append(chapters, chapter)
	}
	sortDuanjuChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func (d *Downloader) drpysPlayOnce(ctx context.Context, apiURL, flag, playID string) (providerMedia, error) {
	payload, err := drpysCall(ctx, d, apiURL, drpysRequestParams("play", "", 0, "", "", flag, playID))
	if err != nil {
		return providerMedia{}, err
	}
	played := httpAggPlay(payload)
	if !played.hasURL {
		return providerMedia{}, errors.New("drpyS 未返回播放地址")
	}
	headers := played.headers
	referer := firstNonEmpty(headers["Referer"], headers["referer"])
	userAgent := firstNonEmpty(headers["User-Agent"], headers["user-agent"])
	cookie := firstNonEmpty(headers["Cookie"], headers["cookie"])
	origin := firstNonEmpty(headers["Origin"], headers["origin"])
	media := providerMedia{URL: played.url, Referer: referer, NeedsParse: played.needsParse}
	if userAgent != "" || referer != "" || cookie != "" || origin != "" {
		media.credentials = &providerMediaCredentials{userAgent: userAgent, referer: referer, cookie: cookie, origin: origin}
	}
	return media, nil
}

func (d *Downloader) drpysResolveMedia(ctx context.Context, source string, task Task) (providerMedia, error) {
	apiURL := drpysAPIURL(source)
	if apiURL == "" {
		return providerMedia{}, errors.New("站源地址不可用")
	}
	tokens := []string{task.Chapter.VideoURL}
	tokens = append(tokens, task.Chapter.Routes...)
	var media providerMedia
	var variants []providerMedia
	for _, token := range tokens {
		flag, playID, ok := drpysParsePlayToken(token)
		if !ok {
			continue
		}
		resolved, err := d.drpysPlayOnce(ctx, apiURL, flag, playID)
		if err != nil {
			continue
		}
		if media.URL == "" {
			media = resolved
		} else {
			variants = append(variants, resolved)
		}
	}
	if media.URL == "" {
		return providerMedia{}, errors.New("drpyS 播放解析失败")
	}
	media.Variants = variants
	return media, nil
}
