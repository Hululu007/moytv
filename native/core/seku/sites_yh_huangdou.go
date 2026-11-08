package seku

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- huangdou （黄豆短剧）: encrypted-envelope JSON API ----
// Recipe: yuhuo huangdou module (r2 ApiService + HuangDouInterceptor).
// Every /api/drama/* POST is rewritten by the app interceptor into
// {"token","deviceId","data"} -> gzip -> AES-256-CBC (key =
// HmacSHA256(appKey, uuidBytes), random IV prepended), with
// sign/time/requestId/sessionId headers; responses decrypt the same
// way (plaintext JSON means an error envelope). Playback is the
// direct HLS template {base}/api/drama/hls/{id}/{seq}/play.m3u8.
// Paid rule (same as the py source): only episodes whose type is
// "free" are exposed or resolved; money/vip dramas stay listed with
// a remark tag, paid episodes never leave Detail/Resolve.

const yhHDSlot = "yh_huangdou"

var yhHDBases = []string{
	"https://cocoaview.cc",
	"https://momodrift.top",
	"https://nbsito.top",
	"https://tideember.cc",
	"https://zuzuspot.top",
}

const yhHDUA = "Mozilla/5.0 (iPhone15,2; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
const yhHDSessionID = "51258db574bc44a3b7e7da1dcce1c54f"
const yhHDPlayToken = "U_763090d1a87b862df53554d778777bd6"

var yhHDHMACKey = []byte("7961beb44246e3012ce228d6b5ced05a")

type yhHDCat struct{ id, name string }

var yhHDCats = []yhHDCat{
	{"246506", "独家原创"},
	{"1050905", "综艺"},
	{"900012", "黑料"},
	{"246502", "魔改短剧"},
	{"1050902", "AI漫剧"},
	{"817201", "二次元"},
	{"246505", "擦边短剧"},
	{"817202", "真人短剧"},
}

var yhHDBaseMu sync.Mutex
var yhHDBaseIdx int

func yhHDBase() string {
	yhHDBaseMu.Lock()
	defer yhHDBaseMu.Unlock()
	return yhHDBases[yhHDBaseIdx%len(yhHDBases)]
}

func yhHDUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func yhHDKey(uid string) []byte {
	raw, _ := hex.DecodeString(strings.ReplaceAll(uid, "-", ""))
	mac := hmac.New(sha256.New, yhHDHMACKey)
	mac.Write(raw)
	return mac.Sum(nil)
}

func yhHDPad(data []byte) []byte {
	pad := 16 - len(data)%16
	out := make([]byte, 0, len(data)+pad)
	out = append(out, data...)
	for i := 0; i < pad; i++ {
		out = append(out, byte(pad))
	}
	return out
}

func yhHDUnpad(data []byte) []byte {
	if len(data) == 0 {
		return data
	}
	pad := int(data[len(data)-1])
	if pad >= 1 && pad <= 16 && pad <= len(data) {
		return data[:len(data)-pad]
	}
	return data
}

func yhHDAPI(path string, fields map[string]string) (map[string]interface{}, error) {
	var lastErr error
	for attempt := 0; attempt < len(yhHDBases); attempt++ {
		yhHDBaseMu.Lock()
		idx := (yhHDBaseIdx + attempt) % len(yhHDBases)
		yhHDBaseMu.Unlock()
		obj, err := yhHDAPIOnce(yhHDBases[idx], path, fields)
		if err == nil && obj != nil {
			yhHDBaseMu.Lock()
			yhHDBaseIdx = idx
			yhHDBaseMu.Unlock()
			return obj, nil
		}
		if err != nil {
			lastErr = err
		}
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, fmt.Errorf("huangdou: %s returned no data", path)
}

func yhHDAPIOnce(base, path string, fields map[string]string) (map[string]interface{}, error) {
	uid := yhHDUUID()
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	token := ""
	if strings.Contains(path, "/api/drama/play") {
		token = yhHDPlayToken
	}
	dataJSON, _ := json.Marshal(fields)
	envelope := fmt.Sprintf(`{"token":"%s","deviceId":"%s","data":%s}`, token, uid, string(dataJSON))
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	_, _ = zw.Write([]byte(envelope))
	_ = zw.Close()
	key := yhHDKey(uid)
	iv := make([]byte, 16)
	_, _ = rand.Read(iv)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	ct := make([]byte, 0, gz.Len()+16)
	ct = append(ct, iv...)
	enc := make([]byte, len(yhHDPad(gz.Bytes())))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(enc, yhHDPad(gz.Bytes()))
	ct = append(ct, enc...)
	url := base + path
	stripped := strings.TrimPrefix(strings.TrimPrefix(url, "https://"), "http://")
	signSrc := fmt.Sprintf("Dart|%s|%s|%s|%s", yhHDSessionID, uid, ts, stripped)
	sign := fmt.Sprintf("%x-%s", md5.Sum([]byte(signSrc)), ts)
	headers := map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"version":      "1.0.0",
		"deviceType":   "web",
		"time":         ts,
		"requestId":    uid,
		"sessionId":    yhHDSessionID,
		"user-agent":   yhHDUA,
		"sign":         sign,
	}
	raw, code, _, err := httpDo("POST", url, bytes.NewReader(ct), headers)
	if err != nil {
		return nil, err
	}
	if code < 200 || code >= 300 || len(raw) == 0 {
		return nil, fmt.Errorf("huangdou: http %d", code)
	}
	var plain []byte
	if len(raw) >= 2 && raw[0] == '{' && (raw[1] == '"' || raw[1] == '}') {
		plain = raw
	} else {
		if len(raw) < 32 {
			return nil, fmt.Errorf("huangdou: short encrypted response")
		}
		blk, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		dec := make([]byte, len(raw)-16)
		cipher.NewCBCDecrypter(blk, raw[:16]).CryptBlocks(dec, raw[16:])
		zr, err := gzip.NewReader(bytes.NewReader(yhHDUnpad(dec)))
		if err != nil {
			return nil, err
		}
		plain, err = io.ReadAll(zr)
		if err != nil {
			return nil, err
		}
	}
	var obj map[string]interface{}
	if err := json.Unmarshal(plain, &obj); err != nil {
		return nil, err
	}
	if obj["status"] != "y" {
		return nil, fmt.Errorf("huangdou: api status %v error %v", obj["status"], obj["error"])
	}
	return obj, nil
}

func yhHDStr(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatInt(int64(t), 10)
	case json.Number:
		return t.String()
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", t)
	}
}

func yhHDInt(v interface{}) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(t))
		return n
	default:
		return 0
	}
}

func yhHDListItems(obj map[string]interface{}) []map[string]interface{} {
	data, _ := obj["data"].(map[string]interface{})
	list, _ := data["list"].([]interface{})
	out := []map[string]interface{}{}
	for _, it := range list {
		if m, ok := it.(map[string]interface{}); ok {
			out = append(out, m)
		}
	}
	return out
}

func yhHDCard(slot string, item map[string]interface{}) map[string]interface{} {
	name := yhHDStr(item["name"])
	cover := yhHDStr(item["img"])
	if cover == "" {
		cover = yhHDStr(item["img_y"])
	}
	remark := yhHDStr(item["update_label"])
	switch yhHDStr(item["pay_type"]) {
	case "money":
		remark = strings.TrimSpace(remark + " [付费]")
	case "vip":
		remark = strings.TrimSpace(remark + " [VIP]")
	}
	return makeDrama(slot, yhHDStr(item["id"]), name, cover, remark, yhHDStr(item["category"]), yhHDStr(item["description"]))
}

func yhHDCategories(slot string) []interface{} {
	out := []interface{}{}
	for _, c := range yhHDCats {
		out = append(out, categoryObj(c.id, c.name))
	}
	return out
}

func yhHDCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	if category == "" {
		category = yhHDCats[0].id
	}
	obj, err := yhHDAPI("/api/drama/list", map[string]string{
		"cat_id": category, "order": "new:top",
		"page": strconv.Itoa(page), "size": "12",
	})
	if err != nil {
		return nil, 0, false, err
	}
	items := yhHDListItems(obj)
	out := []interface{}{}
	for _, it := range items {
		if yhHDStr(it["id"]) != "" {
			out = append(out, yhHDCard(slot, it))
		}
	}
	return out, len(out), len(items) >= 12, nil
}

func yhHDDetailData(id string) (map[string]interface{}, error) {
	obj, err := yhHDAPI("/api/drama/detail", map[string]string{"id": id})
	if err != nil {
		return nil, err
	}
	data, _ := obj["data"].(map[string]interface{})
	if data == nil {
		return nil, fmt.Errorf("huangdou: empty detail for %s", id)
	}
	return data, nil
}

type yhHDEpisode struct {
	Seq  int
	Name string
}

func yhHDFreeEpisodes(data map[string]interface{}) []yhHDEpisode {
	eps, _ := data["episodes"].([]interface{})
	out := []yhHDEpisode{}
	for _, raw := range eps {
		ep, _ := raw.(map[string]interface{})
		if ep == nil {
			continue
		}
		if yhHDStr(ep["type"]) == "free" && yhHDInt(ep["price"]) == 0 {
			name := yhHDStr(ep["name"])
			seq := yhHDInt(ep["seq"])
			if !strings.HasPrefix(name, "第") {
				name = fmt.Sprintf("第%d集", seq)
			}
			out = append(out, yhHDEpisode{Seq: seq, Name: name})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Seq < out[j].Seq })
	return out
}

func yhHDDetail(slot, rawID string) (map[string]interface{}, error) {
	data, err := yhHDDetailData(rawID)
	if err != nil {
		return nil, err
	}
	title := yhHDStr(data["name"])
	cover := yhHDStr(data["img_y"])
	if cover == "" {
		cover = yhHDStr(data["img_x"])
	}
	desc := yhHDStr(data["description"])
	free := yhHDFreeEpisodes(data)
	total := yhHDInt(data["episode_count"])
	if total == 0 {
		if eps, ok := data["episodes"].([]interface{}); ok {
			total = len(eps)
		}
	}
	if len(free) < total {
		note := fmt.Sprintf("本源仅提供免费集：全剧 %d 集，其中免费 %d 集，付费集未收录。", total, len(free))
		if desc != "" {
			desc = desc + "\n" + note
		} else {
			desc = note
		}
	}
	d := makeDrama(slot, rawID, title, cover, yhHDStr(data["update_label"]), yhHDStr(data["category"]), desc)
	chapters := []interface{}{}
	for _, ep := range free {
		ref := fmt.Sprintf("%s@@%d", rawID, ep.Seq)
		chapters = append(chapters, map[string]interface{}{
			"episodeId": ref,
			"id":        dramaID(slot, ref),
			"dramaId":   dramaID(slot, ref),
			"sourceId":  slot,
			"source":    slot,
			"title":     ep.Name,
			"name":      ep.Name,
			"index":     ep.Seq,
			"episode":   ep.Seq,
			"url":       "",
			"videoUrl":  "",
			"mediaSize": 0,
		})
	}
	d["chapters"] = chapters
	d["episodeList"] = chapters
	d["episodeCount"] = len(chapters)
	d["chapterCount"] = len(chapters)
	d["totalEpisode"] = len(chapters)
	d["totalEpisodes"] = len(chapters)
	d["episodes"] = len(chapters)
	return d, nil
}

func yhHDResolve(slot, rawID string) (map[string]interface{}, error) {
	id, seq := rawID, 1
	if i := strings.LastIndex(rawID, "@@"); i >= 0 {
		id = rawID[:i]
		if n, err := strconv.Atoi(strings.TrimSpace(rawID[i+2:])); err == nil && n > 0 {
			seq = n
		}
	}
	data, err := yhHDDetailData(id)
	if err != nil {
		return nil, err
	}
	ok := false
	for _, ep := range yhHDFreeEpisodes(data) {
		if ep.Seq == seq {
			ok = true
			break
		}
	}
	if !ok {
		return nil, fmt.Errorf("huangdou: episode %d of %s is not a free episode", seq, id)
	}
	base := yhHDBase()
	url := fmt.Sprintf("%s/api/drama/hls/%s/%d/play.m3u8", base, id, seq)
	return playResult(url, slot, rawID, yhHDUA, base+"/", "m3u8", "hls"), nil
}

func yhHDSearch(slot, kw string) ([]interface{}, error) {
	obj, err := yhHDAPI("/api/drama/list", map[string]string{
		"page": "1", "size": "12", "keywords": kw,
	})
	if err != nil {
		return nil, err
	}
	out := []interface{}{}
	for _, it := range yhHDListItems(obj) {
		if yhHDStr(it["id"]) != "" {
			out = append(out, yhHDCard(slot, it))
		}
	}
	return out, nil
}

func yhHDHeaders() map[string]string {
	return map[string]string{"User-Agent": yhHDUA}
}

func init() {
	registerSite(yhHDSlot, &siteImpl{
		Key:        "huangdou",
		Name:       "黄豆短剧",
		DefaultCat: yhHDCats[0].id,
		HomeURL:    yhHDBases[0] + "/",
		Categories: yhHDCategories,
		Catalog:    yhHDCatalog,
		Detail:     yhHDDetail,
		Resolve:    yhHDResolve,
		Search:     yhHDSearch,
		Headers:    yhHDHeaders,
	}, "huangdou")
}
