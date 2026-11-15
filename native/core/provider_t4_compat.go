package core

import (
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
)

// HTTP 聚合接口（T4 / drpyS）共享响应解析层。
//
// T4 与 drpyS 都是“一个 HTTP 地址 + 查询参数，返回 MacCMS 风格 JSON”的
// 接口，返回形态只有字段名与信封的差别：
//   - T4：{class:[{type_id,type_name}], list:[{vod_id,vod_name,vod_pic,
//     vod_play_from,vod_play_url}], pagecount}；播放 {url,header,parse,playUrl}。
//   - drpyS（证据：drpy-node 解包样本 controllers/api.js 的 /api/:module
//     分发）：同一套 vod_* 字段，播放同样走 {play,flag} 取 {url,header,parse}。
// 本文件把两边共用的“信封拆包、字段别名、线路解析、播放解析”收在一起，
// T4 与 drpyS 各自只保留请求参数的差别。只做解析，不发请求。

var (
	errHTTPAggNotJSON = errors.New("not json")
	errHTTPAggBadJSON = errors.New("bad json")
)

// httpAggDecodeBody 把接口响应体解成对象：接受 JSON 对象、顶层数组
// （包成 {list:[...]}）、JSONP 包裹（callback({...})）。其余形态报错。
func httpAggDecodeBody(body string) (map[string]any, error) {
	trimmed := strings.TrimSpace(body)
	if trimmed == "" {
		return nil, errHTTPAggNotJSON
	}
	trimmed = strings.TrimSuffix(trimmed, ";")
	trimmed = strings.TrimSpace(trimmed)
	if !strings.HasPrefix(trimmed, "{") && !strings.HasPrefix(trimmed, "[") {
		if open := strings.Index(trimmed, "("); open >= 0 && strings.HasSuffix(trimmed, ")") {
			trimmed = strings.TrimSpace(trimmed[open+1 : len(trimmed)-1])
		}
	}
	if strings.HasPrefix(trimmed, "[") {
		var rows []any
		if err := json.Unmarshal([]byte(trimmed), &rows); err != nil {
			return nil, errHTTPAggBadJSON
		}
		return map[string]any{"list": rows}, nil
	}
	if !strings.HasPrefix(trimmed, "{") {
		return nil, errHTTPAggNotJSON
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(trimmed), &payload); err != nil {
		return nil, errHTTPAggBadJSON
	}
	return payload, nil
}

// httpAggRoot 拆信封：data/result 里若装着 list/class 等业务字段，
// 把它们提到顶层（信封自带的 code/msg 不动）。无信封时原样返回。
func httpAggRoot(payload map[string]any) map[string]any {
	for _, key := range []string{"data", "result"} {
		inner, ok := payload[key].(map[string]any)
		if !ok {
			continue
		}
		hit := false
		for _, field := range []string{"list", "class", "classes", "classlist", "types", "categories", "pagecount", "url", "playUrl", "play_url", "video_url", "videoUrl", "stream_url", "file"} {
			if _, found := inner[field]; found {
				hit = true
				break
			}
		}
		if !hit {
			continue
		}
		merged := make(map[string]any, len(payload)+len(inner))
		for k, v := range payload {
			merged[k] = v
		}
		for k, v := range inner {
			merged[k] = v
		}
		return merged
	}
	return payload
}

var httpAggListKeys = []string{"list", "data", "result", "items", "rows", "vod"}

// httpAggItems 取列表条目：list/data/result/items/rows/vod 任一数组键；
// 都没有且对象本身就是一条 vod 记录（有 id+标题）时，把自身当成一条。
func httpAggItems(payload map[string]any) []map[string]any {
	root := httpAggRoot(payload)
	for _, key := range httpAggListKeys {
		raw, ok := root[key].([]any)
		if !ok {
			continue
		}
		items := make([]map[string]any, 0, len(raw))
		for _, row := range raw {
			if item, ok := row.(map[string]any); ok {
				items = append(items, item)
			}
		}
		if len(items) > 0 {
			return items
		}
	}
	if httpAggFirstString(root, "vod_id", "id", "vid") != "" &&
		httpAggFirstString(root, "vod_name", "name", "title") != "" {
		return []map[string]any{root}
	}
	return nil
}

// httpAggFirstString 按键序取第一个非空字符串（数字/布尔按 t4String 转）。
func httpAggFirstString(item map[string]any, keys ...string) string {
	for _, key := range keys {
		if value := t4String(item[key]); value != "" {
			return value
		}
	}
	return ""
}

type httpAggClass struct {
	id   string
	name string
}

var httpAggClassKeys = []string{"class", "classes", "classlist", "types", "categories"}

// httpAggClasses 取分类：class/classes/classlist/types/categories 任一
// 数组键；id 取 type_id/id/tid，名取 type_name/name/title；interests
// 是伪分类（猜你喜欢），与 T4 旧口径一致跳过。
func httpAggClasses(payload map[string]any) []httpAggClass {
	root := httpAggRoot(payload)
	for _, key := range httpAggClassKeys {
		raw, ok := root[key].([]any)
		if !ok {
			continue
		}
		classes := []httpAggClass{}
		for _, row := range raw {
			entry, ok := row.(map[string]any)
			if !ok {
				continue
			}
			id := httpAggFirstString(entry, "type_id", "id", "tid", "typeId", "value")
			name := httpAggFirstString(entry, "type_name", "name", "title", "label")
			if id == "" || name == "" || id == "interests" {
				continue
			}
			classes = append(classes, httpAggClass{id: id, name: name})
		}
		if len(classes) > 0 {
			return classes
		}
	}
	return nil
}

// httpAggDrama 把一条记录转成剧集卡片：id/标题/封面/简介/备注/分类
// 均认 vod_* 主键与常见别名；id 或标题缺失时返回空 Drama（旧口径）。
func httpAggDrama(source string, item map[string]any) Drama {
	id := httpAggFirstString(item, "vod_id", "id", "vid", "vodid")
	title := httpAggFirstString(item, "vod_name", "name", "title", "vod_title")
	if id == "" || title == "" {
		return Drama{}
	}
	cover := httpAggFirstString(item, "vod_pic", "pic", "cover", "vod_pic_slide", "img", "poster")
	return Drama{
		ID:          providerDramaID(source, id),
		Source:      source,
		SourceID:    id,
		Title:       title,
		Intro:       truncate(httpAggFirstString(item, "vod_content", "content", "desc", "intro", "vod_blurb"), 2000),
		Cover:       cover,
		Category:    httpAggFirstString(item, "type_name", "vod_class", "category", "typeName"),
		ChannelName: duanjuSourceName(source),
		Remark:      httpAggFirstString(item, "vod_remarks", "remarks", "vod_remark"),
	}
}

// httpAggPageCount 取总页数：pagecount 主键与常见别名；都没有时 0。
func httpAggPageCount(payload map[string]any) int {
	root := httpAggRoot(payload)
	for _, key := range []string{"pagecount", "pageCount", "total_page", "totalpage", "pages", "page_total"} {
		if n := t4Int(root[key]); n > 0 {
			return n
		}
	}
	return 0
}

// httpAggHasMore 由总页数/总数判断是否还有下一页：优先总页数；无总页数
// 时用总数与本页条数推算；都没有时沿用“满 30 条即有下一页”的旧口径。
func httpAggHasMore(payload map[string]any, page, itemCount int) bool {
	if pagecount := httpAggPageCount(payload); pagecount > 0 {
		return page < pagecount
	}
	root := httpAggRoot(payload)
	if total := t4Int(root["total"]); total > 0 && itemCount > 0 {
		return page*itemCount < total
	}
	return itemCount >= 30
}

// httpAggRoutes 解析详情的线路/分集，认四种形态：
//  1. 字符串：vod_play_from/vod_play_url 以 $$$ 分线路、# 分集、$ 分名址
//     （分集分隔也认换行，少数老模板用换行分隔）；
//  2. 数组：vod_play_url 是字符串数组（每项“名$址”或裸地址）或对象数组
//     （{name,url}），vod_play_from 同样可为数组；
//  3. 对象：vod_play_url 是 {线路名: "名$址#..."} 映射（键排序后定序）；
//  4. episodes/play_list 对象数组：无 vod_play_url 时的单线路分集。
func httpAggRoutes(item map[string]any) []t4Route {
	if routes := httpAggRoutesFromString(item); len(routes) > 0 {
		return routes
	}
	if routes := httpAggRoutesFromArray(item); len(routes) > 0 {
		return routes
	}
	if routes := httpAggRoutesFromMap(item); len(routes) > 0 {
		return routes
	}
	return httpAggRoutesFromEpisodes(item)
}

func httpAggSplitPlayEntries(group string) []t4Episode {
	group = strings.ReplaceAll(group, "\r\n", "#")
	group = strings.ReplaceAll(group, "\n", "#")
	episodes := []t4Episode{}
	entries := strings.Split(group, "#")
	for i, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		name, playID := entry, ""
		if cut := strings.LastIndex(entry, "$"); cut >= 0 {
			name = strings.TrimSpace(entry[:cut])
			playID = strings.TrimSpace(entry[cut+1:])
		} else if strings.HasPrefix(entry, "http://") || strings.HasPrefix(entry, "https://") {
			// 裸地址（无“名$址”分隔）：地址本身可播，集名按位置补。
			playID = entry
			name = "第" + strconv.Itoa(i+1) + "集"
		}
		if playID == "" {
			continue
		}
		episodes = append(episodes, t4Episode{title: name, playID: playID})
	}
	return episodes
}

func httpAggRoutesFromString(item map[string]any) []t4Route {
	playURL := httpAggFirstString(item, "vod_play_url", "play_url", "playUrl")
	if playURL == "" {
		return nil
	}
	flags := strings.Split(httpAggFirstString(item, "vod_play_from", "play_from"), "$$$")
	groups := strings.Split(playURL, "$$$")
	routes := []t4Route{}
	for index, group := range groups {
		route := t4Route{}
		if index < len(flags) {
			route.flag = strings.TrimSpace(flags[index])
		}
		route.episodes = httpAggSplitPlayEntries(group)
		if len(route.episodes) > 0 {
			routes = append(routes, route)
		}
	}
	return routes
}

func httpAggEpisodesFromValue(value any, fallbackTitle string) []t4Episode {
	switch v := value.(type) {
	case string:
		return httpAggSplitPlayEntries(strings.TrimSpace(v))
	case map[string]any:
		url := httpAggFirstString(v, "url", "play_url", "playUrl", "address", "link")
		if url == "" {
			return nil
		}
		name := httpAggFirstString(v, "name", "title", "episode", "vod_name")
		if name == "" {
			name = fallbackTitle
		}
		return []t4Episode{{title: name, playID: url}}
	}
	return nil
}

func httpAggRoutesFromArray(item map[string]any) []t4Route {
	raw, ok := item["vod_play_url"].([]any)
	if !ok {
		raw, ok = item["play_url"].([]any)
	}
	if !ok || len(raw) == 0 {
		return nil
	}
	// 元素是数组 → 每组一条线路（组内元素再按对象/字符串解析）。
	if _, isGroup := raw[0].([]any); isGroup {
		flags := []string{}
		if flagRaw, ok := item["vod_play_from"].([]any); ok {
			for _, f := range flagRaw {
				flags = append(flags, t4String(f))
			}
		}
		routes := []t4Route{}
		for index, groupValue := range raw {
			group, ok := groupValue.([]any)
			if !ok {
				continue
			}
			route := t4Route{}
			if index < len(flags) {
				route.flag = strings.TrimSpace(flags[index])
			}
			for i, entry := range group {
				route.episodes = append(route.episodes, httpAggEpisodesFromValue(entry, "第"+strconv.Itoa(i+1)+"集")...)
			}
			if len(route.episodes) > 0 {
				routes = append(routes, route)
			}
		}
		return routes
	}
	route := t4Route{flag: httpAggFirstString(item, "vod_play_from", "play_from")}
	for i, entry := range raw {
		route.episodes = append(route.episodes, httpAggEpisodesFromValue(entry, "第"+strconv.Itoa(i+1)+"集")...)
	}
	if len(route.episodes) == 0 {
		return nil
	}
	return []t4Route{route}
}

func httpAggRoutesFromMap(item map[string]any) []t4Route {
	raw, ok := item["vod_play_url"].(map[string]any)
	if !ok {
		return nil
	}
	flags := make([]string, 0, len(raw))
	for flag := range raw {
		flags = append(flags, flag)
	}
	sort.Strings(flags)
	routes := []t4Route{}
	for _, flag := range flags {
		route := t4Route{flag: flag}
		switch v := raw[flag].(type) {
		case string:
			route.episodes = httpAggSplitPlayEntries(v)
		case []any:
			for i, entry := range v {
				route.episodes = append(route.episodes, httpAggEpisodesFromValue(entry, "第"+strconv.Itoa(i+1)+"集")...)
			}
		}
		if len(route.episodes) > 0 {
			routes = append(routes, route)
		}
	}
	return routes
}

func httpAggRoutesFromEpisodes(item map[string]any) []t4Route {
	var raw []any
	var ok bool
	for _, key := range []string{"episodes", "play_list", "playlist"} {
		if raw, ok = item[key].([]any); ok && len(raw) > 0 {
			break
		}
	}
	if !ok || len(raw) == 0 {
		return nil
	}
	route := t4Route{flag: httpAggFirstString(item, "vod_play_from", "play_from")}
	for i, entry := range raw {
		route.episodes = append(route.episodes, httpAggEpisodesFromValue(entry, "第"+strconv.Itoa(i+1)+"集")...)
	}
	if len(route.episodes) == 0 {
		return nil
	}
	return []t4Route{route}
}

// httpAggPlayResult 是播放接口返回的归一结果。
type httpAggPlayResult struct {
	url        string
	headers    map[string]string
	needsParse bool
	hasURL     bool
}

// httpAggPlay 解析播放响应：地址认 url/playUrl/video_url 等别名与 data
// 信封；header 认对象/JSON 字符串/键值对列表三种形态；parse/jx 为 1 时
// 需要二次解析，playUrl 存在时按旧口径拼成最终地址（playUrl + url）。
func httpAggPlay(payload map[string]any) httpAggPlayResult {
	root := httpAggRoot(payload)
	address := httpAggFirstString(root, "url", "play_url", "video_url", "videoUrl", "stream_url", "file", "source", "m3u8")
	if address == "" {
		if raw, ok := root["url"].([]any); ok && len(raw) > 0 {
			address = t4String(raw[0])
		}
	}
	playURL := httpAggFirstString(root, "playUrl", "playurl")
	headers := httpAggHeaders(root["header"])
	if len(headers) == 0 {
		headers = httpAggHeaders(root["headers"])
	}
	needsParse := httpAggParseFlag(root["parse"]) || httpAggParseFlag(root["jx"]) ||
		httpAggParseFlag(root["needParse"]) || httpAggParseFlag(root["needsParse"])
	result := httpAggPlayResult{headers: headers, needsParse: needsParse}
	switch {
	case address != "" && needsParse && playURL != "" && playURL != address:
		result.url = playURL + address
		result.needsParse = false
		result.hasURL = true
	case address != "":
		result.url = address
		result.hasURL = true
	case playURL != "":
		result.url = playURL
		result.hasURL = true
	}
	return result
}

func httpAggParseFlag(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case float64:
		return v == 1
	case json.Number:
		return v.String() == "1"
	case string:
		trimmed := strings.TrimSpace(strings.ToLower(v))
		return trimmed == "1" || trimmed == "true"
	default:
		return false
	}
}

// httpAggHeaders 收三种 header 形态：对象、JSON 字符串、键值对列表
// （[k, v] 数组或 {key,value}/{name,value} 对象）。
func httpAggHeaders(raw any) map[string]string {
	headers := map[string]string{}
	switch v := raw.(type) {
	case map[string]any:
		for k, hv := range v {
			if s := t4String(hv); s != "" {
				headers[k] = s
			}
		}
	case string:
		trimmed := strings.TrimSpace(v)
		if strings.HasPrefix(trimmed, "{") {
			var decoded map[string]any
			if err := json.Unmarshal([]byte(trimmed), &decoded); err == nil {
				for k, hv := range decoded {
					if s := t4String(hv); s != "" {
						headers[k] = s
					}
				}
			}
		}
	case []any:
		for _, row := range v {
			switch entry := row.(type) {
			case []any:
				if len(entry) >= 2 {
					headers[t4String(entry[0])] = t4String(entry[1])
				}
			case map[string]any:
				key := httpAggFirstString(entry, "key", "name")
				value := httpAggFirstString(entry, "value")
				if key != "" {
					headers[key] = value
				}
			}
		}
	}
	return headers
}
