package seku

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
)

// ---- iqiyi （名 iqiyi 实为快手族短视频）: maomi-family AES-CBC envelope API ----
// Recipe: yuhuo iqiyi module, jadx-verified line by line 2026-10-24:
//   request builder a3.b.b(json): _data = UPPERHEX( AES-128-CBC/PKCS5(
//     json, key, IV ) ) with key/IV order taken from a3.b itself (the
//     §5.1 table lists the pair swapped — a3.b is definitive):
//       key = c(f13a = getIQY1) = "5ef80f4745ac5251"  (SecretKeySpec)
//       IV  = d(b    = getIQY2) = "5ef804a1026c705d"  (IvParameterSpec)
//     c()/d() pad with '0' / truncate to 16 — both already 16 bytes.
//     a3.b.a(page,userId) builds {"userId":..,"page":..} (love list only).
//   interceptor a3.c (jadx-clean):
//     form fields _version="1.4", _device="android" added to every
//     request; headers access-token = b.b(h6.b.f8278w = IQY_TOKEN)
//     (AES-encrypted hex, verbatim), access-code =
//     "0ad7fa79203795061bf3dba11ed3e45e" (literal), device-id =
//     b.b(h6.b.f8280x = IQY_ID) (AES-encrypted hex, verbatim);
//     response body JSON -> getString("data") -> hex -> AES-CBC decrypt
//     (a3.b.e) -> plain JSON replaces the body.
//   ApiService a3.a endpoints used here (all POST, field _data):
//     /bigapi/video/search      {isRecommend:1,isPlayList:1,page} -> [VideoInfo] 首页推荐流 (HomeFragment via g)
//     /bigapi/video/search      {keywords,page}                   -> [VideoInfo] 搜索
//     /bigapi/video/search      {orderBy:"time",specialId,page}   -> [VideoInfo] 专题内 (SpecialFragment via g)
//     /bigapi/material/category {indexShow:1}                     -> [Category] (ChoiceFragment via f)
//     /bigapi/material/detail   {cateId,orderBy,page}             -> [VideoInfo] 分类 (CategoryFragment via d)
//     /bigapi/special/list      {}                                -> [Special] (ChoiceFragment via a)
//     /bigapi/video/detail      {id,linkType:""}                  -> VideoInfo (ShortVideoAdapter via c)
//     /bigapi/app/info          {deviceVersion:"3.7",deviceId:IQY_ID} (launch only, unused here)
//   Play: VideoInfo.videoLink is the direct play URL (list items carry
//     it already; detail re-fetches it). Ads: adType=="1" items are the
//     app's own isAd() and are filtered. Paid/unavailable handling: the
//     video beans carry no price field; a detail whose videoLink is
//     empty surfaces playTips and Resolve refuses it — category-level
//     isPoint/vipLevel (Category bean) are shown as remarks, not hidden.
//   Bases: h6.b URL_IQIYI http://api.apikuaishou3.com with the decoded
//     rotation siblings apikuaishou2 / apikuaishou4; health check
//     /bigapi/app/ping?_version=1.4&_device=android (module string).
//
// Verification (2026-10-24, build sandbox): the sandbox egress reaches
// none of the apikuaishou hosts (DNS resolves to 198.18.x.x fake-IPs,
// direct connect fails / proxy empty reply; HTTP-DNS has no record) —
// the known sandbox egress class from the porting guide. All legs are
// CODE-PROVEN (jadx line-by-line) but BYTE-UNVERIFIED from here:
// Categories/Catalog/Cover/Detail/Search/Resolve 出口未验，待真机补验.
// No evidence the site itself is dead.

const yhIQYSlot = "yh_iqiyi"
const yhIQYUA = "okhttp/4.9.0"
const yhIQYToken = "2af24c5367e76711cdb4d057db931e70"
const yhIQYID = "355712103569514"
const yhIQYAccessCode = "0ad7fa79203795061bf3dba11ed3e45e"

var yhIQYKey = []byte("5ef80f4745ac5251")
var yhIQYIV = []byte("5ef804a1026c705d")

var yhIQYBases = []string{
	"http://api.apikuaishou3.com",
	"http://api.apikuaishou2.com",
	"http://api.apikuaishou4.com",
}

var (
	yhIQYBaseMu sync.Mutex
	yhIQYBase   string
	yhIQYCache  sync.Map // id -> VideoInfo map
)

func yhIQYPad(b []byte) []byte {
	n := 16 - len(b)%16
	out := append([]byte{}, b...)
	for i := 0; i < n; i++ {
		out = append(out, byte(n))
	}
	return out
}

func yhIQYUnpad(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	n := int(b[len(b)-1])
	if n < 1 || n > 16 || n > len(b) {
		return b
	}
	return b[:len(b)-n]
}

func yhIQYEnc(plain string) string {
	block, _ := aes.NewCipher(yhIQYKey)
	padded := yhIQYPad([]byte(plain))
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, yhIQYIV).CryptBlocks(out, padded)
	return strings.ToUpper(hex.EncodeToString(out))
}

func yhIQYDec(hexs string) ([]byte, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(hexs))
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw)%16 != 0 {
		return nil, fmt.Errorf("yh_iqiyi: bad cipher len")
	}
	block, _ := aes.NewCipher(yhIQYKey)
	out := make([]byte, len(raw))
	cipher.NewCBCDecrypter(block, yhIQYIV).CryptBlocks(out, raw)
	return yhIQYUnpad(out), nil
}

func yhIQYPost(base, path string, payload map[string]interface{}) (interface{}, error) {
	plain := "{}"
	if payload != nil {
		jb, _ := json.Marshal(payload)
		plain = string(jb)
	}
	form := url.Values{
		"_data":    {yhIQYEnc(plain)},
		"_version": {"1.4"},
		"_device":  {"android"},
	}
	h := map[string]string{
		"User-Agent":   yhIQYUA,
		"Content-Type": "application/x-www-form-urlencoded",
		"access-token": yhIQYEnc(yhIQYToken),
		"access-code":  yhIQYAccessCode,
		"device-id":    yhIQYEnc(yhIQYID),
	}
	raw, code, _, err := httpDo("POST", base+path, strings.NewReader(form.Encode()), h)
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_iqiyi http %d", code)
	}
	trimmed := strings.TrimSpace(string(raw))
	var inner string
	var env map[string]interface{}
	if err := json.Unmarshal([]byte(trimmed), &env); err == nil {
		if ds, ok := env["data"].(string); ok && ds != "" {
			inner = ds
		}
	}
	var plainBytes []byte
	if inner != "" {
		plainBytes, err = yhIQYDec(inner)
		if err != nil {
			return nil, fmt.Errorf("yh_iqiyi decrypt: %v", err)
		}
	} else {
		plainBytes = []byte(trimmed)
	}
	var out interface{}
	if err := json.Unmarshal(plainBytes, &out); err != nil {
		return nil, fmt.Errorf("yh_iqiyi parse: %v", err)
	}
	return out, nil
}

func yhIQYCall(path string, payload map[string]interface{}) (interface{}, error) {
	yhIQYBaseMu.Lock()
	base := yhIQYBase
	yhIQYBaseMu.Unlock()
	if base != "" {
		if res, err := yhIQYPost(base, path, payload); err == nil {
			return res, nil
		}
		yhIQYBaseMu.Lock()
		if yhIQYBase == base {
			yhIQYBase = ""
		}
		yhIQYBaseMu.Unlock()
	}
	var lastErr error
	for _, cand := range yhIQYBases {
		if cand == base {
			continue
		}
		res, err := yhIQYPost(cand, path, payload)
		if err == nil {
			yhIQYBaseMu.Lock()
			yhIQYBase = cand
			yhIQYBaseMu.Unlock()
			return res, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func yhIQYCard(slot string, rec map[string]interface{}) (map[string]interface{}, bool) {
	// VideoInfo.isAd(): adType == "1".
	if g5StrVal(rec["adType"]) == "1" || g5StrVal(rec["isAd"]) == "1" {
		return nil, false
	}
	id := g5StrVal(rec["id"])
	title := g5StrVal(rec["name"])
	if id == "" || title == "" {
		return nil, false
	}
	yhIQYCache.Store(id, rec)
	remark := g5StrVal(rec["tagName"])
	desc := ""
	if n := g5StrVal(rec["nickname"]); n != "" {
		desc = "作者 " + n
	}
	if lv := g5StrVal(rec["love"]); lv != "" {
		if desc != "" {
			desc += " · "
		}
		desc += "喜欢 " + lv
	}
	return makeDrama(slot, id, title, g5StrVal(rec["img"]), remark, g5StrVal(rec["tagName"]), desc), true
}

func yhIQYCards(slot string, recs []interface{}) []interface{} {
	out := []interface{}{}
	for _, e := range recs {
		if m := yhMap(e); m != nil {
			if c, ok := yhIQYCard(slot, m); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func yhIQYListCall(slot, path string, payload map[string]interface{}) ([]interface{}, int, bool, error) {
	res, err := yhIQYCall(path, payload)
	if err != nil {
		return nil, 0, false, err
	}
	items := yhIQYCards(slot, yhArr(res))
	return items, len(items), len(items) >= 10, nil
}

func yhIQYCategories(slot string) []interface{} {
	out := []interface{}{categoryObj("recommend", "推荐")}
	if res, err := yhIQYCall("/bigapi/material/category", map[string]interface{}{"indexShow": 1}); err == nil {
		for _, e := range yhArr(res) {
			m := yhMap(e)
			if m == nil {
				continue
			}
			cid := g5StrVal(m["cateId"])
			if cid == "" {
				cid = g5StrVal(m["catId"])
			}
			name := g5StrVal(m["name"])
			if cid == "" || name == "" {
				continue
			}
			ob := g5StrVal(m["orderBy"])
			id := "cat:" + cid
			if ob != "" {
				id += "|" + ob
			}
			out = append(out, categoryObj(id, name))
		}
	}
	out = append(out, categoryObj("special", "专题"))
	return out
}

func yhIQYCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case category == "" || category == "recommend":
		return yhIQYListCall(slot, "/bigapi/video/search", map[string]interface{}{
			"isRecommend": 1, "isPlayList": 1, "page": page,
		})
	case strings.HasPrefix(category, "cat:"):
		rest := strings.TrimPrefix(category, "cat:")
		cid, ob := rest, "time"
		if i := strings.Index(rest, "|"); i >= 0 {
			cid, ob = rest[:i], rest[i+1:]
		}
		return yhIQYListCall(slot, "/bigapi/material/detail", map[string]interface{}{
			"cateId": cid, "orderBy": ob, "page": page,
		})
	case category == "special":
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		res, err := yhIQYCall("/bigapi/special/list", map[string]interface{}{})
		if err != nil {
			return nil, 0, false, err
		}
		out := []interface{}{}
		for _, e := range yhArr(res) {
			m := yhMap(e)
			if m == nil {
				continue
			}
			id, name := g5StrVal(m["id"]), g5StrVal(m["name"])
			if id == "" || name == "" {
				continue
			}
			out = append(out, makeDrama(slot, "dir:special:"+id, name, g5StrVal(m["img"]), "", "专题", g5StrVal(m["description"])))
		}
		return out, len(out), false, nil
	case strings.HasPrefix(category, "dir:special:"):
		return yhIQYListCall(slot, "/bigapi/video/search", map[string]interface{}{
			"orderBy": "time", "specialId": strings.TrimPrefix(category, "dir:special:"), "page": page,
		})
	}
	return yhIQYListCall(slot, "/bigapi/video/search", map[string]interface{}{
		"isRecommend": 1, "isPlayList": 1, "page": page,
	})
}

func yhIQYDetailFetch(rawID string) (map[string]interface{}, error) {
	res, err := yhIQYCall("/bigapi/video/detail", map[string]interface{}{"id": rawID, "linkType": ""})
	if err != nil {
		return nil, err
	}
	m := yhMap(res)
	if m == nil {
		if v, ok := yhIQYCache.Load(rawID); ok {
			return v.(map[string]interface{}), nil
		}
		return nil, fmt.Errorf("yh_iqiyi: detail empty for %s", rawID)
	}
	yhIQYCache.Store(rawID, m)
	return m, nil
}

func yhIQYDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "dir:special:") {
		items, _, _, err := yhIQYCatalog(slot, rawID, 1)
		if err != nil {
			return nil, err
		}
		d := makeDrama(slot, rawID, strings.TrimPrefix(rawID, "dir:special:"), "", "", "专题", "")
		if len(items) > 0 {
			d["related"] = items
		}
		return d, nil
	}
	rec, err := yhIQYDetailFetch(rawID)
	if err != nil {
		return nil, err
	}
	title := g5StrVal(rec["name"])
	d := makeDrama(slot, rawID, title, g5StrVal(rec["img"]), g5StrVal(rec["tagName"]), g5StrVal(rec["tagName"]), "")
	if n := g5StrVal(rec["nickname"]); n != "" {
		d["actor"] = n
		d["vod_actor"] = n
	}
	g5SetChapters(d, slot, rawID, []string{rawID}, []string{"正片"})
	return d, nil
}

func yhIQYResolve(slot, rawID string) (map[string]interface{}, error) {
	vid := rawID
	if i := strings.Index(vid, "$"); i >= 0 {
		vid = vid[i+1:]
	}
	rec, err := yhIQYDetailFetch(vid)
	if err != nil {
		// Fall back to the list-cached item (list items carry videoLink).
		if v, ok := yhIQYCache.Load(vid); ok {
			rec = v.(map[string]interface{})
		} else {
			return nil, err
		}
	}
	u := g5StrVal(rec["videoLink"])
	if u == "" {
		tips := g5StrVal(rec["playTips"])
		return nil, fmt.Errorf("yh_iqiyi: no play url for %s (%s)", vid, tips)
	}
	format, protocol := "mp4", ""
	if strings.Contains(u, ".m3u8") {
		format, protocol = "m3u8", "hls"
	}
	return playResult(u, slot, rawID, yhIQYUA, yhIQYBases[0]+"/", format, protocol), nil
}

func yhIQYSearch(slot, kw string) ([]interface{}, error) {
	res, err := yhIQYCall("/bigapi/video/search", map[string]interface{}{"keywords": kw, "page": 1})
	if err != nil {
		return nil, err
	}
	return yhIQYCards(slot, yhArr(res)), nil
}

func yhIQYHeaders() map[string]string {
	return map[string]string{"User-Agent": yhIQYUA}
}
