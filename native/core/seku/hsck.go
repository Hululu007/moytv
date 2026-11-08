package seku

import (
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// ---- hsck123.com （黄色仓库）, recipe from ZakaHsckAmns ----

// hsckCats is the site's real navigation (verified 2026-10-23,
// batch/hsck_categories.md): 10 categories, id = the site's type
// value. "new" is kept as the id of the first category: the server
// default stream (home, no type param) IS ycgc/国产新片， and
// sites.go's DefaultCat for this slot is "new", so hsckCatalog maps
// "new" (and ""/"ycgc") to type=ycgc.
var hsckCats = []struct{ id, name string }{
	{"new", "国产新片"},
	{"gcjp", "國產舊篇"},
	{"wz", "无码中文字幕"},
	{"yz", "有码中文字幕"},
	{"rw", "日本无码"},
	{"ry", "日本有码"},
	{"qp", "骑兵破解"},
	{"gc", "国产视频"},
	{"om", "欧美高清"},
	{"dm", "动漫剧情"},
}

func hsckCatName(category string) string {
	for _, c := range hsckCats {
		if c.id == category {
			return c.name
		}
	}
	if category == "ycgc" {
		return "国产新片"
	}
	return "国产新片"
}

const hsckHost = "https://hsck123.com"
const hsckUA = "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

var hsckHosts = []string{
	hsckHost,
	"https://hsck123.25img.com",
	"https://hsck0.cctv38.com",
}

func hsckHeaders() map[string]string {
	return hsckHeadersFor(hsckHost)
}

func hsckHeadersFor(host string) map[string]string {
	return map[string]string{
		"User-Agent":      hsckUA,
		"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
		"Accept-Language": "zh-CN,zh;q=0.9",
		"Referer":         host + "/",
	}
}

func hsckGet(path string) ([]byte, string, error) {
	var lastErr error
	var lastCode int
	for _, host := range hsckHosts {
		body, code, _, err := httpGet(host+path, hsckHeadersFor(host))
		if err == nil && code == 200 {
			return body, host, nil
		}
		if err != nil {
			lastErr = err
		}
		lastCode = code
	}
	return nil, "", fmt.Errorf("hsck http %d err %v", lastCode, lastErr)
}

var (
	hsckListRe  = regexp.MustCompile(`(?s)href="(/view/\?id=[a-z0-9]+)"[^>]*?title="([^"]*)"[^>]*?data-original="([^"]*)"`)
	hsckIDRe    = regexp.MustCompile(`id=([a-z0-9]+)`)
	hsckPagesRe = regexp.MustCompile(`totalPages:\s*(\d+)`)
	hsckTitleRe = regexp.MustCompile(`(?s)<title>(.*?)</title>`)
	hsckImgRe   = regexp.MustCompile(`(?s)<img id="video_img"[^>]*?alt="([^"]*)"[^>]*?src="([^"]*)"`)
	hsckM3u8Re  = regexp.MustCompile(`https?://[^\s'"<>]+\.m3u8[^\s'"<>]*`)
)

func hsckParseList(slot, html string) []interface{} {
	return hsckParseListAs(slot, html, "国产新片")
}

func hsckParseListAs(slot, html, catName string) []interface{} {
	items := []interface{}{}
	seen := map[string]bool{}
	for _, m := range hsckListRe.FindAllStringSubmatch(html, -1) {
		idm := hsckIDRe.FindStringSubmatch(m[1])
		if idm == nil {
			continue
		}
		id := idm[1]
		if seen[id] {
			continue
		}
		seen[id] = true
		items = append(items, makeDrama(slot, id, cleanText(m[2]), strings.TrimSpace(m[3]), "", catName, ""))
	}
	return items
}

func hsckCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	// Category id is the site's type value; "new"/""/"ycgc" are the
	// same stream (server default type is ycgc — hsck_categories.md).
	typ := category
	switch typ {
	case "", "new", "ycgc":
		typ = "ycgc"
	}
	if page < 1 {
		page = 1
	}
	body, _, err := hsckGet(fmt.Sprintf("/?type=%s&p=%d", typ, page))
	if err != nil {
		return nil, 0, false, fmt.Errorf("hsck catalog %v", err)
	}
	html := string(body)
	items := hsckParseListAs(slot, html, hsckCatName(category))
	totalPages := 1
	if m := hsckPagesRe.FindStringSubmatch(html); m != nil {
		totalPages, _ = strconv.Atoi(m[1])
	}
	return items, totalPages * 40, page < totalPages, nil
}

func hsckSearch(slot, kw string, page int) ([]interface{}, int, bool, error) {
	body, _, err := hsckGet(fmt.Sprintf("/?p=%d&search2=ndafeoafa&search=%s", page, url.QueryEscape(kw)))
	if err != nil {
		return nil, 0, false, fmt.Errorf("hsck search %v", err)
	}
	items := hsckParseListAs(slot, string(body), "搜索")
	return items, len(items), false, nil
}

func hsckFetchDetail(rawID string) (title, cover, playURL, host string, err error) {
	body, host, err := hsckGet(fmt.Sprintf("/view/?id=%s", rawID))
	if err != nil {
		return "", "", "", "", fmt.Errorf("hsck detail %v", err)
	}
	html := string(body)
	if m := hsckTitleRe.FindStringSubmatch(html); m != nil {
		title = cleanText(m[1])
		if i := strings.LastIndex(title, " - "); i > 0 {
			title = title[:i]
		}
	}
	if m := hsckImgRe.FindStringSubmatch(html); m != nil {
		cover = strings.TrimSpace(m[1])
		playURL = strings.TrimSpace(m[2])
	}
	if playURL == "" {
		if m := hsckM3u8Re.FindString(html); m != "" {
			playURL = m
		}
	}
	return title, cover, playURL, host, nil
}

func hsckDetail(slot, rawID string) (map[string]interface{}, error) {
	title, cover, playURL, _, err := hsckFetchDetail(rawID)
	if err != nil {
		return nil, err
	}
	remark := "无源"
	if playURL != "" {
		remark = "直连"
	}
	d := makeDrama(slot, rawID, title, cover, remark, "黄色仓库", title)
	return d, nil
}

func hsckResolve(slot, rawID string) (map[string]interface{}, error) {
	_, _, playURL, host, err := hsckFetchDetail(rawID)
	if err != nil {
		return nil, err
	}
	if playURL == "" {
		return nil, fmt.Errorf("no play url")
	}
	if host == "" {
		host = hsckHost
	}
	return playResult(playURL, slot, rawID, hsckUA, host+"/", "m3u8", "hls"), nil
}

func playResult(u, prov, rawID, ua, referer, format, protocol string) map[string]interface{} {
	hdrs := map[string]interface{}{"User-Agent": ua, "Referer": referer}
	sess := "pilot-" + prov + "-" + rawID
	return map[string]interface{}{
		"url":                u,
		"videoUrl":           u,
		"playUrl":            u,
		"headers":            hdrs,
		"header":             hdrs,
		"referer":            referer,
		"userAgent":          ua,
		"quality":            "HD",
		"actualQuality":      "HD",
		"qualities":          []interface{}{"HD"},
		"availableQualities": []interface{}{"HD"},
		"format":             format,
		"protocol":           protocol,
		"playbackSession":    sess,
		"session":            sess,
		"sessionId":          sess,
		"sourceId":           prov,
		"dramaId":            dramaID(prov, rawID),
		"episodeId":          rawID,
		"route":              "正片",
		"routes":             []interface{}{map[string]interface{}{"name": "正片", "route": "正片", "url": u}},
		"routeIndex":         0,
		"routeCount":         1,
	}
}
