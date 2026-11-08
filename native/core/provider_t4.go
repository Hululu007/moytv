package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
)

const t4PlayTokenPrefix = "t4play:"
const t4PlayTokenSeparator = "\x1f"

func isT4CustomSource(source string) bool {
	return isCustomMaccmsSource(source) && customSourceTypeFor(source) == customSourceTypeT4
}

func t4APIURL(source string) string {
	if record, found := customSourceRecordOf(source); found {
		return strings.TrimSpace(record.Base)
	}
	return ""
}

func t4RequestURL(apiURL string, params map[string]string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(apiURL))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", errors.New("T4 服务地址无效")
	}
	query := parsed.Query()
	for key, value := range params {
		query.Set(key, value)
	}
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

func t4Call(ctx context.Context, d *Downloader, apiURL string, params map[string]string) (map[string]any, error) {
	address, err := t4RequestURL(apiURL, params)
	if err != nil {
		return nil, err
	}
	body, err := d.fetchProviderText(ctx, address, address)
	if err != nil {
		return nil, err
	}
	body = strings.TrimSpace(body)
	if body == "" || !strings.HasPrefix(body, "{") {
		return nil, errors.New("T4 服务未返回 JSON")
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return nil, errors.New("T4 服务响应无法解析")
	}
	return payload, nil
}

func t4String(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case json.Number:
		return v.String()
	case bool:
		if v {
			return "1"
		}
		return "0"
	default:
		return ""
	}
}

func t4Int(value any) int {
	switch v := value.(type) {
	case float64:
		return int(v)
	case json.Number:
		n, _ := v.Int64()
		return int(n)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(v))
		return n
	case bool:
		if v {
			return 1
		}
		return 0
	default:
		return 0
	}
}

func t4Items(payload map[string]any) []map[string]any {
	raw, ok := payload["list"].([]any)
	if !ok {
		return nil
	}
	items := make([]map[string]any, 0, len(raw))
	for _, row := range raw {
		if item, ok := row.(map[string]any); ok {
			items = append(items, item)
		}
	}
	return items
}

func t4Drama(source string, item map[string]any) Drama {
	id := t4String(item["vod_id"])
	title := t4String(item["vod_name"])
	if title == "" {
		title = t4String(item["name"])
	}
	if id == "" || title == "" {
		return Drama{}
	}
	cover := t4String(item["vod_pic"])
	if cover == "" {
		cover = t4String(item["vod_pic_slide"])
	}
	return Drama{
		ID:          providerDramaID(source, id),
		Source:      source,
		SourceID:    id,
		Title:       title,
		Intro:       truncate(t4String(item["vod_content"]), 2000),
		Cover:       cover,
		Category:    t4String(item["type_name"]),
		ChannelName: duanjuSourceName(source),
		Remark:      t4String(item["vod_remarks"]),
	}
}

func t4Dramas(source string, payload map[string]any) []Drama {
	items := make([]Drama, 0, len(t4Items(payload)))
	for _, item := range t4Items(payload) {
		drama := t4Drama(source, item)
		if drama.SourceID == "" {
			continue
		}
		items = append(items, drama)
	}
	return items
}

func t4HomePayload(ctx context.Context, d *Downloader, source string) (map[string]any, error) {
	apiURL := t4APIURL(source)
	if apiURL == "" {
		return nil, errors.New("站源地址不可用")
	}
	return t4Call(ctx, d, apiURL, nil)
}

func t4Categories(ctx context.Context, d *Downloader, source string) ([]nativeCategory, error) {
	payload, err := t4HomePayload(ctx, d, source)
	if err != nil {
		return nil, err
	}
	raw, _ := payload["class"].([]any)
	categories := make([]nativeCategory, 0, len(raw))
	for _, row := range raw {
		entry, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id := t4String(entry["type_id"])
		name := t4String(entry["type_name"])
		if id == "" || name == "" || id == "interests" {
			continue
		}
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	return categories, nil
}

func t4CatalogPage(ctx context.Context, d *Downloader, source string, page int, category string) ([]Drama, bool, error) {
	category = strings.TrimSpace(category)
	if category == "" {
		if page > 1 {
			return nil, false, nil
		}
		payload, err := t4HomePayload(ctx, d, source)
		if err != nil {
			return nil, false, err
		}
		return t4Dramas(source, payload), false, nil
	}
	apiURL := t4APIURL(source)
	if apiURL == "" {
		return nil, false, errors.New("站源地址不可用")
	}
	if page < 1 {
		page = 1
	}
	payload, err := t4Call(ctx, d, apiURL, map[string]string{"t": category, "pg": strconv.Itoa(page)})
	if err != nil {
		return nil, false, err
	}
	items := t4Dramas(source, payload)
	pagecount := t4Int(payload["pagecount"])
	if pagecount > 0 {
		return items, page < pagecount, nil
	}
	return items, len(items) >= 30, nil
}

func t4Search(ctx context.Context, d *Downloader, source, query string) ([]Drama, error) {
	apiURL := t4APIURL(source)
	if apiURL == "" {
		return nil, errors.New("站源地址不可用")
	}
	payload, err := t4Call(ctx, d, apiURL, map[string]string{"wd": query})
	if err != nil {
		return nil, err
	}
	return t4Dramas(source, payload), nil
}

type t4Episode struct {
	title  string
	playID string
}

type t4Route struct {
	flag     string
	episodes []t4Episode
}

func t4ParseRoutes(item map[string]any) []t4Route {
	flags := strings.Split(t4String(item["vod_play_from"]), "$$$")
	groups := strings.Split(t4String(item["vod_play_url"]), "$$$")
	routes := make([]t4Route, 0, len(groups))
	for index, group := range groups {
		route := t4Route{}
		if index < len(flags) {
			route.flag = strings.TrimSpace(flags[index])
		}
		for _, entry := range strings.Split(group, "#") {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			name, playID := entry, ""
			if cut := strings.LastIndex(entry, "$"); cut >= 0 {
				name = strings.TrimSpace(entry[:cut])
				playID = strings.TrimSpace(entry[cut+1:])
			}
			if playID == "" {
				continue
			}
			route.episodes = append(route.episodes, t4Episode{title: name, playID: playID})
		}
		if len(route.episodes) > 0 {
			routes = append(routes, route)
		}
	}
	return routes
}

func t4PlayToken(flag, playID string) string {
	return t4PlayTokenPrefix + flag + t4PlayTokenSeparator + playID
}

func t4ParsePlayToken(token string) (string, string, bool) {
	rest, found := strings.CutPrefix(token, t4PlayTokenPrefix)
	if !found {
		return "", "", false
	}
	flag, playID, found := strings.Cut(rest, t4PlayTokenSeparator)
	if !found || flag == "" || playID == "" {
		return "", "", false
	}
	return flag, playID, true
}

func t4Detail(ctx context.Context, d *Downloader, source, sourceID string) (Drama, []Chapter, error) {
	apiURL := t4APIURL(source)
	if apiURL == "" {
		return Drama{}, nil, errors.New("站源地址不可用")
	}
	payload, err := t4Call(ctx, d, apiURL, map[string]string{"ac": "1", "ids": sourceID})
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
		chapter := duanjuChapter(source, sourceID, number, episode.title, t4PlayToken(primary.flag, episode.playID), "", "")
		for _, route := range routes[1:] {
			if index >= len(route.episodes) {
				continue
			}
			chapter.Routes = append(chapter.Routes, t4PlayToken(route.flag, route.episodes[index].playID))
		}
		chapters = append(chapters, chapter)
	}
	sortDuanjuChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func (d *Downloader) t4PlayOnce(ctx context.Context, apiURL, flag, playID string) (providerMedia, error) {
	payload, err := t4Call(ctx, d, apiURL, map[string]string{"play": playID, "flag": flag})
	if err != nil {
		return providerMedia{}, err
	}
	address := t4String(payload["url"])
	if address == "" {
		return providerMedia{}, errors.New("T4 未返回播放地址")
	}
	var headers map[string]string
	if raw := t4String(payload["header"]); raw != "" {
		_ = json.Unmarshal([]byte(raw), &headers)
	}
	referer := firstNonEmpty(headers["Referer"], headers["referer"])
	userAgent := firstNonEmpty(headers["User-Agent"], headers["user-agent"])
	cookie := firstNonEmpty(headers["Cookie"], headers["cookie"])
	origin := firstNonEmpty(headers["Origin"], headers["origin"])
	media := providerMedia{URL: address, Referer: referer}
	if userAgent != "" || referer != "" || cookie != "" || origin != "" {
		media.credentials = &providerMediaCredentials{userAgent: userAgent, referer: referer, cookie: cookie, origin: origin}
	}
	parse := t4Int(payload["parse"])
	playURL := t4String(payload["playUrl"])
	if playURL == "" {
		playURL = t4String(payload["playurl"])
	}
	switch {
	case parse == 1 && playURL != "":
		media.URL = playURL + address
	case parse == 1:
		media.NeedsParse = true
	}
	return media, nil
}

func (d *Downloader) t4ResolveMedia(ctx context.Context, source string, task Task) (providerMedia, error) {
	apiURL := t4APIURL(source)
	if apiURL == "" {
		return providerMedia{}, errors.New("站源地址不可用")
	}
	tokens := []string{task.Chapter.VideoURL}
	tokens = append(tokens, task.Chapter.Routes...)
	var media providerMedia
	var variants []providerMedia
	for _, token := range tokens {
		flag, playID, ok := t4ParsePlayToken(token)
		if !ok {
			continue
		}
		resolved, err := d.t4PlayOnce(ctx, apiURL, flag, playID)
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
		return providerMedia{}, errors.New("T4 播放解析失败")
	}
	media.Variants = variants
	return media, nil
}
