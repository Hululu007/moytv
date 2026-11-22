package seku

import (
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strings"
)

// ---- XVIDEOS www.xvideos.com ----
//
// 实测（2026-11-22，出境直连）：
//   - 列表 /new/{page}：卡片是 <div id="video_<eid">，封面在 img 的
//     data-src（首图是 blank.gif 占位，必须取 data-src），标题在
//     <p class="title"><a title="...">。
//   - 详情必须带 slug：/video.<eid>/<slug>；只给 eid 会 404（实测）
//     → 列表里把 eid 与 slug 一起存成 rawID（eid~slug）。
//   - 播放：html5player.setVideoHLS('...') 是带签名的 m3u8，实测取回
//     #EXTM3U 且含 480p/720p 子清单；兜底 setVideoUrlHigh。
//   - 分类 /c/<name>-<id>/<page>；搜索 /?k=<kw>。

const xvideosBase = "https://www.xvideos.com"

var xvideosCats = []htmlCat{
	{ID: "new", Name: "最新"},
	{ID: "best", Name: "最佳"},
	{ID: "c/AI-239", Name: "AI"},
	{ID: "c/Amateur-65", Name: "素人"},
	{ID: "c/Asian_Woman-32", Name: "亚洲"},
	{ID: "c/Japanese-32", Name: "日本"},
	{ID: "c/Anal-12", Name: "肛交"},
	{ID: "c/Big_Tits-23", Name: "巨乳"},
	{ID: "c/Blowjob-15", Name: "口交"},
	{ID: "c/Creampie-17", Name: "中出"},
	{ID: "c/MILF-19", Name: "人妻"},
	{ID: "c/Teen-18", Name: "少女"},
	{ID: "c/Lesbian-26", Name: "女同"},
	{ID: "c/Cosplay-241", Name: "角色扮演"},
	{ID: "c/ASMR-229", Name: "ASMR"},
}

var (
	xvideosCardRe = regexp.MustCompile(
		`(?s)<div id="video_(?P<eid>[a-z0-9]+)".{0,900}?data-src="(?P<cover>[^"]+)".{0,900}?<p class="title"><a href="/video\.[^/]+/(?P<slug>[^"]+)" title="(?P<title>[^"]*)"`)
	xvideosHLSRe   = regexp.MustCompile(`setVideoHLS\('([^']+)'\)`)
	xvideosMP4Re   = regexp.MustCompile(`setVideoUrlHigh\('([^']+)'\)`)
	xvideosOGRe    = regexp.MustCompile(`property="og:image"[^>]*content="([^"]+)"`)
	xvideosTitleRe = regexp.MustCompile(`(?s)<title>(.*?)</title>`)
	xvideosDescRe  = regexp.MustCompile(`(?s)<div id="video-description"[^>]*>(.*?)</div>`)
	xvideosTagRe   = regexp.MustCompile(`<[^>]+>`)
)

func xvideosHeaders() map[string]string {
	return map[string]string{
		"User-Agent":      z2UA,
		"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
		"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
		"Referer":         xvideosBase + "/",
	}
}

func xvideosFetch(rawurl string) (string, error) {
	body, code, _, err := httpGet(rawurl, xvideosHeaders())
	if err != nil {
		return "", err
	}
	if code != 200 {
		return "", fmt.Errorf("xvideos http %d", code)
	}
	return string(body), nil
}

// xvideosListURL 把分类 id 翻成列表地址。
func xvideosListURL(cat string, page int) string {
	if page < 1 {
		page = 1
	}
	if cat == "" || cat == "new" {
		return fmt.Sprintf("%s/new/%d", xvideosBase, page)
	}
	if cat == "best" {
		return fmt.Sprintf("%s/best/%d", xvideosBase, page)
	}
	return fmt.Sprintf("%s/%s/%d", xvideosBase, cat, page)
}

// xvideosSplitID rawID 形如 "<eid>~<slug>"。
func xvideosSplitID(rawID string) (string, string) {
	if i := strings.Index(rawID, "~"); i > 0 {
		return rawID[:i], rawID[i+1:]
	}
	return rawID, ""
}

func xvideosParseList(slot, catName, body string) []interface{} {
	items := []interface{}{}
	seen := map[string]bool{}
	for _, m := range xvideosCardRe.FindAllStringSubmatch(body, -1) {
		g := namedSubexp(xvideosCardRe, m)
		eid, slug := g["eid"], g["slug"]
		if eid == "" || seen[eid] {
			continue
		}
		seen[eid] = true
		id := eid + "~" + slug
		items = append(items, makeDrama(
			slot, id,
			cleanText(html.UnescapeString(g["title"])),
			g["cover"], "", catName, ""))
	}
	return items
}

func xvideosDetailBody(rawID string) (string, string, error) {
	eid, slug := xvideosSplitID(rawID)
	if slug == "" {
		return "", "", fmt.Errorf("xvideos: slug missing for %s", eid)
	}
	body, err := xvideosFetch(fmt.Sprintf("%s/video.%s/%s", xvideosBase, eid, slug))
	return body, eid, err
}

func xvideosImpl() *siteImpl {
	impl := &siteImpl{
		Key: "xvideos", Name: "🔞XVideos", DefaultCat: "new",
		HomeURL: xvideosBase + "/",
		Headers: xvideosHeaders,
	}
	impl.Categories = func(slot string) []interface{} {
		out := []interface{}{}
		for _, c := range xvideosCats {
			out = append(out, categoryObj(c.ID, c.Name))
		}
		return out
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		cat := category
		if cat == "" {
			cat = "new"
		}
		body, err := xvideosFetch(xvideosListURL(cat, page))
		if err != nil {
			return nil, 0, false, err
		}
		name := cat
		for _, c := range xvideosCats {
			if c.ID == cat {
				name = c.Name
				break
			}
		}
		items := xvideosParseList(slot, name, body)
		return items, page * 28, len(items) > 0, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		body, _, err := xvideosDetailBody(rawID)
		if err != nil {
			return nil, err
		}
		title := ""
		if m := xvideosTitleRe.FindStringSubmatch(body); m != nil {
			title = cleanText(m[1])
			if i := strings.LastIndex(title, " - XVIDE"); i > 0 {
				title = strings.TrimSpace(title[:i])
			}
		}
		cover := ""
		if m := xvideosOGRe.FindStringSubmatch(body); m != nil {
			cover = m[1]
		}
		desc := ""
		if m := xvideosDescRe.FindStringSubmatch(body); m != nil {
			desc = cleanText(xvideosTagRe.ReplaceAllString(m[1], " "))
		}
		remark := "无源"
		if xvideosHLSRe.MatchString(body) || xvideosMP4Re.MatchString(body) {
			remark = "直连"
		}
		d := makeDrama(slot, rawID, title, cover, remark, "", desc)
		d["chapters"] = []interface{}{
			map[string]interface{}{
				"episodeId": rawID,
				"id":        dramaID(slot, rawID),
				"dramaId":   dramaID(slot, rawID),
				"sourceId":  slot,
				"source":    slot,
				"title":     "正片",
				"name":      "正片",
				"index":     1,
				"episode":   1,
				"url":       "",
				"videoUrl":  "",
			},
		}
		return d, nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		body, _, err := xvideosDetailBody(rawID)
		if err != nil {
			return nil, err
		}
		if m := xvideosHLSRe.FindStringSubmatch(body); m != nil {
			return playResult(m[1], slot, rawID, z2UA, xvideosBase+"/", "m3u8", "hls"), nil
		}
		if m := xvideosMP4Re.FindStringSubmatch(body); m != nil {
			return playResult(m[1], slot, rawID, z2UA, xvideosBase+"/", "mp4", "file"), nil
		}
		return nil, fmt.Errorf("xvideos no play url")
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		body, err := xvideosFetch(xvideosBase + "/?k=" + url.QueryEscape(kw))
		if err != nil {
			return nil, err
		}
		return xvideosParseList(slot, "搜索", body), nil
	}
	return impl
}
