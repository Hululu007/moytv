package seku

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// ---- vjav.tube （天天A片， KVS JSON API), recipe from ZakaDaydayAmns ----

const daydayBase = "https://vjav.tube"
const daydayUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

func daydayHeaders() map[string]string {
	return map[string]string{
		"User-Agent":       daydayUA,
		"Accept":           "application/json, text/plain, */*",
		"Accept-Language":  "zh-CN,zh;q=0.9,en;q=0.8",
		"Referer":          daydayBase + "/",
		"X-Requested-With": "XMLHttpRequest",
	}
}

type daydayCat struct{ id, name, slug string }

var daydayCats = []daydayCat{
	{"new", "最新更新", "latest-updates"},
	{"hot", "最热门", "most-popular"},
	{"c:asian", "Asian", "categories.asian"},
	{"c:japanese", "Japanese", "categories.japanese"},
	{"c:hd", "HD", "categories.hd"},
	{"c:big-tits", "Big Tits", "categories.big-tits"},
	{"c:cuckold", "Cuckold", "categories.cuckold"},
	{"c:dildos-toys", "Toys", "categories.dildos-toys"},
}

func daydayListURL(category string, page int) string {
	cat := "new"
	if category != "" {
		cat = category
	}
	// accept category by display name too
	for _, c := range daydayCats {
		if category == c.name {
			cat = c.id
			break
		}
	}
	switch {
	case cat == "new":
		return fmt.Sprintf("%s/api/json/videos2/14400/str/latest-updates/25/top-country.sg.%d.all...json", daydayBase, page)
	case cat == "hot":
		return fmt.Sprintf("%s/api/json/videos2/14400/str/most-popular/25/top-country.sg.%d.all...json", daydayBase, page)
	case strings.HasPrefix(cat, "c:"):
		slug := strings.TrimPrefix(cat, "c:")
		return fmt.Sprintf("%s/api/json/videos2/14400/str/latest-updates/25/categories.%s.%d.all...json", daydayBase, slug, page)
	default:
		// maybe a bare slug or sort name was passed
		return fmt.Sprintf("%s/api/json/videos2/14400/str/latest-updates/25/top-country.sg.%d.all...json", daydayBase, page)
	}
}

func flexID(v interface{}) string {
	switch t := v.(type) {
	case float64:
		return fmt.Sprintf("%d", int64(t))
	case string:
		return t
	case json.Number:
		return t.String()
	default:
		return fmt.Sprintf("%v", v)
	}
}

func bucketOf(id string) string {
	n, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		return "0"
	}
	return fmt.Sprintf("%d", (n/1000)*1000)
}

func daydayThumb(id string, thumb interface{}) string {
	if s, ok := thumb.(string); ok && strings.TrimSpace(s) != "" {
		return s
	}
	return fmt.Sprintf("https://tn.vjav.com/contents/videos_screenshots/%s/%s/240x180/1.jpg", bucketOf(id), id)
}

func daydayParseVideos(slot string, body []byte, categoryName string) []interface{} {
	items := []interface{}{}
	var root map[string]interface{}
	if err := json.Unmarshal(body, &root); err != nil {
		return items
	}
	vids, _ := root["videos"].([]interface{})
	for _, vv := range vids {
		vm, ok := vv.(map[string]interface{})
		if !ok {
			continue
		}
		id := flexID(vm["video_id"])
		if id == "" || id == "<nil>" {
			continue
		}
		title, _ := vm["title"].(string)
		dur, _ := vm["duration"].(string)
		items = append(items, makeDrama(slot, id, cleanText(title), daydayThumb(id, vm["thumb"]), dur, categoryName, ""))
	}
	return items
}

func daydayCatName(category string) string {
	for _, c := range daydayCats {
		if category == c.id || category == c.name {
			return c.name
		}
	}
	return "最新更新"
}

func daydayCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	u := daydayListURL(category, page)
	body, code, _, err := httpGet(u, daydayHeaders())
	if err != nil || code != 200 || len(body) < 20 {
		return nil, 0, false, fmt.Errorf("dayday catalog http %d err %v", code, err)
	}
	items := daydayParseVideos(slot, body, daydayCatName(category))
	return items, 249975, true, nil
}

func daydaySearch(slot, kw string) ([]interface{}, error) {
	u := fmt.Sprintf("%s/api/json/videos2/14400/str/relevance/25/top-country.sg.1.all...json?sq=%s", daydayBase, url.QueryEscape(kw))
	body, code, _, err := httpGet(u, daydayHeaders())
	if err != nil || code != 200 || len(body) < 20 {
		// fallback ?s=
		u2 := fmt.Sprintf("%s/api/json/videos2/14400/str/relevance/25/top-country.sg.1.all...json?s=%s", daydayBase, url.QueryEscape(kw))
		body, code, _, err = httpGet(u2, daydayHeaders())
		if err != nil || code != 200 {
			return []interface{}{}, fmt.Errorf("dayday search http %d err %v", code, err)
		}
	}
	return daydayParseVideos(slot, body, "搜索"), nil
}

type daydayDetailJSON struct {
	Video map[string]interface{} `json:"video"`
}

func daydayDetail(slot, rawID string) (map[string]interface{}, error) {
	u := fmt.Sprintf("%s/api/json/video/86400/0/%s/%s.json", daydayBase, bucketOf(rawID), rawID)
	body, code, _, err := httpGet(u, daydayHeaders())
	if err != nil || code != 200 || len(body) < 20 {
		return nil, fmt.Errorf("dayday detail http %d err %v", code, err)
	}
	var dj daydayDetailJSON
	if err := json.Unmarshal(body, &dj); err != nil || dj.Video == nil {
		return nil, fmt.Errorf("dayday detail parse %v", err)
	}
	v := dj.Video
	title, _ := v["title"].(string)
	dur, _ := v["duration"].(string)
	catNames := []string{}
	if cats, ok := v["categories"].(map[string]interface{}); ok {
		for _, cv := range cats {
			if cm, ok := cv.(map[string]interface{}); ok {
				if t, ok := cm["title"].(string); ok && t != "" {
					catNames = append(catNames, t)
				}
			}
		}
	}
	desc := fmt.Sprintf("分类：%s\n时长：%s\n来源：天天A片", strings.Join(catNames, " / "), dur)
	d := makeDrama(slot, rawID, cleanText(title), daydayThumb(rawID, v["thumb"]), dur, strings.Join(catNames, " / "), desc)
	return d, nil
}

// KVS deobfuscation: cyrillic homoglyph map from ZakaDaydayAmns.HOMO()
var homoMap = map[rune]rune{
	'А': 'A', 'В': 'B', 'Е': 'E', 'К': 'K', 'М': 'M', 'Н': 'H',
	'О': 'O', 'Р': 'P', 'С': 'C', 'Т': 'T', 'У': 'Y', 'Х': 'X',
	'а': 'a', 'в': 'b', 'е': 'e', 'к': 'k', 'м': 'm', 'н': 'h',
	'о': 'o', 'р': 'p', 'с': 'c', 'т': 't', 'у': 'y', 'х': 'x',
	'ѕ': 's', 'і': 'i', 'ј': 'j',
}

func daydayDeobf(s string) string {
	var b strings.Builder
	for _, ch := range s {
		if ch <= 127 {
			switch ch {
			case ',':
				b.WriteRune('/')
			case '~':
				b.WriteRune('=')
			default:
				b.WriteRune(ch)
			}
		} else if rep, ok := homoMap[ch]; ok {
			b.WriteRune(rep)
		} else {
			b.WriteRune(ch)
		}
	}
	mapped := b.String()
	var f strings.Builder
	for _, ch := range mapped {
		if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '+' || ch == '/' || ch == '=' {
			f.WriteRune(ch)
		}
	}
	clean := f.String()
	for len(clean)%4 != 0 {
		clean += "="
	}
	// b64dec in the Java class also maps url-safe chars first
	clean = strings.ReplaceAll(strings.ReplaceAll(clean, "-", "+"), "_", "/")
	dec, err := base64.StdEncoding.DecodeString(clean)
	if err != nil {
		dec2, err2 := base64.URLEncoding.DecodeString(f.String())
		if err2 != nil {
			return ""
		}
		dec = dec2
	}
	return strings.TrimSpace(string(dec))
}

func daydayFileURL(rawID string) (string, error) {
	u := fmt.Sprintf("%s/api/videofile.php?video_id=%s&lifetime=8640000", daydayBase, rawID)
	body, code, _, err := httpGet(u, daydayHeaders())
	if err != nil || code != 200 {
		return "", fmt.Errorf("videofile http %d err %v", code, err)
	}
	var arr []map[string]interface{}
	if err := json.Unmarshal(body, &arr); err != nil || len(arr) == 0 {
		return "", fmt.Errorf("videofile parse")
	}
	vu, _ := arr[0]["video_url"].(string)
	if vu == "" {
		return "", fmt.Errorf("videofile empty video_url")
	}
	real := daydayDeobf(vu)
	if real == "" {
		return "", fmt.Errorf("deobf empty")
	}
	if strings.HasPrefix(real, "/") {
		real = daydayBase + real
	}
	return real, nil
}

func daydayResolve(slot, rawID string) (map[string]interface{}, error) {
	fileURL, err := daydayFileURL(rawID)
	if err != nil {
		return nil, err
	}
	final := fileURL
	if strings.Contains(fileURL, "/get_file/") {
		// Follow one redirect hop manually to land on the signed CDN URL,
		// mirroring ZakaDaydayAmns.playerContent.
		req, err := http.NewRequest("GET", fileURL, nil)
		if err == nil {
			for k, v := range daydayHeaders() {
				req.Header.Set(k, v)
			}
			resp, err := noRedirectClient.Do(req)
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode >= 300 && resp.StatusCode < 400 {
					loc := resp.Header.Get("Location")
					if loc != "" {
						if strings.HasPrefix(loc, "/") {
							loc = daydayBase + loc
						}
						final = loc
					}
				}
			}
		}
	}
	return playResult(final, slot, rawID, daydayUA, daydayBase+"/", "mp4", "file"), nil
}
