package seku

import (
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strings"
)

// ---- 苹果版（i短剧 iOS 包）内置源的移植：XNXX / Pornhub / EPorner / SupJav ----
//
// 来源：iOS 包 STV.app 的源表里明文列着这 8 家（jable / missav 多镜像 /
// hanime1 / supjav / eporner / xvideos / xnxx / pornhub），魔蚁这边已有
// missav（hongguo 槽位的镜像实现），这轮把其余的尽量补齐。
//
// 实测（2026-11-22，出境直连）：
//   xnxx     /best/{page} 每页 36 条；卡片 a.thumb-link → /video-<id>/<slug>，
//            封面 data-src、标题 alt；详情必须带 slug；播放页
//            setVideoHLS('...') 实测拿到 hls.m3u8，兜底 setVideoUrlHigh。
//   pornhub  /video?page=N 每页 22 条；卡片 /view_video.php?viewkey=<key>，
//            封面 data-mediumthumb；详情 mediaDefinitions 里按档位给
//            master.m3u8（1080P/480P/240P 实测都在）。
//   eporner  首页每页 59 条、分页 /{page}/ 与 /cat/{cat}/{page}/ 实测都通；
//            卡片 /video-<id>/<slug>；详情页给出 /dload/<id>/<q>/<file>.mp4，
//            该地址 302 到签名 CDN（签名含请求方 IP，必须由播放器自己取，
//            不能预先缓存）。
//   supjav   直接复用 sites_g2.go 里已成型的那套（页面是 Cloudflare 挑战，
//            出口直连拿不到正文，靠 App 内隐藏浏览器解盾回填票据）。
//            2026-11-22 恢复注册：v56 补丁把 tlsGet 接进票据/上报通路，
//            supjavFetch 断链根因已修（用户 2026-11-22 18:06 点头恢复）。

var (
	xnxxCardRe = regexp.MustCompile(
		`(?s)class="thumb-link" href="/video-(?P<id>[a-z0-9]+)/(?P<slug>[^"]+)".{0,900}?data-src="(?P<cover>[^"]+)"[^>]*alt="(?P<title>[^"]*)"`)
	phCardRe = regexp.MustCompile(
		`(?s)<a href="/view_video\.php\?viewkey=(?P<id>[a-z0-9]+)" title="(?P<title>[^"]*)"(?P<rest>.{0,900}?)data-mediumthumb="(?P<cover>[^"]+)"`)
	epCardRe = regexp.MustCompile(
		`(?s)<a href="/video-(?P<id>[A-Za-z0-9]+)/(?P<slug>[^"]*)"[^>]*><img src="(?P<cover>[^"]+)"[^>]*alt="(?P<title>[^"]*)"`)
)

// splitRawIDS slug 型 rawID 统一是 "<id>~<slug>"。
func splitRawIDS(rawID string) (string, string) {
	if i := strings.Index(rawID, "~"); i > 0 {
		return rawID[:i], rawID[i+1:]
	}
	return rawID, ""
}

func joinRawIDS(id, slug string) string {
	if slug == "" {
		return id
	}
	return id + "~" + slug
}

// ---- XNXX ----

func xnxxImpl() *siteImpl {
	const base = "https://www.xnxx.com"
	headers := func() map[string]string {
		return map[string]string{
			"User-Agent":      z2UA,
			"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
			"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
			"Referer":         base + "/",
		}
	}
	fetch := func(u string) (string, error) {
		body, code, _, err := httpGet(u, headers())
		if err != nil {
			return "", err
		}
		if code != 200 {
			return "", fmt.Errorf("xnxx http %d", code)
		}
		return string(body), nil
	}
	parse := func(slot, catName, htmlText string) []interface{} {
		items := []interface{}{}
		seen := map[string]bool{}
		for _, m := range xnxxCardRe.FindAllStringSubmatch(htmlText, -1) {
			g := namedSubexp(xnxxCardRe, m)
			if g["id"] == "" || seen[g["id"]] {
				continue
			}
			seen[g["id"]] = true
			items = append(items, makeDrama(slot, joinRawIDS(g["id"], g["slug"]),
				cleanText(html.UnescapeString(g["title"])), g["cover"], "", catName, ""))
		}
		return items
	}
	impl := &siteImpl{
		Key: "xnxx", Name: "🔞XNXX", DefaultCat: "best",
		HomeURL: base + "/", Headers: headers,
	}
	impl.Categories = func(slot string) []interface{} {
		return []interface{}{
			categoryObj("best", "最佳"),
			categoryObj("hits", "最热"),
		}
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		if page < 1 {
			page = 1
		}
		path := "best"
		name := "最佳"
		if category == "hits" {
			path, name = "hits", "最热"
		}
		body, err := fetch(fmt.Sprintf("%s/%s/%d", base, path, page))
		if err != nil {
			return nil, 0, false, err
		}
		items := parse(slot, name, body)
		return items, page * 36, len(items) > 0, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		id, slug := splitRawIDS(rawID)
		if slug == "" {
			return nil, fmt.Errorf("xnxx: slug missing")
		}
		body, err := fetch(fmt.Sprintf("%s/video-%s/%s", base, id, slug))
		if err != nil {
			return nil, err
		}
		title := ""
		if m := xvideosTitleRe.FindStringSubmatch(body); m != nil {
			title = cleanText(html.UnescapeString(m[1]))
			for _, sep := range []string{" - XNXX", " - Xnxx"} {
				if i := strings.LastIndex(title, sep); i > 0 {
					title = strings.TrimSpace(title[:i])
				}
			}
		}
		cover := ""
		if m := xvideosOGRe.FindStringSubmatch(body); m != nil {
			cover = m[1]
		}
		remark := "无源"
		if xvideosHLSRe.MatchString(body) || xvideosMP4Re.MatchString(body) {
			remark = "直连"
		}
		d := makeDrama(slot, rawID, title, cover, remark, "", "")
		d["chapters"] = singleChapter(slot, rawID)
		return d, nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		id, slug := splitRawIDS(rawID)
		if slug == "" {
			return nil, fmt.Errorf("xnxx: slug missing")
		}
		body, err := fetch(fmt.Sprintf("%s/video-%s/%s", base, id, slug))
		if err != nil {
			return nil, err
		}
		if m := xvideosHLSRe.FindStringSubmatch(body); m != nil {
			return playResult(m[1], slot, rawID, z2UA, base+"/", "m3u8", "hls"), nil
		}
		if m := xvideosMP4Re.FindStringSubmatch(body); m != nil {
			return playResult(m[1], slot, rawID, z2UA, base+"/", "mp4", "file"), nil
		}
		return nil, fmt.Errorf("xnxx no play url")
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		body, err := fetch(base + "/?k=" + url.QueryEscape(kw))
		if err != nil {
			return nil, err
		}
		return parse(slot, "搜索", body), nil
	}
	return impl
}

// ---- Pornhub ----

var (
	phAnchorRe    = regexp.MustCompile(`href="/view_video\.php\?viewkey=([a-z0-9]+)"`)
	phThumbRe     = regexp.MustCompile(`data-mediumthumb="([^"]+)"`)
	phTitleAttrRe = regexp.MustCompile(`title="([^"]{4,200})"`)
	phHLSRe       = regexp.MustCompile(`"format"\s*:\s*"hls"\s*,\s*"videoUrl"\s*:\s*"([^"]+)"`)
	phMP4Re       = regexp.MustCompile(`"format"\s*:\s*"mp4"\s*,\s*"videoUrl"\s*:\s*"([^"]+)"`)
)

func pornhubImpl() *siteImpl {
	const base = "https://www.pornhub.com"
	headers := func() map[string]string {
		return map[string]string{
			"User-Agent":      z2UA,
			"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
			"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
			"Referer":         base + "/",
		}
	}
	fetch := func(u string) (string, error) {
		// 标准库客户端的 TLS 指纹在 Pornhub 边缘节点会被判 403（curl
		// 同 UA 是 200），这里走伪装指纹的客户端。
		body, code, _, err := tlsGet(u, headers())
		if err != nil {
			// 首页首取常耗时 30 秒上下（本机出口实测 38.5 秒），撞上
			// tlsGet 30 秒单次超时；连接预热后重试通常 1 秒内通，
			// 只重试一次，仍失败即报出（Dart 侧 70 秒上限内）。
			body, code, _, err = tlsGet(u, headers())
		}
		if err != nil {
			return "", err
		}
		if code != 200 {
			return "", fmt.Errorf("pornhub http %d", code)
		}
		return string(body), nil
	}
	// 首页卡片里 <a> 与封面/标题的距离不固定（实测 134 个 viewkey 只有
	// 63 个贴着 data-mediumthumb），所以先定位锚点，再在窗口里就近取。
	parse := func(slot, catName, htmlText string) []interface{} {
		items := []interface{}{}
		seen := map[string]bool{}
		for _, loc := range phAnchorRe.FindAllStringSubmatchIndex(htmlText, -1) {
			id := htmlText[loc[2]:loc[3]]
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			start := loc[0] - 200
			if start < 0 {
				start = 0
			}
			end := loc[1] + 1500
			if end > len(htmlText) {
				end = len(htmlText)
			}
			win := htmlText[start:end]
			cover, title := "", ""
			if m := phThumbRe.FindStringSubmatch(win); m != nil {
				cover = m[1]
			}
			if m := phTitleAttrRe.FindStringSubmatch(win); m != nil {
				title = cleanText(html.UnescapeString(m[1]))
			}
			if title == "" {
				continue
			}
			items = append(items, makeDrama(slot, id, title, cover, "", catName, ""))
		}
		return items
	}
	impl := &siteImpl{
		Key: "pornhub", Name: "🔞Pornhub", DefaultCat: "hot",
		HomeURL: base + "/", Headers: headers,
	}
	impl.Categories = func(slot string) []interface{} {
		return []interface{}{
			categoryObj("hot", "最热"),
			categoryObj("new", "最新"),
		}
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		if page < 1 {
			page = 1
		}
		// /video?page=N 从机房出口实测 403（被边缘节点挡），首页与
		// /video?o=cm 可通；首页就是最热流，翻页退回首页重新抓。
		u := base + "/"
		name := "最热"
		if category == "new" {
			u = base + "/video?o=cm"
			name = "最新"
		}
		if page > 1 {
			// 2026-11-22 修：旧写法先拼 "&page=N" 再补 "?page=N"，最热
			// 分页 URL 会畸形成 "/&page=2?page=2"；按有无问号分支拼。
			if strings.Contains(u, "?") {
				u = fmt.Sprintf("%s&page=%d", u, page)
			} else {
				u = fmt.Sprintf("%s?page=%d", u, page)
			}
		}
		body, err := fetch(u)
		if err != nil {
			return nil, 0, false, err
		}
		items := parse(slot, name, body)
		return items, page * 22, len(items) > 0, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		body, err := fetch(base + "/view_video.php?viewkey=" + rawID)
		if err != nil {
			return nil, err
		}
		title := ""
		if m := xvideosTitleRe.FindStringSubmatch(body); m != nil {
			title = cleanText(m[1])
			for _, sep := range []string{" | Pornhub", " - Pornhub.com"} {
				if i := strings.LastIndex(title, sep); i > 0 {
					title = strings.TrimSpace(title[:i])
				}
			}
		}
		cover := ""
		if m := xvideosOGRe.FindStringSubmatch(body); m != nil {
			cover = m[1]
		}
		remark := "无源"
		if phHLSRe.MatchString(body) || phMP4Re.MatchString(body) {
			remark = "直连"
		}
		d := makeDrama(slot, rawID, title, cover, remark, "", "")
		d["chapters"] = singleChapter(slot, rawID)
		return d, nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		body, err := fetch(base + "/view_video.php?viewkey=" + rawID)
		if err != nil {
			return nil, err
		}
		if m := phHLSRe.FindStringSubmatch(body); m != nil {
			return playResult(unescapePlay(m[1]), slot, rawID, z2UA, base+"/", "m3u8", "hls"), nil
		}
		if m := phMP4Re.FindStringSubmatch(body); m != nil {
			return playResult(unescapePlay(m[1]), slot, rawID, z2UA, base+"/", "mp4", "file"), nil
		}
		return nil, fmt.Errorf("pornhub no play url")
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		body, err := fetch(base + "/video/search?search=" + url.QueryEscape(kw))
		if err != nil {
			return nil, err
		}
		return parse(slot, "搜索", body), nil
	}
	return impl
}

// ---- EPorner ----

var (
	epDloadRe  = regexp.MustCompile(`(/dload/[A-Za-z0-9]+/\d+/[^"' <>]+\.mp4)`)
	epH1Re     = regexp.MustCompile(`(?s)<h1[^>]*>(.*?)</h1>`)
	epAnchorRe = regexp.MustCompile(`href="/video-([A-Za-z0-9]+)/[^"]*"`)
	epImgSrcRe = regexp.MustCompile(`src="([^"]+)"`)
	epImgAltRe = regexp.MustCompile(`alt="([^"]*)"`)
	epTailJunk = regexp.MustCompile(`\s+(\d+min|\d{3,4}p(\(4K\))?|\d+fps|\s*\d+p)\s*$`)
)

func epornerImpl() *siteImpl {
	const base = "https://www.eporner.com"
	headers := func() map[string]string {
		return map[string]string{
			"User-Agent":      z2UA,
			"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
			"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
			"Referer":         base + "/",
		}
	}
	fetch := func(u string) (string, error) {
		body, code, _, err := httpGet(u, headers())
		if err != nil {
			return "", err
		}
		if code != 200 {
			return "", fmt.Errorf("eporner http %d", code)
		}
		return string(body), nil
	}
	parse := func(slot, catName, htmlText string) []interface{} {
		items := []interface{}{}
		seen := map[string]bool{}
		locs := epAnchorRe.FindAllStringSubmatchIndex(htmlText, -1)
		for _, loc := range locs {
			id := htmlText[loc[2]:loc[3]]
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			end := loc[1] + 600
			if end > len(htmlText) {
				end = len(htmlText)
			}
			tail := htmlText[loc[0]:end]
			cover, title := "", ""
			if m := epImgSrcRe.FindStringSubmatch(tail); m != nil {
				cover = m[1]
			}
			if m := epImgAltRe.FindStringSubmatch(tail); m != nil {
				title = cleanText(html.UnescapeString(m[1]))
			}
			if title == "" {
				continue
			}
			items = append(items, makeDrama(slot, id, title, cover, "", catName, ""))
		}
		return items
	}
	cats := []htmlCat{
		{ID: "", Name: "最新"},
		{ID: "cat/asian", Name: "亚洲"},
		{ID: "cat/japanese", Name: "日本"},
		{ID: "cat/amateur", Name: "素人"},
		{ID: "cat/milf", Name: "人妻"},
		{ID: "cat/anal", Name: "肛交"},
		{ID: "cat/creampie", Name: "中出"},
		{ID: "cat/lesbian", Name: "女同"},
		{ID: "cat/big-tits", Name: "巨乳"},
		{ID: "cat/teen", Name: "少女"},
		{ID: "cat/4k-porn", Name: "4K"},
	}
	impl := &siteImpl{
		Key: "eporner", Name: "🔞EPorner", DefaultCat: "",
		HomeURL: base + "/", Headers: headers,
	}
	impl.Categories = func(slot string) []interface{} {
		out := []interface{}{}
		for _, c := range cats {
			out = append(out, categoryObj(c.ID, c.Name))
		}
		return out
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		if page < 1 {
			page = 1
		}
		name := "最新"
		prefix := ""
		for _, c := range cats {
			if c.ID == category {
				name = c.Name
				prefix = c.ID
				break
			}
		}
		var u string
		if prefix == "" {
			u = fmt.Sprintf("%s/%d/", base, page)
		} else {
			u = fmt.Sprintf("%s/%s/%d/", base, prefix, page)
		}
		body, err := fetch(u)
		if err != nil {
			return nil, 0, false, err
		}
		items := parse(slot, name, body)
		return items, page * 59, len(items) > 0, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		body, err := fetch(fmt.Sprintf("%s/video-%s/", base, rawID))
		if err != nil {
			return nil, err
		}
		title := ""
		if m := epH1Re.FindStringSubmatch(body); m != nil {
			title = cleanText(xvideosTagRe.ReplaceAllString(m[1], " "))
			for i := 0; i < 6; i++ {
				trimmed := strings.TrimSpace(epTailJunk.ReplaceAllString(title, ""))
				if trimmed == title {
					break
				}
				title = trimmed
			}
		}
		cover := ""
		if m := xvideosOGRe.FindStringSubmatch(body); m != nil {
			cover = m[1]
		}
		remark := "无源"
		if epDloadRe.MatchString(body) {
			remark = "直连"
		}
		d := makeDrama(slot, rawID, title, cover, remark, "", "")
		d["chapters"] = singleChapter(slot, rawID)
		return d, nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		body, err := fetch(fmt.Sprintf("%s/video-%s/", base, rawID))
		if err != nil {
			return nil, err
		}
		if pick := epornerBestDload(body); pick != "" {
			// /dload/... 会 302 到签名 CDN，签名绑定请求方 IP，
			// 只能让播放器自己跳，不能在这儿跟。
			return playResult(base+pick, slot, rawID, z2UA, base+"/", "mp4", "file"), nil
		}
		return nil, fmt.Errorf("eporner no play url")
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		body, err := fetch(base + "/search/" + url.PathEscape(kw) + "/")
		if err != nil {
			return nil, err
		}
		return parse(slot, "搜索", body), nil
	}
	return impl
}

// epornerBestDload 从详情页挑一档可直接播的下载地址：优先非 av1
// （部分机型 av1 解不了），再优先高分辨率。
func epornerBestDload(body string) string {
	picks := epDloadRe.FindAllString(body, -1)
	if len(picks) == 0 {
		return ""
	}
	type cand struct {
		path string
		q    int
		av1  bool
	}
	list := make([]cand, 0, len(picks))
	for _, p := range picks {
		q := 0
		parts := strings.Split(p, "/")
		if len(parts) > 3 {
			fmt.Sscanf(parts[3], "%d", &q)
		}
		list = append(list, cand{path: p, q: q, av1: strings.Contains(p, "av1")})
	}
	best := list[0]
	for _, c := range list {
		if best.av1 && !c.av1 {
			best = c
			continue
		}
		if best.av1 == c.av1 && c.q > best.q {
			best = c
		}
	}
	return best.path
}

// singleChapter 单集作品的章节表。
func singleChapter(slot, rawID string) []interface{} {
	return []interface{}{
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
}

func init() {
	registerSite("xnxx", xnxxImpl(), "XNXX")
	registerSite("pornhub", pornhubImpl(), "Pornhub")
	registerSite("eporner", epornerImpl(), "EPorner")
	registerSite("xvideos", xvideosImpl(), "XVideos")
	registerSite("supjav", &siteImpl{
		Key: "supjav", Name: "🔞SupJav", DefaultCat: "home",
		HomeURL:    supjavHost + "/",
		Categories: supjavCategories,
		Catalog:    supjavCatalog,
		Detail:     supjavDetail,
		Resolve:    supjavResolve,
		Search:     supjavSearch,
		Headers:    func() map[string]string { return supjavHeaders("") },
	}, "SupJav")
}
