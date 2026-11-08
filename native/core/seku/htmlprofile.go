package seku

import (
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// ---- Generic regex-profile HTML engine ----
//
// For bespoke HTML sites whose py spiders parse with regexes: the whole
// site is a profile of URL templates + regexes with named groups
// (id/title/cover). Detail pages yield the play URL via PlayRes (first
// matching pattern wins). Covers/titles fall back to the list data when
// the detail page does not repeat them.

type htmlCat struct {
	ID, Name string
	// ListURL template for this category ({page} substituted). Empty ->
	// the profile's ListURL with {cat} = ID.
	ListURL string
}

type htmlProfile struct {
	Base   string // no trailing slash
	UA     string
	Heads  map[string]string
	Origin string

	Cats []htmlCat
	// ListURL is the default list template; placeholders: {cat} {page}.
	ListURL string
	// ItemRe extracts one video card; must define named groups id,
	// title, cover (cover optional). Relative hrefs/ids pass through
	// IDClean when set.
	ItemRe    *regexp.Regexp
	IDClean   func(string) string
	CoverBase string         // prefix for relative cover URLs ("" = profile Base)
	PagesRe   *regexp.Regexp // group 1 = total pages (optional)

	DetailURL string         // template {id}
	TitleRe   *regexp.Regexp // group 1 (optional)
	CoverRe   *regexp.Regexp // group 1 (optional)
	DescRe    *regexp.Regexp // group 1 (optional)
	PlayRes   []*regexp.Regexp
	PlayBase  string // prefix for relative play URLs ("" = Base)

	SearchURL    string         // template {kw} {page}
	SearchItemRe *regexp.Regexp // nil -> ItemRe

	Format string // "m3u8"/"mp4" hint for resolve; "" = sniff by suffix

	Fetch func(rawurl string, headers map[string]string, referer string) ([]byte, int, error)
}

func (p *htmlProfile) headers() map[string]string {
	h := map[string]string{
		"User-Agent":      p.UA,
		"Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
		"Accept-Language": "zh-CN,zh;q=0.9",
		"Referer":         p.Base + "/",
	}
	for k, v := range p.Heads {
		h[k] = v
	}
	return h
}

func (p *htmlProfile) abs(base, u string) string {
	u = strings.TrimSpace(u)
	if u == "" || strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "https://") {
		return u
	}
	if base == "" {
		base = p.Base
	}
	if strings.HasPrefix(u, "//") {
		return "https:" + u
	}
	if strings.HasPrefix(u, "/") {
		return base + u
	}
	return base + "/" + u
}

func namedSubexp(re *regexp.Regexp, m []string) map[string]string {
	out := map[string]string{}
	for i, name := range re.SubexpNames() {
		if i > 0 && name != "" && i < len(m) {
			out[name] = m[i]
		}
	}
	return out
}

func (p *htmlProfile) parseItems(slot, html, catName string, re *regexp.Regexp) []interface{} {
	items := []interface{}{}
	seen := map[string]bool{}
	if re == nil {
		re = p.ItemRe
	}
	for _, m := range re.FindAllStringSubmatch(html, -1) {
		g := namedSubexp(re, m)
		id := g["id"]
		if p.IDClean != nil {
			id = p.IDClean(id)
		}
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		cover := p.abs(p.CoverBase, g["cover"])
		items = append(items, makeDrama(slot, id, cleanText(g["title"]), cover, g["remark"], catName, ""))
	}
	return items
}

func (p *htmlProfile) catName(cat string) string {
	for _, c := range p.Cats {
		if c.ID == cat {
			return c.Name
		}
	}
	return cat
}

func (p *htmlProfile) fetchPage(rawurl string, headers map[string]string) ([]byte, int, error) {
	if p.Fetch != nil {
		referer := p.Origin
		if referer == "" {
			referer = p.Base + "/"
		}
		return p.Fetch(rawurl, headers, referer)
	}
	body, code, _, err := httpGet(rawurl, headers)
	return body, code, err
}

func (p *htmlProfile) listURL(cat string, page int) string {
	tpl := p.ListURL
	for _, c := range p.Cats {
		if c.ID == cat && c.ListURL != "" {
			tpl = c.ListURL
			break
		}
	}
	u := strings.ReplaceAll(tpl, "{cat}", cat)
	u = strings.ReplaceAll(u, "{page}", strconv.Itoa(page))
	if !strings.HasPrefix(u, "http") {
		u = p.Base + u
	}
	return u
}

// htmlProfileImpl builds a siteImpl from a regex profile.
func htmlProfileImpl(key, name string, p *htmlProfile) *siteImpl {
	defCat := ""
	if len(p.Cats) > 0 {
		defCat = p.Cats[0].ID
	}
	impl := &siteImpl{
		Key: key, Name: name, DefaultCat: defCat, HomeURL: p.Base + "/",
		Headers: p.headers,
	}
	impl.Categories = func(slot string) []interface{} {
		out := []interface{}{}
		for _, c := range p.Cats {
			out = append(out, categoryObj(c.ID, c.Name))
		}
		return out
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		if category == "" {
			category = defCat
		}
		body, code, err := p.fetchPage(p.listURL(category, page), p.headers())
		if err != nil || code != 200 {
			return nil, 0, false, fmt.Errorf("%s catalog http %d err %v", key, code, err)
		}
		html := string(body)
		items := p.parseItems(slot, html, p.catName(category), nil)
		totalPages := page
		hasMore := len(items) > 0
		if p.PagesRe != nil {
			if m := p.PagesRe.FindStringSubmatch(html); m != nil {
				if n, err := strconv.Atoi(m[1]); err == nil {
					totalPages = n
					hasMore = page < n
				}
			}
		}
		return items, totalPages * 24, hasMore, nil
	}
	fetchDetail := func(rawID string) (title, cover, desc, play string, err error) {
		u := strings.ReplaceAll(p.DetailURL, "{id}", rawID)
		if !strings.HasPrefix(u, "http") {
			u = p.Base + u
		}
		body, code, err := p.fetchPage(u, p.headers())
		if err != nil || code != 200 {
			return "", "", "", "", fmt.Errorf("%s detail http %d err %v", key, code, err)
		}
		html := string(body)
		if p.TitleRe != nil {
			if m := p.TitleRe.FindStringSubmatch(html); m != nil {
				title = cleanText(m[1])
			}
		}
		if p.CoverRe != nil {
			if m := p.CoverRe.FindStringSubmatch(html); m != nil {
				cover = p.abs(p.CoverBase, m[1])
			}
		}
		if p.DescRe != nil {
			if m := p.DescRe.FindStringSubmatch(html); m != nil {
				desc = cleanText(m[1])
			}
		}
		for _, re := range p.PlayRes {
			if m := re.FindStringSubmatch(html); m != nil {
				v := m[0]
				if len(m) > 1 && m[1] != "" {
					v = m[1]
				}
				if v != "" {
					play = p.abs(p.PlayBase, v)
					break
				}
			}
		}
		return title, cover, desc, play, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		title, cover, desc, play, err := fetchDetail(rawID)
		if err != nil {
			return nil, err
		}
		remark := "无源"
		if play != "" {
			remark = "直连"
		}
		d := makeDrama(slot, rawID, title, cover, remark, p.catName(""), desc)
		if title == "" {
			// fall back to whatever the store knows about this drama
			if st := getStore(slot).findDrama(rawID); st != nil {
				if t, _ := st["title"].(string); t != "" {
					d["title"] = t
					d["name"] = t
				}
				if c, _ := st["cover"].(string); c != "" && cover == "" {
					d["cover"] = c
					d["coverUrl"] = c
					d["vod_pic"] = c
					d["pic"] = c
					d["thumb"] = c
				}
			}
		}
		return d, nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		_, _, _, play, err := fetchDetail(rawID)
		if err != nil {
			return nil, err
		}
		if play == "" {
			return nil, fmt.Errorf("%s no play url", key)
		}
		format, proto := p.Format, "hls"
		if format == "" {
			if strings.Contains(play, ".m3u8") {
				format = "m3u8"
			} else {
				format, proto = "mp4", "file"
			}
		} else if format != "m3u8" {
			proto = "file"
		}
		result := playResult(play, slot, rawID, p.UA, p.Base+"/", format, proto)
		if p.Origin != "" {
			if headers, ok := result["headers"].(map[string]interface{}); ok {
				headers["Origin"] = p.Origin
			}
		}
		return result, nil
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		if p.SearchURL == "" {
			return nil, fmt.Errorf("%s search not supported", key)
		}
		u := strings.ReplaceAll(p.SearchURL, "{kw}", url.QueryEscape(kw))
		u = strings.ReplaceAll(u, "{page}", "1")
		if !strings.HasPrefix(u, "http") {
			u = p.Base + u
		}
		body, code, err := p.fetchPage(u, p.headers())
		if err != nil || code != 200 {
			return []interface{}{}, fmt.Errorf("%s search http %d err %v", key, code, err)
		}
		re := p.SearchItemRe
		if re == nil {
			re = p.ItemRe
		}
		return p.parseItems(slot, string(body), "搜索", re), nil
	}
	return impl
}
