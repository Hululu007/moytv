package seku

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const mjvHost = "https://mjv011.com"

const mjvUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

var mjvMu sync.Mutex
var mjvClient *http.Client

func mjvHTTPClient() *http.Client {
	mjvMu.Lock()
	defer mjvMu.Unlock()
	if mjvClient != nil {
		return mjvClient
	}
	jar, _ := cookiejar.New(nil)
	mjvClient = &http.Client{Jar: jar, Timeout: 25 * time.Second}
	return mjvClient
}

func mjvGet(rawurl string) (string, error) {
	client := mjvHTTPClient()
	do := func(u string) (string, int, error) {
		req, err := http.NewRequest("GET", u, nil)
		if err != nil {
			return "", 0, err
		}
		req.Header.Set("User-Agent", mjvUA)
		req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
		req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
		req.Header.Set("Referer", mjvHost+"/")
		resp, err := client.Do(req)
		if err != nil {
			return "", 0, err
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if err != nil {
			return "", resp.StatusCode, err
		}
		return string(body), resp.StatusCode, nil
	}
	text, code, err := do(rawurl)
	if err != nil || code != 200 {
		if err == nil {
			err = fmt.Errorf("mjv011 http %d", code)
		}
		return "", err
	}
	if len(text) < 3000 && (strings.Contains(text, "同意(enter)") || strings.Contains(text, "IamOverEighteenYearsOld")) {
		_, _, _ = do(mjvHost + "/zh/chinese_IamOverEighteenYearsOld/19/index.html")
		text, code, err = do(rawurl)
		if err != nil || code != 200 {
			if err == nil {
				err = fmt.Errorf("mjv011 http %d", code)
			}
			return "", err
		}
	}
	return text, nil
}

func mjvIsNovel(id string) bool { return strings.HasPrefix(id, "novel") }

func mjvIsImage(id string) bool {
	for _, p := range []string{"18H", "doujin", "cg", "cwp"} {
		if strings.HasPrefix(id, p) {
			return true
		}
	}
	return false
}

var mjvCats = []struct{ id, name string }{
	{"chinese_random/all", "中文字幕"},
	{"censored_random/all", "有码"},
	{"uncensored_random/all", "无码"},
	{"amateurjav_random/all", "素人"},
	{"reducing-mosaic_random/all", "无码破解"},
	{"animation_random/all", "H动画"},
	{"CensoredAnimation_random/all", "H有码动画"},
	{"UncensoredAnimation_random/all", "H无码动画"},
	{"tdAnimation_random/all", "H_3D动画"},
	{"dt_random/all", "国产自拍"},
	{"18H_random/all", "18H漫画"},
	{"doujin_random/all", "18H短篇同人"},
	{"cg_random/all", "写真图集"},
	{"cwp_random/all", "国产写真"},
	{"novel_random/all", "小说"},
	{"content_news/all", "每日更新"},
}

func mjvCategories(slot string) []interface{} {
	out := []interface{}{}
	for _, c := range mjvCats {
		out = append(out, categoryObj(c.id, c.name))
	}
	return out
}

func mjvHeaders() map[string]string {
	return map[string]string{"User-Agent": mjvUA, "Referer": mjvHost + "/"}
}

var mjvPostRe = regexp.MustCompile(`(?s)<div class='post[^']*'>.*?<a[^>]*href="([^"]+)"[^>]*>.*?<img[^>]*src='([^']+)'[^>]*>.*?<h3[^>]*><a[^>]*>([^<]+)</a></h3>(?:\s*<div class='meta'>([^<]*)</div>)?`)
var mjvContentRe = regexp.MustCompile(`/([^/]+)_content/(\d+)/([^/]+)\.html`)

func mjvParsePosts(text string) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, m := range mjvPostRe.FindAllStringSubmatch(text, -1) {
		href, pic, title, date := m[1], m[2], strings.TrimSpace(g6StripTags(m[3])), strings.TrimSpace(m[4])
		href = strings.TrimPrefix(href, mjvHost)
		if !strings.HasPrefix(href, "/") {
			continue
		}
		mm := mjvContentRe.FindStringSubmatch(href)
		if mm == nil {
			continue
		}
		raw := mm[1] + "#" + mm[2] + "#" + mm[3]
		if seen[raw] {
			continue
		}
		seen[raw] = true
		out = append(out, makeDrama("mjv011", raw, title, pic, date, "", ""))
	}
	return out
}

func mjvBaseTid(tid string) string {
	base := tid
	base = strings.TrimSuffix(base, "_random/all")
	base = strings.TrimSuffix(base, "_random")
	base = strings.TrimSuffix(base, "_list/all")
	return base
}

func mjvCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	if category == "" {
		category = "chinese_random/all"
	}
	if category == "home" {
		text, err := mjvGet(mjvHost + "/zh/chinese_IamOverEighteenYearsOld/19/index.html")
		if err != nil {
			return nil, 0, false, err
		}
		items := mjvParsePosts(text)
		per := 20
		start := (page - 1) * per
		if start >= len(items) {
			return []interface{}{}, len(items), false, nil
		}
		end := start + per
		if end > len(items) {
			end = len(items)
		}
		return items[start:end], len(items), end < len(items), nil
	}
	if category == "content_news/all" {
		today := time.Now().Format("2006-01-02")
		text, err := mjvGet(mjvHost + "/zh/content_news/all/" + today + ".html")
		if err != nil {
			return nil, 0, false, err
		}
		items := mjvParsePosts(text)
		return items, len(items), false, nil
	}
	base := mjvBaseTid(category)
	candidates := []string{}
	if page == 1 {
		candidates = append(candidates, mjvHost+"/zh/"+base+"_list/all/index.html", mjvHost+"/zh/"+base+"_random/all/index.html")
	}
	candidates = append(candidates,
		mjvHost+"/zh/"+base+"_list/all/"+strconv.Itoa(page)+".html",
		mjvHost+"/zh/"+base+"_list/index_"+strconv.Itoa(page)+".html",
		mjvHost+"/zh/"+base+"/"+strconv.Itoa(page)+".html",
		mjvHost+"/zh/"+base+"/page/"+strconv.Itoa(page)+".html",
		mjvHost+"/zh/"+base+"_random/all/"+strconv.Itoa(page)+".html",
	)
	for _, u := range candidates {
		text, err := mjvGet(u)
		if err != nil || text == "" {
			continue
		}
		items := mjvParsePosts(text)
		if len(items) > 0 {
			return items, page*len(items) + 1, true, nil
		}
	}
	return []interface{}{}, 0, false, nil
}

func mjvSearch(slot, kw string) ([]interface{}, error) {
	kw = strings.TrimSpace(kw)
	if kw == "" {
		return []interface{}{}, nil
	}
	text, err := mjvGet(mjvHost + "/zh/chinese_search/all/" + url.PathEscape(kw) + "/1.html")
	if err != nil {
		return nil, err
	}
	return mjvParsePosts(text), nil
}

func mjvTitle(text string) string {
	if m := regexp.MustCompile(`(?s)<h1[^>]*>(.*?)</h1>`).FindStringSubmatch(text); m != nil {
		return strings.TrimSpace(g6StripTags(m[1]))
	}
	if m := regexp.MustCompile(`<title>([^<]+)</title>`).FindStringSubmatch(text); m != nil {
		return strings.TrimSpace(m[1])
	}
	return ""
}

func mjvCover(text string) string {
	if m := regexp.MustCompile(`"thumbnailUrl"\s*:\s*"([^"]+)"`).FindStringSubmatch(text); m != nil {
		return m[1]
	}
	if m := regexp.MustCompile(`<meta[^>]*property="og:image"[^>]*content="([^"]+)"`).FindStringSubmatch(text); m != nil {
		return m[1]
	}
	return ""
}

func mjvChapter(slot, parentRaw, epRaw, title string, idx int) map[string]interface{} {
	return map[string]interface{}{
		"episodeId": epRaw,
		"id":        dramaID(slot, parentRaw+":"+epRaw),
		"dramaId":   dramaID(slot, parentRaw),
		"sourceId":  slot,
		"source":    slot,
		"title":     title,
		"name":      title,
		"index":     idx,
		"episode":   idx,
		"url":       "",
		"videoUrl":  epRaw,
		"mediaSize": 0,
	}
}

func mjvDetail(slot, rawID string) (map[string]interface{}, error) {
	parts := strings.SplitN(rawID, "#", 3)
	if len(parts) != 3 {
		return nil, fmt.Errorf("mjv011 bad id")
	}
	ctype, num, slug := parts[0], parts[1], parts[2]
	text, err := mjvGet(mjvHost + "/zh/" + ctype + "_content/" + num + "/" + slug + ".html")
	if err != nil {
		return nil, err
	}
	title := mjvTitle(text)
	cover := mjvCover(text)
	d := makeDrama(slot, rawID, title, cover, "", "", "")
	if mjvIsNovel(ctype) {
		content := ""
		if m := regexp.MustCompile(`(?s)id=['"]novel_content_txtsize['"][^>]*>(.*?)</div>`).FindStringSubmatch(text); m != nil {
			content = g6StripTags(m[1])
		}
		if content == "" {
			if m := regexp.MustCompile(`(?s)<span class='content_18h_wpcg'>(.*?)</span>\s*<div class='contents'`).FindStringSubmatch(text); m != nil {
				content = g6StripTags(m[1])
			}
		}
		if len([]rune(content)) > 3000 {
			content = string([]rune(content)[:3000]) + "..."
		}
		payload, _ := json.Marshal(map[string]string{"title": title, "content": content})
		ep := "novel://" + string(payload)
		ch := []interface{}{mjvChapter(slot, rawID, ep, "阅读", 1)}
		d["chapters"] = ch
		d["episodeList"] = ch
		d["episodes"] = 1
		d["episodeCount"] = 1
		d["chapterCount"] = 1
		d["totalEpisode"] = 1
		d["totalEpisodes"] = 1
		return d, nil
	}
	if mjvIsImage(ctype) {
		imgs := mjvImageURLs(text)
		if len(imgs) == 0 {
			return nil, fmt.Errorf("mjv011 no images")
		}
		ep := "pics://" + strings.Join(imgs, "&&")
		ch := []interface{}{mjvChapter(slot, rawID, ep, "查看", 1)}
		d["chapters"] = ch
		d["episodeList"] = ch
		d["episodes"] = 1
		d["episodeCount"] = 1
		d["chapterCount"] = 1
		d["totalEpisode"] = 1
		d["totalEpisodes"] = 1
		d["remark"] = fmt.Sprintf("共 %d 张图片", len(imgs))
		d["remarks"] = d["remark"]
		d["vod_remarks"] = d["remark"]
		return d, nil
	}
	items, err := mjvVideoItems(text, num, slug)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		ch := []interface{}{mjvChapter(slot, rawID, "video|"+rawID, "正片", 1)}
		d["chapters"] = ch
		d["episodeList"] = ch
		d["episodes"] = 1
		d["episodeCount"] = 1
		d["chapterCount"] = 1
		d["totalEpisode"] = 1
		d["totalEpisodes"] = 1
		return d, nil
	}
	ch := []interface{}{}
	for i, it := range items {
		ch = append(ch, mjvChapter(slot, rawID, it.ep, it.label, i+1))
	}
	d["chapters"] = ch
	d["episodeList"] = ch
	d["episodes"] = len(ch)
	d["episodeCount"] = len(ch)
	d["chapterCount"] = len(ch)
	d["totalEpisode"] = len(ch)
	d["totalEpisodes"] = len(ch)
	return d, nil
}

func mjvImageURLs(text string) []string {
	seen := map[string]bool{}
	out := []string{}
	add := func(u string) {
		u = strings.TrimSpace(u)
		if u == "" || seen[u] {
			return
		}
		seen[u] = true
		out = append(out, u)
	}
	type indexed struct {
		n int
		u string
	}
	list := []indexed{}
	for _, m := range regexp.MustCompile(`Large_cgurl\[(\d+)\]\s*=\s*"([^"]+)"`).FindAllStringSubmatch(text, -1) {
		n, _ := strconv.Atoi(m[1])
		list = append(list, indexed{n, m[2]})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].n < list[j].n })
	seenIdx := map[int]bool{}
	for _, it := range list {
		if it.n == 0 || seenIdx[it.n] {
			continue
		}
		seenIdx[it.n] = true
		add(it.u)
	}
	if len(out) > 0 {
		return out
	}
	for _, m := range regexp.MustCompile(`(?i)src=['"]([^'"]*eemmhh02\.com/[^'"]+\.(?:jpg|png|webp))['"]`).FindAllStringSubmatch(text, -1) {
		add(m[1])
	}
	return out
}

type mjvVideoItem struct {
	ep    string
	label string
}

func mjvVideoItems(text, num, slug string) ([]mjvVideoItem, error) {
	xorS := regexp.MustCompile(`hadeedg252=(\d+)`).FindStringSubmatch(text)
	baseS := regexp.MustCompile(`hcdeedg252=(\d+)`).FindStringSubmatch(text)
	keyS := regexp.MustCompile(`var argdeqweqweqwe = '([^']+)'`).FindStringSubmatch(text)
	ivS := regexp.MustCompile(`var hdddedg252 = '([^']+)'`).FindStringSubmatch(text)
	if xorS == nil || baseS == nil || keyS == nil || ivS == nil {
		return nil, nil
	}
	xorKey, _ := strconv.Atoi(xorS[1])
	base, _ := strconv.Atoi(baseS[1])
	mm := regexp.MustCompile(`(?s)mvarr\['10_1'\]=(\[.*?\]);`).FindStringSubmatch(text)
	if mm == nil {
		return nil, nil
	}
	rows := regexp.MustCompile(`\['([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)'\]`).FindAllStringSubmatch(mm[1], -1)
	out := []mjvVideoItem{}
	for _, r := range rows {
		if len(r) < 7 || r[2] == "" || r[4] == "" {
			continue
		}
		pid := mjvDecryptID(r[2], xorKey, base, keyS[1], ivS[1])
		if pid == "" {
			continue
		}
		for _, res := range []struct{ code, label string }{{"480", "480P"}, {"720", "720P"}, {"1080", "1080P"}} {
			out = append(out, mjvVideoItem{ep: num + "|" + slug + "|" + pid + "|" + res.code, label: res.label})
		}
	}
	return out, nil
}

func mjvDecryptID(enc string, xorKey, base int, aesKey, aesIV string) string {
	sep := string(rune(base + 97))
	parts := strings.Split(enc, sep)
	var chars []rune
	for _, p := range parts {
		if p == "" {
			continue
		}
		n, err := strconv.ParseInt(p, base, 64)
		if err != nil {
			return ""
		}
		chars = append(chars, rune(n^int64(xorKey)))
	}
	data, err := base64.StdEncoding.DecodeString(string(chars))
	if err != nil {
		return ""
	}
	plain := mjvAESCBCDecrypt(data, []byte(aesKey), []byte(aesIV))
	if plain == nil {
		return ""
	}
	return string(plain)
}

func mjvAESCBCDecrypt(data, key, iv []byte) []byte {
	if len(data) == 0 || len(data)%aes.BlockSize != 0 {
		return nil
	}
	block, err := aes.NewCipher(key)
	if err != nil || len(iv) != aes.BlockSize {
		return nil
	}
	out := make([]byte, len(data))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, data)
	if len(out) == 0 {
		return nil
	}
	pad := int(out[len(out)-1])
	if pad < 1 || pad > aes.BlockSize || pad > len(out) {
		return out
	}
	return out[:len(out)-pad]
}

func mjvResolve(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "novel://") {
		return map[string]interface{}{"url": rawID, "videoUrl": rawID, "playUrl": rawID, "headers": mjvHeaders(), "format": "text", "protocol": "novel"}, nil
	}
	if strings.HasPrefix(rawID, "pics://") {
		return map[string]interface{}{"url": rawID, "videoUrl": rawID, "playUrl": rawID, "headers": mjvHeaders(), "format": "image", "protocol": "pics"}, nil
	}
	if strings.HasPrefix(rawID, "video|") {
		parts := strings.SplitN(strings.TrimPrefix(rawID, "video|"), "#", 3)
		if len(parts) != 3 {
			return nil, fmt.Errorf("mjv011 bad video id")
		}
		page := mjvHost + "/zh/" + parts[0] + "_content/" + parts[1] + "/" + parts[2] + ".html"
		res := playResult(page, slot, rawID, mjvUA, mjvHost+"/", "html", "page")
		res["parse"] = float64(1)
		res["jx"] = float64(1)
		return res, nil
	}
	parts := strings.SplitN(rawID, "|", 4)
	if len(parts) != 4 {
		if strings.Contains(rawID, "|") {
			return nil, fmt.Errorf("mjv011 bad video id")
		}
		detailParts := strings.SplitN(rawID, "#", 3)
		if len(detailParts) != 3 {
			return nil, fmt.Errorf("mjv011 bad video id")
		}
		return nil, fmt.Errorf("mjv011 video player needs JS player parsing, not connected")
	}
	num, slug, pid, res := parts[0], parts[1], parts[2], parts[3]
	text, err := mjvGet(mjvHost + "/js/player/play.php?numresolution=" + res + "&lo=on&id=" + pid)
	if err != nil {
		return nil, err
	}
	_ = num
	_ = slug
	m3u8 := ""
	if mm := regexp.MustCompile(`(?s)videoSources\s*=\s*(\[.*?\]);`).FindStringSubmatch(text); mm != nil {
		type src struct {
			u string
			s int
		}
		srcs := []src{}
		for _, m := range regexp.MustCompile(`src:\s*'([^']+)'[^}]*?size:\s*(\d+)`).FindAllStringSubmatch(mm[1], -1) {
			n, _ := strconv.Atoi(m[2])
			srcs = append(srcs, src{m[1], n})
		}
		target, _ := strconv.Atoi(res)
		for _, s := range srcs {
			if s.s == target {
				m3u8 = s.u
				break
			}
		}
		if m3u8 == "" && len(srcs) > 0 {
			m3u8 = srcs[0].u
		}
	}
	if m3u8 == "" {
		if mm := regexp.MustCompile(`https?://[^\s"<>']+?\.m3u8`).FindStringSubmatch(text); mm != nil {
			m3u8 = mm[0]
		}
	}
	if m3u8 == "" {
		return nil, fmt.Errorf("mjv011 no m3u8")
	}
	return playResult(m3u8, slot, rawID, mjvUA, mjvHost+"/", "m3u8", "hls"), nil
}

func init() {
	registerSite("mjv011", &siteImpl{
		Key: "mjv011", Name: "🔞mjv011", DefaultCat: "chinese_random/all", HomeURL: mjvHost + "/zh/",
		Categories: mjvCategories,
		Catalog:    mjvCatalog,
		Detail:     mjvDetail,
		Resolve:    mjvResolve,
		Search:     mjvSearch,
		Headers:    mjvHeaders,
	}, "mjv011")
}
