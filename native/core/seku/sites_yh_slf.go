package seku

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
)

// ---- slf: maomi-family signed + AES-CBC envelope API (/bigapi) ----
// Recipe: yuhuo slf module, jadx-verified line by line 2026-10-24:
//   request builder l5.d.a(json): form map
//     _data = UPPERHEX( AES-128-CBC/PKCS5( json, key, IV ) )
//       key = c(getSlf1) = "525202f9149e061p", IV = b(getSlf2) =
//       "4efd3f6060e20332" (c()/b() pad with '0' / truncate to 16 —
//       both strings are already 16 bytes)
//     _sign = MD5( UPPER( _data + "yqqwhadshoiadsnkspdsasas4581306" ) )
//       (l5.d appends the suffix, upper-cases the whole string, then
//       MD5s it and renders lowercase hex)
//   interceptor l5.c (jadx failed on it; dumped via androguard from
//     classes.dex and read instruction by instruction):
//     form fields _version="1.6", _device="android" are added to every
//     request; headers access-token = h6.b.G (SLF_TOKEN, raw),
//     device-id = h6.b.F (SLF_DEVICE, raw),
//     access-code = "9f7690763daa8804ebba9b9b1984d551";
//     response body JSON -> getString("data") -> hex -> AES-CBC decrypt
//     with the same key/IV -> plain JSON replaces the body.
//   ApiService l5.a endpoints used here (all POST, {type}="video"):
//     /bigapi/video/homenew     payload ""        -> HomeDataBean
//     /bigapi/video/search      {page}            -> [SLFItemBean] 最新流
//     /bigapi/{type}/search     {page,catId}      -> [SLFItemBean] 分类
//     /bigapi/{type}/search     {order,page}      -> [SLFItemBean] 排行
//     /bigapi/{type}/search     {keywords,page}   -> [SLFItemBean] 搜索
//     /bigapi/{type}/special    {page}            -> [Special]
//     /bigapi/{type}/specialdetail {id}           -> GuessLike{items}
//     /bigapi/video/detail      {id}              -> ComicDetail
//     /bigapi/video/searchinfo  payload ""        -> SearchInfo{order[]}
//   Play: ComicDetail.videoLink is played directly (VideoDetailActivity);
//     an empty videoLink shows canPlayTips instead. Paid rule: items and
//     details carry point (points price); point>0 items are filtered in
//     Catalog and refused in Resolve.
//   Base: h6.b E http://api-01.adieuqdmds.com:8091.
//
// Verification (2026-10-24, build sandbox): the sandbox egress reaches
// neither the base host (DNS resolves to a 198.18.x.x fake-IP, direct
// connect fails) nor any HTTP-DNS record for it (119.28.28.28 returns
// empty) — the known sandbox egress class from the porting guide. All
// legs are CODE-PROVEN (jadx + androguard line-by-line, incl. the
// interceptor jadx could not decompile) but BYTE-UNVERIFIED from here:
// Categories/Catalog/Cover/Detail/Search/Resolve 出口未验，待真机补验.
// No evidence the site itself is dead.

const yhSLFSlot = "yh_slf"
const yhSLFUA = "okhttp/4.9.0"
const yhSLFBase = "http://api-01.adieuqdmds.com:8091"
const yhSLFToken = "7b1dd13840b2783aef81d05bf696596a"
const yhSLFDevice = "0ed99cef71d6eec3e1d5734085745876"
const yhSLFAccessCode = "9f7690763daa8804ebba9b9b1984d551"
const yhSLFSuffix = "yqqwhadshoiadsnkspdsasas4581306"

var yhSLFKey = []byte("525202f9149e061p")
var yhSLFIV = []byte("4efd3f6060e20332")

var yhSLFCache sync.Map // id -> ComicDetail map

func yhSLFPad(b []byte) []byte {
	n := 16 - len(b)%16
	out := append([]byte{}, b...)
	for i := 0; i < n; i++ {
		out = append(out, byte(n))
	}
	return out
}

func yhSLFUnpad(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	n := int(b[len(b)-1])
	if n < 1 || n > 16 || n > len(b) {
		return b
	}
	return b[:len(b)-n]
}

func yhSLFEnc(plain string) string {
	block, _ := aes.NewCipher(yhSLFKey)
	padded := yhSLFPad([]byte(plain))
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, yhSLFIV).CryptBlocks(out, padded)
	return strings.ToUpper(hex.EncodeToString(out))
}

func yhSLFDec(hexs string) ([]byte, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(hexs))
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw)%16 != 0 {
		return nil, fmt.Errorf("yh_slf: bad cipher len")
	}
	block, _ := aes.NewCipher(yhSLFKey)
	out := make([]byte, len(raw))
	cipher.NewCBCDecrypter(block, yhSLFIV).CryptBlocks(out, raw)
	return yhSLFUnpad(out), nil
}

// yhSLFCall posts one l5.d.a-built form and returns the decrypted,
// parsed response JSON (object or array).
func yhSLFCall(path string, payload map[string]interface{}) (interface{}, error) {
	plain := ""
	if payload != nil {
		jb, _ := json.Marshal(payload)
		plain = string(jb)
	}
	data := yhSLFEnc(plain)
	sign := fmt.Sprintf("%x", md5.Sum([]byte(strings.ToUpper(data+yhSLFSuffix))))
	form := url.Values{
		"_data":    {data},
		"_sign":    {sign},
		"_version": {"1.6"},
		"_device":  {"android"},
	}
	h := map[string]string{
		"User-Agent":   yhSLFUA,
		"Content-Type": "application/x-www-form-urlencoded",
		"access-token": yhSLFToken,
		"device-id":    yhSLFDevice,
		"access-code":  yhSLFAccessCode,
	}
	raw, code, _, err := httpDo("POST", yhSLFBase+path, strings.NewReader(form.Encode()), h)
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_slf http %d", code)
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
		plainBytes, err = yhSLFDec(inner)
		if err != nil {
			return nil, fmt.Errorf("yh_slf decrypt: %v", err)
		}
	} else {
		plainBytes = []byte(trimmed)
	}
	var out interface{}
	if err := json.Unmarshal(plainBytes, &out); err != nil {
		return nil, fmt.Errorf("yh_slf parse: %v", err)
	}
	return out, nil
}

func yhSLFItemCard(slot string, rec map[string]interface{}) (map[string]interface{}, bool) {
	id := g5StrVal(rec["id"])
	title := g5StrVal(rec["name"])
	if id == "" || title == "" {
		return nil, false
	}
	remark := g5StrVal(rec["status"])
	if remark == "" {
		remark = g5StrVal(rec["tagStr"])
	}
	desc := g5StrVal(rec["summary"])
	if desc == "" {
		desc = g5StrVal(rec["description"])
	}
	return makeDrama(slot, id, title, g5StrVal(rec["img"]), remark, g5StrVal(rec["author"]), desc), true
}

func yhSLFItemCards(slot string, recs []interface{}) []interface{} {
	out := []interface{}{}
	for _, e := range recs {
		if m := yhMap(e); m != nil {
			if c, ok := yhSLFItemCard(slot, m); ok {
				out = append(out, c)
			}
		}
	}
	return out
}

func yhSLFListCall(slot, path string, payload map[string]interface{}) ([]interface{}, int, bool, error) {
	res, err := yhSLFCall(path, payload)
	if err != nil {
		return nil, 0, false, err
	}
	items := yhSLFItemCards(slot, yhArr(res))
	return items, len(items), len(items) >= 10, nil
}

func yhSLFHome(slot string) (map[string]interface{}, error) {
	res, err := yhSLFCall("/bigapi/video/homenew", nil)
	if err != nil {
		return nil, err
	}
	m := yhMap(res)
	if m == nil {
		return nil, fmt.Errorf("yh_slf: homenew empty")
	}
	return m, nil
}

func yhSLFCategories(slot string) []interface{} {
	out := []interface{}{categoryObj("new", "最新")}
	if home, err := yhSLFHome(slot); err == nil {
		for _, e := range yhArr(home["categories"]) {
			m := yhMap(e)
			if m == nil {
				continue
			}
			name := g5StrVal(m["name"])
			catID := g5StrVal(m["key"])
			if f := g5StrVal(m["filter"]); f != "" {
				var fm map[string]interface{}
				if json.Unmarshal([]byte(f), &fm) == nil {
					if c := g5StrVal(fm["catId"]); c != "" {
						catID = c
					}
				}
			}
			if name != "" && catID != "" {
				out = append(out, categoryObj("cat:"+catID, name))
			}
		}
	}
	// Rank orders come from SearchInfo (RankFragment/RankActivity verbatim).
	if res, err := yhSLFCall("/bigapi/video/searchinfo", nil); err == nil {
		if m := yhMap(res); m != nil {
			for _, e := range yhArr(m["order"]) {
				om := yhMap(e)
				if om == nil {
					continue
				}
				code, name := g5StrVal(om["code"]), g5StrVal(om["name"])
				if code != "" && name != "" {
					out = append(out, categoryObj("rank:"+code, name))
				}
			}
		}
	}
	out = append(out, categoryObj("special", "专题合集"))
	return out
}

func yhSLFCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case category == "" || category == "new":
		return yhSLFListCall(slot, "/bigapi/video/search", map[string]interface{}{"page": page})
	case strings.HasPrefix(category, "cat:"):
		return yhSLFListCall(slot, "/bigapi/video/search", map[string]interface{}{
			"page": page, "catId": strings.TrimPrefix(category, "cat:"),
		})
	case strings.HasPrefix(category, "rank:"):
		return yhSLFListCall(slot, "/bigapi/video/search", map[string]interface{}{
			"order": strings.TrimPrefix(category, "rank:"), "page": page,
		})
	case category == "special":
		res, err := yhSLFCall("/bigapi/video/special", map[string]interface{}{"page": page})
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
			out = append(out, makeDrama(slot, "dir:special:"+id, name, g5StrVal(m["img"]), "", "专题合集", g5StrVal(m["description"])))
		}
		return out, len(out), len(out) >= 10, nil
	case strings.HasPrefix(category, "dir:special:"):
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		res, err := yhSLFCall("/bigapi/video/specialdetail", map[string]interface{}{
			"id": strings.TrimPrefix(category, "dir:special:"),
		})
		if err != nil {
			return nil, 0, false, err
		}
		m := yhMap(res)
		if m == nil {
			return []interface{}{}, 0, false, nil
		}
		items := yhSLFItemCards(slot, yhArr(m["items"]))
		return items, len(items), false, nil
	}
	return yhSLFListCall(slot, "/bigapi/video/search", map[string]interface{}{"page": page})
}

func yhSLFDetailFetch(rawID string) (map[string]interface{}, error) {
	if v, ok := yhSLFCache.Load(rawID); ok {
		return v.(map[string]interface{}), nil
	}
	res, err := yhSLFCall("/bigapi/video/detail", map[string]interface{}{"id": rawID})
	if err != nil {
		return nil, err
	}
	m := yhMap(res)
	if m == nil {
		return nil, fmt.Errorf("yh_slf: detail empty for %s", rawID)
	}
	yhSLFCache.Store(rawID, m)
	return m, nil
}

func yhSLFDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "dir:special:") {
		items, _, _, err := yhSLFCatalog(slot, rawID, 1)
		if err != nil {
			return nil, err
		}
		d := makeDrama(slot, rawID, strings.TrimPrefix(rawID, "dir:special:"), "", "", "专题合集", "")
		if len(items) > 0 {
			d["related"] = items
		}
		return d, nil
	}
	rec, err := yhSLFDetailFetch(rawID)
	if err != nil {
		return nil, err
	}
	title := g5StrVal(rec["name"])
	desc := g5StrVal(rec["description"])
	d := makeDrama(slot, rawID, title, g5StrVal(rec["img"]), g5StrVal(rec["status"]), g5StrVal(rec["tagStr"]), desc)
	if a := g5StrVal(rec["author"]); a != "" {
		d["actor"] = a
		d["vod_actor"] = a
	}
	g5SetChapters(d, slot, rawID, []string{rawID}, []string{"正片"})
	return d, nil
}

func yhSLFResolve(slot, rawID string) (map[string]interface{}, error) {
	vid := rawID
	if i := strings.Index(vid, "$"); i >= 0 {
		vid = vid[i+1:]
	}
	rec, err := yhSLFDetailFetch(vid)
	if err != nil {
		return nil, err
	}
	if pt, ok := g5MapInt(rec, "point"); ok && pt > 0 {
		return nil, fmt.Errorf("yh_slf: %s is points-priced (point=%d), refused", vid, pt)
	}
	u := g5StrVal(rec["videoLink"])
	if u == "" {
		tips := g5StrVal(rec["canPlayTips"])
		return nil, fmt.Errorf("yh_slf: no play url for %s (%s)", vid, tips)
	}
	format, protocol := "mp4", ""
	if strings.Contains(u, ".m3u8") {
		format, protocol = "m3u8", "hls"
	}
	return playResult(u, slot, rawID, yhSLFUA, yhSLFBase+"/", format, protocol), nil
}

func yhSLFSearch(slot, kw string) ([]interface{}, error) {
	res, err := yhSLFCall("/bigapi/video/search", map[string]interface{}{"keywords": kw, "page": 1})
	if err != nil {
		return nil, err
	}
	return yhSLFItemCards(slot, yhArr(res)), nil
}

func yhSLFHeaders() map[string]string {
	return map[string]string{"User-Agent": yhSLFUA}
}
