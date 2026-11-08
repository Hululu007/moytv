package seku

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

// ---- Generic MacCMS v10 API engine ----
//
// Covers any site exposing the standard 苹果CMS JSON API:
//   {base}/api.php/provide/vod/?ac=list              -> class[] + page info
//   {base}/api.php/provide/vod/?ac=videolist&t=&pg=  -> list[]
//   {base}/api.php/provide/vod/?ac=detail&ids=       -> list[0] full record
//   {base}/api.php/provide/vod/?ac=videolist&wd=     -> search
// Play addresses come from vod_play_url ("线路$$$"-groups, "#"-episodes,
// "name$url" pairs). Episodes: chapter list is built from the first play
// group; resolve re-reads the detail record and picks the episode the
// caller asked for (rawID may carry "#<episodeIndex>" suffix).
//
// rawID form: "<vod_id>" or "<vod_id>#<n>" (1-based episode index).

type mcAPIConfig struct {
	Base       string // site root, no trailing slash
	UA         string
	ExtraHeads map[string]string
	// PlayGroup picks which vod_play_url group to expose (0 = first
	// group that contains a playable URL).
	PlayGroup int
}

type mcAPIVod struct {
	VodID       json.RawMessage `json:"vod_id"`
	VodName     string          `json:"vod_name"`
	VodPic      string          `json:"vod_pic"`
	VodRemarks  string          `json:"vod_remarks"`
	VodContent  string          `json:"vod_content"`
	VodPlayFrom string          `json:"vod_play_from"`
	VodPlayURL  string          `json:"vod_play_url"`
	TypeName    string          `json:"type_name"`
	VodYear     string          `json:"vod_year"`
	VodArea     string          `json:"vod_area"`
	VodActor    string          `json:"vod_actor"`
	VodDirector string          `json:"vod_director"`
	VodScore    string          `json:"vod_score"`
	VodTime     string          `json:"vod_time"`
	TypeID      json.RawMessage `json:"type_id"`
}

type mcAPIListResp struct {
	Code      int             `json:"code"`
	Page      json.RawMessage `json:"page"`
	PageCount int             `json:"pagecount"`
	Total     int             `json:"total"`
	Class     []struct {
		TypeID   json.RawMessage `json:"type_id"`
		TypeName string          `json:"type_name"`
	} `json:"class"`
	List []*mcAPIVod `json:"list"`
}

func (c *mcAPIConfig) headers() map[string]string {
	h := map[string]string{
		"User-Agent":      c.UA,
		"Accept":          "application/json, text/plain, */*",
		"Accept-Language": "zh-CN,zh;q=0.9",
		"Referer":         c.Base + "/",
	}
	for k, v := range c.ExtraHeads {
		h[k] = v
	}
	return h
}

func (c *mcAPIConfig) get(path string) ([]byte, error) {
	body, code, _, err := httpGet(c.Base+path, c.headers())
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("maccms api http %d", code)
	}
	return body, nil
}

func (c *mcAPIConfig) list(params url.Values) (*mcAPIListResp, error) {
	body, err := c.get("/api.php/provide/vod/?" + params.Encode())
	if err != nil {
		return nil, err
	}
	var resp mcAPIListResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("maccms api parse: %v", err)
	}
	return &resp, nil
}

func mcRawID(v json.RawMessage) string {
	s := strings.Trim(string(v), `"`)
	return s
}

// mcEpisodes parses vod_play_url into episode (name, url) pairs of the
// selected play group.
func (c *mcAPIConfig) mcEpisodes(v *mcAPIVod) (from string, eps [][2]string) {
	groups := strings.Split(v.VodPlayURL, "$$$")
	froms := strings.Split(v.VodPlayFrom, "$$$")
	pick := -1
	for i, g := range groups {
		if strings.Contains(g, "$") && (pick < 0 || i == c.PlayGroup) {
			pick = i
			if i == c.PlayGroup {
				break
			}
		}
	}
	if pick < 0 || pick >= len(groups) {
		return "", nil
	}
	if pick < len(froms) {
		from = froms[pick]
	}
	for _, seg := range strings.Split(groups[pick], "#") {
		kv := strings.SplitN(seg, "$", 2)
		if len(kv) == 2 && strings.TrimSpace(kv[1]) != "" {
			eps = append(eps, [2]string{strings.TrimSpace(kv[0]), strings.TrimSpace(kv[1])})
		} else if len(kv) == 1 && strings.HasPrefix(seg, "http") {
			eps = append(eps, [2]string{"正片", strings.TrimSpace(seg)})
		}
	}
	return from, eps
}

func (c *mcAPIConfig) toDrama(slot string, v *mcAPIVod, withChapters bool) map[string]interface{} {
	id := mcRawID(v.VodID)
	title := cleanText(v.VodName)
	desc := cleanText(v.VodContent)
	d := makeDrama(slot, id, title, strings.TrimSpace(v.VodPic), v.VodRemarks, v.TypeName, desc)
	if withChapters {
		_, eps := c.mcEpisodes(v)
		if len(eps) > 0 {
			chapters := []interface{}{}
			for i, ep := range eps {
				epID := id
				if len(eps) > 1 {
					epID = fmt.Sprintf("%s#%d", id, i+1)
				}
				chapters = append(chapters, map[string]interface{}{
					"episodeId": epID,
					"id":        dramaID(slot, epID),
					"dramaId":   dramaID(slot, id),
					"sourceId":  slot,
					"source":    slot,
					"title":     ep[0],
					"name":      ep[0],
					"index":     i + 1,
					"episode":   i + 1,
					"url":       "",
					"videoUrl":  "",
					"mediaSize": 0,
				})
			}
			d["chapters"] = chapters
			d["episodeList"] = chapters
			d["episodes"] = len(eps)
			d["episodeCount"] = len(eps)
			d["chapterCount"] = len(eps)
			d["totalEpisode"] = len(eps)
			d["totalEpisodes"] = len(eps)
		}
	}
	return d
}

// mcAPIImpl builds a siteImpl from a MacCMS API config.
func mcAPIImpl(key, name string, cfg *mcAPIConfig) *siteImpl {
	impl := &siteImpl{
		Key: key, Name: name, DefaultCat: "", HomeURL: cfg.Base + "/",
		Headers: cfg.headers,
	}
	impl.Categories = func(slot string) []interface{} {
		resp, err := cfg.list(url.Values{"ac": {"list"}})
		if err != nil {
			return []interface{}{}
		}
		out := []interface{}{}
		for _, cl := range resp.Class {
			tid := mcRawID(cl.TypeID)
			if tid == "" || cl.TypeName == "" {
				continue
			}
			out = append(out, categoryObj(tid, cl.TypeName))
		}
		return out
	}
	impl.Catalog = func(slot, category string, page int) ([]interface{}, int, bool, error) {
		p := url.Values{"ac": {"videolist"}, "pg": {fmt.Sprint(page)}}
		if category != "" {
			p.Set("t", category)
		}
		resp, err := cfg.list(p)
		if err != nil {
			return nil, 0, false, err
		}
		items := []interface{}{}
		for _, v := range resp.List {
			items = append(items, cfg.toDrama(slot, v, false))
		}
		return items, resp.Total, page < resp.PageCount, nil
	}
	impl.Detail = func(slot, rawID string) (map[string]interface{}, error) {
		id, _ := splitEpisodeSuffix(rawID)
		resp, err := cfg.list(url.Values{"ac": {"detail"}, "ids": {id}})
		if err != nil || len(resp.List) == 0 {
			return nil, fmt.Errorf("maccms detail empty")
		}
		return cfg.toDrama(slot, resp.List[0], true), nil
	}
	impl.Resolve = func(slot, rawID string) (map[string]interface{}, error) {
		id, epIdx := splitEpisodeSuffix(rawID)
		resp, err := cfg.list(url.Values{"ac": {"detail"}, "ids": {id}})
		if err != nil || len(resp.List) == 0 {
			return nil, fmt.Errorf("maccms resolve empty")
		}
		_, eps := cfg.mcEpisodes(resp.List[0])
		if len(eps) == 0 {
			return nil, fmt.Errorf("maccms no play url")
		}
		if epIdx < 1 || epIdx > len(eps) {
			epIdx = 1
		}
		u := eps[epIdx-1][1]
		format, proto := "m3u8", "hls"
		if !strings.Contains(u, ".m3u8") {
			format, proto = "mp4", "file"
		}
		return playResult(u, slot, rawID, cfg.UA, cfg.Base+"/", format, proto), nil
	}
	impl.Search = func(slot, kw string) ([]interface{}, error) {
		resp, err := cfg.list(url.Values{"ac": {"videolist"}, "wd": {kw}, "pg": {"1"}})
		if err != nil {
			return []interface{}{}, err
		}
		items := []interface{}{}
		for _, v := range resp.List {
			items = append(items, cfg.toDrama(slot, v, false))
		}
		return items, nil
	}
	return impl
}

// splitEpisodeSuffix splits "123#2" into ("123", 2); no suffix -> idx 1.
func splitEpisodeSuffix(raw string) (string, int) {
	if i := strings.LastIndex(raw, "#"); i > 0 {
		var n int
		if _, err := fmt.Sscanf(raw[i+1:], "%d", &n); err == nil && n > 0 {
			return raw[:i], n
		}
	}
	return raw, 1
}
