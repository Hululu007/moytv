package seku

// ---- 123AV (123av.com) — hongguo slot, v4 replacement for MissAV ----
//
// Ported from the user's ZakaTV jar class Zaka123avAmns (config key
// Zaka123av). MissAV was removed from hongguo in v4: the datacenter
// egress is IP-level blocked by Cloudflare (every TLS profile / domain /
// warm-up combination returns the challenge page) and the jar's own
// MissAV class turns out to be a thin client of a private relay
// (missav.ws286.ystv.top) that now answers HTTP 410. The missav*
// functions stay in sites_g2.go, unregistered; see batch notes v4.
//
// Live-verified deviations from the jar (2026-10-23):
//   - The watch page's player payload is a BARE JSON array (the jar's
//     arr() fallback covers it; kept).
//   - Episode embed hosts rotate (e.g. sadie-shop.site). The jar calls
//     {javplayer.cc}/stream?id={hash}, which currently returns 500; the
//     embed host itself answers /stream?id={hash} with the media JSON.
//     Resolve tries the embed host first, then javplayer.cc.
//   - The returned m3u8 refuses bare requests (403) and requires a
//     Referer; the embed page URL is sent (playResult UA+Referer only,
//     which is all the player forwards).

import (
	"encoding/json"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const av123Site = "https://123av.com"
const av123PlayerHost = "https://javplayer.cc"

const av123UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

func av123Headers() map[string]string {
	return map[string]string{
		"User-Agent":      av123UA,
		"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6",
		"Referer":         av123Site + "/",
	}
}

var av123BlockRe = regexp.MustCompile(`(?i)(loli|lolita|underage|child(?:ren)?|kids?|elementary\s*school|primary\s*school|junior\s*high|middle\s*school|未成年|幼女|儿童)`)

var (
	av123CardCoverRe = regexp.MustCompile(`<a class="card__cover"\s+href="([^"]+)"`)
	av123SlugRe      = regexp.MustCompile(`/v/([^/?"]+)`)
	av123CardImgRe   = regexp.MustCompile(`<img class="card__img"\s+src="([^"]*)"`)
	av123CardTitleRe = regexp.MustCompile(`(?s)<h3 class="card__title">\s*<a[^>]*>(.*?)</a>`)
	av123CardDurRe   = regexp.MustCompile(`<span class="card__dur">([^<]*)</span>`)
	av123TitleRe     = regexp.MustCompile(`(?s)<h1 class="watch__title"[^>]*>(.*?)</h1>`)
	av123DocTitleRe  = regexp.MustCompile(`(?s)<title>(.*?)</title>`)
	av123OgImageRe   = regexp.MustCompile(`<meta property="og:image" content="([^"]+)"`)
	av123BgImageRe   = regexp.MustCompile(`background-image:\s*url\('([^']+)'\)`)
	av123InfoRe      = regexp.MustCompile(`(?s)<dl class="watch__info">(.*?)</dl>`)
	av123InfoRowRe   = regexp.MustCompile(`(?s)<div class="watch__info-row">(.*?)</div>`)
	av123DtRe        = regexp.MustCompile(`(?s)<dt>(.*?)</dt>`)
	av123DdRe        = regexp.MustCompile(`(?s)<dd[^>]*>(.*?)</dd>`)
	av123LinkTextRe  = regexp.MustCompile(`(?s)<a[^>]*>(.*?)</a>`)
	av123EpHashRe    = regexp.MustCompile(`/e/([A-Za-z0-9_]+)`)
	av123TagDirRe    = regexp.MustCompile(`href="/en/tags/([^"]+)"[^>]*>\s*([^<]{1,40})<`)
	av123TitleTailRe = regexp.MustCompile(`\s*[—-]\s*123AV\s*$`)
)

var av123DirSpecs = []struct {
	kind, path, re string
}{
	{"genre", "genres", `<a class="gchip"\s+href="/en/genres/([^"]+)"[^>]*>.*?<span class="gchip__name">(.*?)</span>`},
	{"maker", "makers", `<a class="mcard"\s+href="/en/makers/([^"]+)"[^>]*>.*?<span class="mcard__name">(.*?)</span>`},
	{"actress", "actresses", `<a class="actress__name"\s+href="/en/actresses/([^"]+)"[^>]*>(.*?)</a>`},
	{"series", "series", `<a class="srow"\s+href="/en/series/([^"]+)"[^>]*>.*?<span class="srow__name">(.*?)</span>`},
}

var av123DirRe = map[string]*regexp.Regexp{}

func init() {
	for _, s := range av123DirSpecs {
		av123DirRe[s.kind] = regexp.MustCompile("(?s)" + s.re)
	}
}

// ---- fetch ladder: stdlib first, TLS-impersonated on challenge ----

func av123Fetch(rawurl string) (string, error) {
	body, code, _, err := httpGet(rawurl, av123Headers())
	if err == nil && code == 200 && !isChallengePage(string(body)) {
		return string(body), nil
	}
	body2, code2, _, err2 := tlsGet(rawurl, av123Headers())
	if err2 == nil && code2 == 200 && !isChallengePage(string(body2)) {
		return string(body2), nil
	}
	if err != nil {
		return "", err
	}
	return "", fmt.Errorf("123av fetch %s -> %d", rawurl, code)
}

func isChallengePage(text string) bool {
	if len(text) >= 12000 {
		return false
	}
	lower := strings.ToLower(text)
	return strings.Contains(lower, "just a moment") ||
		strings.Contains(lower, "performing security verification") ||
		(strings.Contains(lower, "attention required") && strings.Contains(lower, "cloudflare"))
}

// ---- categories ----

var av123Cats = []struct{ id, name string }{
	{"new", "最新更新"},
	{"recent", "最近添加"},
	{"hot", "热门推荐"},
	{"all", "全部片库"},
	{"censored", "有码"},
	{"uncensored", "无码"},
	{"uncensored-leaked", "无码流出"},
	{"jable", "Jable"},
	{"missav", "MissAV"},
	{"supjav", "SupJAV"},
	{"genre", "类型"},
	{"maker", "厂牌"},
	{"actress", "演员"},
	{"tag", "番号标签"},
	{"series", "系列"},
}

func av123Categories(slot string) []interface{} {
	out := []interface{}{}
	for _, c := range av123Cats {
		out = append(out, categoryObj(c.id, c.name))
	}
	return out
}

func av123IsDirCat(id string) bool {
	switch id {
	case "genre", "maker", "actress", "tag", "series":
		return true
	}
	return false
}

func av123CategoryURL(tid string, pg int) string {
	if tid == "" {
		tid = "new"
	}
	if tid == "all" {
		return av123Site + "/en/all?sort=today&page=" + strconv.Itoa(pg)
	}
	return av123Site + "/en/" + tid + "?page=" + strconv.Itoa(pg)
}

// ---- cards ----

func av123Clean(s string) string {
	s = regexp.MustCompile(`<[^>]+>`).ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	return strings.TrimSpace(strings.Join(strings.Fields(s), " "))
}

// av123Cards parses one list page into works. rawID is the /v/ slug.
func av123Cards(page string) []g2Work {
	works := []g2Work{}
	seen := map[string]bool{}
	chunks := strings.Split(page, `<div class="card"`)
	for _, ch := range chunks[1:] {
		if len(ch) > 6000 {
			ch = ch[:6000]
		}
		m := av123CardCoverRe.FindStringSubmatch(ch)
		if m == nil {
			continue
		}
		sm := av123SlugRe.FindStringSubmatch(m[1])
		if sm == nil {
			continue
		}
		slug := sm[1]
		if seen[slug] {
			continue
		}
		seen[slug] = true
		title := ""
		if tm := av123CardTitleRe.FindStringSubmatch(ch); tm != nil {
			title = av123Clean(tm[1])
		}
		if title == "" {
			title = strings.ToUpper(slug)
		}
		if av123BlockRe.MatchString(title) {
			continue
		}
		cover := ""
		if im := av123CardImgRe.FindStringSubmatch(ch); im != nil {
			cover = html.UnescapeString(im[1])
		}
		remark := ""
		if dm := av123CardDurRe.FindStringSubmatch(ch); dm != nil {
			d := strings.TrimSpace(dm[1])
			if d != "" && d != "0:00" {
				remark = d
			}
		}
		works = append(works, g2Work{RawID: slug, Title: title, Cover: cover, Remark: remark})
	}
	return works
}

// ---- directory (folder) pages ----

func av123DirEntries(kind string) ([]g2Work, error) {
	works := []g2Work{}
	if kind == "tag" {
		page, err := av123Fetch(av123Site + "/en")
		if err != nil {
			return nil, err
		}
		seen := map[string]bool{}
		for _, m := range av123TagDirRe.FindAllStringSubmatch(page, -1) {
			if seen[m[1]] {
				continue
			}
			seen[m[1]] = true
			name := av123Clean(m[2])
			if name == "" {
				continue
			}
			works = append(works, g2Work{RawID: "dir:tag:" + m[1], Title: name, Remark: "标签"})
		}
		return works, nil
	}
	var spec *struct{ kind, path, re string }
	for i := range av123DirSpecs {
		if av123DirSpecs[i].kind == kind {
			spec = &av123DirSpecs[i]
			break
		}
	}
	if spec == nil {
		return works, nil
	}
	page, err := av123Fetch(av123Site + "/en/" + spec.path)
	if err != nil {
		return nil, err
	}
	re := av123DirRe[kind]
	seen := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(page, -1) {
		if seen[m[1]] {
			continue
		}
		seen[m[1]] = true
		name := av123Clean(m[2])
		if name == "" {
			name = m[1]
		}
		remark := map[string]string{"genre": "类型", "maker": "厂牌", "actress": "演员", "series": "系列"}[kind]
		works = append(works, g2Work{RawID: "dir:" + kind + ":" + m[1], Title: name, Remark: remark})
	}
	return works, nil
}

// dirPath converts a folder rawID "dir:<kind>:<slug>" to its list path.
func av123DirListURL(rawID string, pg int) string {
	parts := strings.SplitN(rawID, ":", 3)
	if len(parts) != 3 {
		return ""
	}
	kind, slug := parts[1], parts[2]
	plural := map[string]string{"genre": "genres", "maker": "makers", "actress": "actresses", "series": "series", "tag": "tags"}[kind]
	if plural == "" {
		return ""
	}
	return av123Site + "/en/" + plural + "/" + slug + "?page=" + strconv.Itoa(pg)
}

// ---- catalog ----

func av123Catalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	if strings.HasPrefix(category, "dir:") {
		u := av123DirListURL(category, page)
		if u == "" {
			return []interface{}{}, 0, false, fmt.Errorf("bad dir id")
		}
		text, err := av123Fetch(u)
		if err != nil {
			return []interface{}{}, 0, false, err
		}
		works := av123Cards(text)
		return g2WorksToItems(slot, works, "目录"), len(works), len(works) >= 12, nil
	}
	if av123IsDirCat(category) {
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		entries, err := av123DirEntries(category)
		if err != nil {
			return []interface{}{}, 0, false, err
		}
		catName := ""
		for _, c := range av123Cats {
			if c.id == category {
				catName = c.name
			}
		}
		return g2WorksToItems(slot, entries, catName), len(entries), false, nil
	}
	text, err := av123Fetch(av123CategoryURL(category, page))
	if err != nil {
		return []interface{}{}, 0, false, err
	}
	works := av123Cards(text)
	catName := category
	for _, c := range av123Cats {
		if c.id == category {
			catName = c.name
		}
	}
	return g2WorksToItems(slot, works, catName), len(works), len(works) >= 12, nil
}

// ---- detail ----

type av123DetailCache struct {
	mu sync.Mutex
	m  map[string]av123DetailEntry
}

type av123DetailEntry struct {
	at    time.Time
	drama map[string]interface{}
	eps   []av123Episode
}

type av123Episode struct {
	Hash string
	Name string
}

var av123Cache = &av123DetailCache{m: map[string]av123DetailEntry{}}

func av123UnescapePayload(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' && i+1 < len(s) {
			n := s[i+1]
			switch n {
			case 'u':
				if i+5 < len(s) {
					if v, err := strconv.ParseUint(s[i+2:i+6], 16, 32); err == nil {
						b.WriteRune(rune(v))
						i += 5
						continue
					}
				}
				b.WriteByte(c)
			case '/':
				b.WriteByte('/')
				i++
			default:
				b.WriteByte(c)
			}
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}

// av123Episodes extracts the player payload episode list from a watch page.
func av123Episodes(page string) []av123Episode {
	eps := []av123Episode{}
	idx := strings.Index(page, "player(JSON.parse('")
	if idx < 0 {
		return eps
	}
	rest := page[idx+len("player(JSON.parse('"):]
	var raw strings.Builder
	for i := 0; i < len(rest); i++ {
		c := rest[i]
		if c == '\\' && i+1 < len(rest) {
			raw.WriteString(rest[i : i+2])
			i++
			continue
		}
		if c == '\'' {
			break
		}
		raw.WriteByte(c)
	}
	payload := av123UnescapePayload(raw.String())
	if payload == "" {
		return eps
	}
	var root interface{}
	if err := json.Unmarshal([]byte(payload), &root); err != nil {
		return eps
	}
	var list []interface{}
	switch v := root.(type) {
	case map[string]interface{}:
		if a, ok := v["episodes"].([]interface{}); ok {
			list = a
		} else if a, ok := v["list"].([]interface{}); ok {
			list = a
		} else if _, ok := v["url"]; ok {
			list = []interface{}{v}
		}
	case []interface{}:
		list = v
	}
	for i, it := range list {
		obj, ok := it.(map[string]interface{})
		if !ok {
			continue
		}
		u, _ := obj["url"].(string)
		u = strings.ReplaceAll(u, "\\/", "/")
		m := av123EpHashRe.FindStringSubmatch(u)
		if m == nil {
			continue
		}
		name, _ := obj["name"].(string)
		if name == "" {
			if num, ok := obj["number"]; ok {
				name = fmt.Sprintf("第%v集", num)
			} else {
				name = fmt.Sprintf("第%d集", i+1)
			}
		}
		// remember the embed host for the stream call
		eps = append(eps, av123Episode{Hash: m[1], Name: name})
		av123EmbedHosts.Store(m[1], embedHostOf(u))
	}
	return eps
}

var av123EmbedHosts sync.Map // hash -> embed host (scheme://host)

func embedHostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

func av123Detail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "dir:") {
		u := av123DirListURL(rawID, 1)
		if u == "" {
			return nil, fmt.Errorf("bad dir id")
		}
		text, err := av123Fetch(u)
		if err != nil {
			return nil, err
		}
		works := av123Cards(text)
		title := rawID
		parts := strings.SplitN(rawID, ":", 3)
		if len(parts) == 3 {
			title = parts[2]
		}
		return g2WorksDetail(slot, rawID, title, "", "目录", "目录", works, ""), nil
	}
	av123Cache.mu.Lock()
	if e, ok := av123Cache.m[rawID]; ok && time.Since(e.at) < 30*time.Minute {
		d := e.drama
		av123Cache.mu.Unlock()
		return d, nil
	}
	av123Cache.mu.Unlock()

	page, err := av123Fetch(av123Site + "/en/v/" + rawID)
	if err != nil {
		return nil, err
	}
	title := ""
	if m := av123TitleRe.FindStringSubmatch(page); m != nil {
		title = av123Clean(m[1])
	}
	if title == "" {
		if m := av123DocTitleRe.FindStringSubmatch(page); m != nil {
			title = av123TitleTailRe.ReplaceAllString(av123Clean(m[1]), "")
		}
	}
	if title == "" {
		title = strings.ToUpper(rawID)
	}
	cover := ""
	if m := av123OgImageRe.FindStringSubmatch(page); m != nil {
		cover = html.UnescapeString(m[1])
	}
	if cover == "" || strings.Contains(cover, "logo") {
		if m := av123BgImageRe.FindStringSubmatch(page); m != nil {
			cover = html.UnescapeString(m[1])
		}
	}
	// info rows -> description + remark
	descParts := []string{}
	remark := ""
	if dm := av123InfoRe.FindStringSubmatch(page); dm != nil {
		for _, row := range av123InfoRowRe.FindAllStringSubmatch(dm[1], -1) {
			dt := ""
			if m := av123DtRe.FindStringSubmatch(row[1]); m != nil {
				dt = av123Clean(m[1])
			}
			dd := ""
			links := []string{}
			if m := av123DdRe.FindStringSubmatch(row[1]); m != nil {
				dd = av123Clean(m[1])
				for _, lm := range av123LinkTextRe.FindAllStringSubmatch(m[1], -1) {
					if t := av123Clean(lm[1]); t != "" {
						links = append(links, t)
					}
				}
			}
			if dt != "" && dd != "" {
				descParts = append(descParts, dt+" "+dd)
			}
			if strings.Contains(dt, "Release") || strings.Contains(dt, "发行") {
				remark = dd
			}
			_ = links
		}
	}
	eps := av123Episodes(page)
	d := makeDrama(slot, rawID, title, cover, remark, "详情", strings.Join(descParts, " · "))
	if len(eps) > 0 {
		chs := []interface{}{}
		for i, ep := range eps {
			chs = append(chs, g2Chapter(slot, rawID, "e:"+ep.Hash, ep.Name, i+1))
		}
		g2SetChapters(d, chs)
	}
	av123Cache.mu.Lock()
	av123Cache.m[rawID] = av123DetailEntry{at: time.Now(), drama: d, eps: eps}
	av123Cache.mu.Unlock()
	return d, nil
}

// ---- resolve ----

var av123StreamCache = &struct {
	mu sync.Mutex
	m  map[string]av123StreamEntry
}{m: map[string]av123StreamEntry{}}

type av123StreamEntry struct {
	at  time.Time
	url string
	ref string
}

func av123StreamOf(hash string) (string, string, error) {
	av123StreamCache.mu.Lock()
	if e, ok := av123StreamCache.m[hash]; ok && time.Since(e.at) < 900*time.Second {
		u, r := e.url, e.ref
		av123StreamCache.mu.Unlock()
		return u, r, nil
	}
	av123StreamCache.mu.Unlock()

	hosts := []string{}
	if h, ok := av123EmbedHosts.Load(hash); ok {
		if hs, _ := h.(string); hs != "" {
			hosts = append(hosts, hs)
		}
	}
	hosts = append(hosts, av123PlayerHost)
	var lastErr error
	for _, host := range hosts {
		ref := host + "/e/" + hash
		hdr := map[string]string{"User-Agent": av123UA, "Referer": ref}
		body, code, _, err := httpGet(host+"/stream?id="+hash, hdr)
		if err != nil {
			lastErr = err
			continue
		}
		if code != 200 {
			lastErr = fmt.Errorf("stream %s -> %d", host, code)
			continue
		}
		var root map[string]interface{}
		if err := json.Unmarshal(body, &root); err != nil {
			lastErr = err
			continue
		}
		media := root
		if m, ok := root["media"].(map[string]interface{}); ok {
			media = m
		}
		stream, _ := media["stream"].(string)
		if stream == "" {
			lastErr = fmt.Errorf("stream %s: no media.stream", host)
			continue
		}
		av123StreamCache.mu.Lock()
		av123StreamCache.m[hash] = av123StreamEntry{at: time.Now(), url: stream, ref: ref}
		av123StreamCache.mu.Unlock()
		return stream, ref, nil
	}
	return "", "", lastErr
}

func av123Resolve(slot, rawID string) (map[string]interface{}, error) {
	hash := ""
	if strings.HasPrefix(rawID, "e:") {
		hash = rawID[2:]
	} else {
		// drama-level resolve: take the first episode of the detail
		if _, err := av123Detail(slot, rawID); err != nil {
			return nil, err
		}
		av123Cache.mu.Lock()
		e := av123Cache.m[rawID]
		av123Cache.mu.Unlock()
		if len(e.eps) == 0 {
			return nil, fmt.Errorf("no episodes")
		}
		hash = e.eps[0].Hash
	}
	stream, ref, err := av123StreamOf(hash)
	if err != nil {
		return nil, err
	}
	return playResult(stream, slot, rawID, av123UA, ref, "m3u8", "hls"), nil
}

// ---- search ----

func av123Search(slot, kw string) ([]interface{}, error) {
	u := av123Site + "/en/search?keyword=" + url.QueryEscape(kw) + "&page=1"
	text, err := av123Fetch(u)
	if err != nil {
		return []interface{}{}, err
	}
	works := av123Cards(text)
	return g2WorksToItems(slot, works, "搜索"), nil
}

// v4 final mapping: hongguo carries the MissAV mirror (thisav.my,
// sites_mirror.go) per the user's 17:48 order — the mirror passed the
// full vetting and is the same MissAV catalogue; 123AV is the
// documented second choice and this provider stays unregistered.
// To restore 123AV, re-add its registerSite call here and remove the
// mirror registration.
