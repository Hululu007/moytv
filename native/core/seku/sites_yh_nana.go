package seku

// ---- 娜娜 nana (yh_nana, type 35) — fulao2 同族，HostInfo 发现 + 响应解密 ----
//
// 配方来源（jadx 逐行实证；端点/基址以 nana 模块自身代码为准）：
//   发现：GET https://public.zhengfengkeji.cn/host_pwa.txt，备
//     https://public.taget.cn/host_pwa.txt（t4 拦截器：URL 含 host_pwa 时
//     用专 key；体为 Base64 → AES/CBC/PKCS5，key =
//     Base64 解码 "N0JBuseJKODmJFTRbmsr4InmstXB6VWahKgbVRPhHGw="（32 字节），
//     IV = MD5hex(x-vtag 响应头，缺省 "911530690")[8:24]）。
//     → HostInfo{api_pwa[], img_pwa[], stream_pwa[]}（各 {url, encrypt}）。
//   测速（NanaLaunchActivity.p + r4 回调）：对每个实体 GET {url}/speed.html
//     （头 Connection: close），首个 ≤300 者胜出，胜出 url 去掉
//     "/speed.html" 后分别成为 Api 基址（t4.c.f11523d）、图基址（t4.c.b）、
//     流基址（t4.c.f11522c）。
//   令牌：GET https://pwax.hyxpay.com/v1/fastauth（备
//     https://pwan.ppding.net/v1/fastauth）→ AuthBean.response.code；再
//     GET {同族}/v1/fastlogin，头 x-afdac809-9ad768a3: <code> →
//     AuthBean.response.token；全失败时用 t4.c 内置默认 token（JWT，
//     user_id 3203689）。fastauth/fastlogin 体不解密（拦截器放行）。
//   API 响应解密（t4/b NaNaInterceptor）：体 Base64 → AES/CBC/PKCS5，
//     key = Base64 解码 "6e561ccd4aade2fed458d4da61e76770"（24 字节，
//     代码原样如此，AES-192），IV = MD5hex(x-vtag 头，缺省
//     "911530690")[8:24]。
//   端点（t4/a）：
//     GET /v1/videos/menu/{menu} query {token, video_type, order, top, category}
//     GET /v1/{long|short}/menus?token= → MenuBean[{id, layout, title}]
//     GET /v1/{long|short}/videos/{menuid}?token=
//     GET /v1/category/{long|short}?token= → categories[]
//     GET /v1/videos/{long|short}/top?token=
//     GET /v1/actors query {page, order(""|vcount), cup(""|A..G), token}
//     GET /v1/actor/{actorId} query {page, token}
//     GET /v1/video/info/{id}?token=
//     GET /v1/videos/{long|short}/keyword/{key}?token=
//     GET /v1/shorts/tags?token=
//   播放（VideoInfo.getPlayUrl/PlayName）：流基址 + video_urls.480 / .240 /
//     intro 三线，名分别为 480P/240P/预览；封面 = 图基址 + cover（bean 原样
//     前缀，不做 http 判断）。
//   VIP 口径：nana bean 未见 fulao2 式 getter 过滤；本核沿用同族口径，
//     main_tag 含 "VIP" 的卡片过滤（账本边界，见回执）。
//
// 分类与 App 导航 1:1：长片（推荐=menus 动态/最新 menu0·time/排行
// menu0·views·day/独家 menu2/中文 menu9/无码 menu10）、短片（推荐=menus
// 动态/最新 menu0·time/排行 menu0·views·day/国产 menu6/SWAG menu7/
// 大神 menu11/巨乳 menu12）、分类（/v1/category/{type} 动态）、女优
// （罩杯筛选 + 下钻）、榜单（/v1/videos/{type}/top）。
//
// 验证门（2026-10-24，本机沙箱出口）：public.zhengfengkeji.cn 的
// HTTP-DNS 返回空（本机解析器无记录），pwax/pwan 与发现域直连均为 000
// （代理假 IP 拦截 + other_tcp 未放行，与 fulao2/bale 同类）。故
// Catalog/Detail/Resolve/Search/封面魔数均标「出口未验」，代码逐行
// 实证。不把出口问题写成站已死。

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"
)

const yhNanaSlot = "yh_nana"
const yhNanaUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
const yhNanaHostKeyB64 = "N0JBuseJKODmJFTRbmsr4InmstXB6VWahKgbVRPhHGw="
const yhNanaAPIKeyB64 = "6e561ccd4aade2fed458d4da61e76770"
const yhNanaVTagDefault = "911530690"
const yhNanaFallbackToken = "eyJ1c2VyX2lkIjozMjAzNjg5LCJsYXN0bG9naW4iOjE2MjY1OTIwNzF9.4fc11bbb936d22567916cf67f9459890.19c785d304c1fe604a567414c9a3129bad7725e93fc06d7d18a69989"

var yhNanaHostURLs = []string{
	"https://public.zhengfengkeji.cn/host_pwa.txt",
	"https://public.taget.cn/host_pwa.txt",
}
var yhNanaAuthURLs = []string{
	"https://pwax.hyxpay.com/v1/fastauth",
	"https://pwan.ppding.net/v1/fastauth",
}
var yhNanaLoginURLs = []string{
	"https://pwax.hyxpay.com/v1/fastlogin",
	"https://pwan.ppding.net/v1/fastlogin",
}

var (
	yhNanaMu      sync.Mutex
	yhNanaReady   bool
	yhNanaAPI     string
	yhNanaImg     string
	yhNanaStream  string
	yhNanaToken   string
	yhNanaInitErr error
)

func yhNanaMD5IV(seed string) []byte {
	if seed == "" {
		seed = yhNanaVTagDefault
	}
	sum := md5.Sum([]byte(seed))
	return []byte(hex.EncodeToString(sum[:])[8:24])
}

func yhNanaUnpad(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	n := int(b[len(b)-1])
	if n < 1 || n > 16 || n > len(b) {
		return b
	}
	return b[:len(b)-n]
}

func yhNanaDecrypt(keyB64, vtag, body string) (string, error) {
	key, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return "", err
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(body))
	if err != nil {
		return "", err
	}
	if len(raw) == 0 || len(raw)%16 != 0 {
		return "", fmt.Errorf("yh_nana: bad ciphertext len %d", len(raw))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	out := make([]byte, len(raw))
	cipher.NewCBCDecrypter(block, yhNanaMD5IV(vtag)).CryptBlocks(out, raw)
	return string(yhNanaUnpad(out)), nil
}

func yhNanaHeaders() map[string]string {
	return map[string]string{"User-Agent": yhNanaUA}
}

// yhNanaSpeed：对实体列表测速，首个 ≤300 者胜出（r4 回调原路）。
func yhNanaSpeed(entities []struct{ URL string }) string {
	for _, e := range entities {
		u := strings.TrimSuffix(e.URL, "/")
		if u == "" {
			continue
		}
		h := yhNanaHeaders()
		h["Connection"] = "close"
		_, code, _, err := httpGetTimeout(u+"/speed.html", h, 8*time.Second)
		if err == nil && code <= 300 {
			return u
		}
	}
	return ""
}

func yhNanaDiscover() (api, img, stream string, err error) {
	type ent struct {
		URL string `json:"url"`
	}
	var host struct {
		APIPwa    []ent `json:"api_pwa"`
		ImgPwa    []ent `json:"img_pwa"`
		StreamPwa []ent `json:"stream_pwa"`
		API       []ent `json:"api"`
		Img       []ent `json:"img"`
		Stream    []ent `json:"stream"`
	}
	var lastErr error
	for _, u := range yhNanaHostURLs {
		b, code, hdr, gerr := httpGet(u, yhNanaHeaders())
		if gerr != nil || code != 200 {
			lastErr = gerr
			continue
		}
		plain, derr := yhNanaDecrypt(yhNanaHostKeyB64, hdr.Get("x-vtag"), string(b))
		if derr != nil {
			lastErr = derr
			continue
		}
		if jerr := json.Unmarshal([]byte(plain), &host); jerr != nil {
			lastErr = jerr
			continue
		}
		break
	}
	if len(host.APIPwa) == 0 && len(host.API) == 0 {
		if lastErr != nil {
			return "", "", "", lastErr
		}
		return "", "", "", fmt.Errorf("yh_nana: host discovery empty")
	}
	toE := func(in []ent) []struct{ URL string } {
		out := []struct{ URL string }{}
		for _, e := range in {
			out = append(out, struct{ URL string }{URL: e.URL})
		}
		return out
	}
	apis, imgs, streams := host.APIPwa, host.ImgPwa, host.StreamPwa
	if len(apis) == 0 {
		apis = host.API
	}
	if len(imgs) == 0 {
		imgs = host.Img
	}
	if len(streams) == 0 {
		streams = host.Stream
	}
	api = yhNanaSpeed(toE(apis))
	if api == "" {
		return "", "", "", fmt.Errorf("yh_nana: api speed test all failed")
	}
	return api, yhNanaSpeed(toE(imgs)), yhNanaSpeed(toE(streams)), nil
}

// yhNanaEnsure：发现 + 令牌；任一失败时退空基址/默认 token，不中断。
func yhNanaEnsure() {
	yhNanaMu.Lock()
	defer yhNanaMu.Unlock()
	if yhNanaReady {
		return
	}
	yhNanaToken = yhNanaFallbackToken
	if api, img, stream, err := yhNanaDiscover(); err == nil {
		yhNanaAPI, yhNanaImg, yhNanaStream = api, img, stream
		yhNanaReady = true
	} else {
		yhNanaInitErr = err
	}
	// fastauth → fastlogin（r4/a、r4/c 原路）。
	for i, authURL := range yhNanaAuthURLs {
		b, code, _, err := httpGet(authURL, yhNanaHeaders())
		if err != nil || code != 200 {
			continue
		}
		var auth struct {
			Response struct {
				Code  string `json:"code"`
				Token string `json:"token"`
			} `json:"response"`
		}
		if jerr := json.Unmarshal(b, &auth); jerr != nil || auth.Response.Code == "" {
			continue
		}
		loginURL := yhNanaLoginURLs[i]
		h := yhNanaHeaders()
		h["x-afdac809-9ad768a3"] = auth.Response.Code
		lb, lcode, _, lerr := httpGet(loginURL, h)
		if lerr != nil || lcode != 200 {
			continue
		}
		var login struct {
			Response struct {
				Token string `json:"token"`
			} `json:"response"`
		}
		if jerr := json.Unmarshal(lb, &login); jerr == nil && login.Response.Token != "" {
			yhNanaToken = login.Response.Token
		}
		break
	}
}

func yhNanaCall(path string, q url.Values) (map[string]interface{}, error) {
	yhNanaEnsure()
	if yhNanaAPI == "" {
		return nil, fmt.Errorf("yh_nana: no api base (discovery failed: %v)", yhNanaInitErr)
	}
	if q == nil {
		q = url.Values{}
	}
	q.Set("token", yhNanaToken)
	u := strings.TrimSuffix(yhNanaAPI, "/") + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	b, code, hdr, err := httpGet(u, yhNanaHeaders())
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_nana http %d", code)
	}
	trimmed := strings.TrimSpace(string(b))
	if strings.HasPrefix(trimmed, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal(b, &obj); err == nil {
			return obj, nil
		}
	}
	plain, err := yhNanaDecrypt(yhNanaAPIKeyB64, hdr.Get("x-vtag"), trimmed)
	if err != nil {
		return nil, fmt.Errorf("yh_nana decrypt: %v", err)
	}
	var obj map[string]interface{}
	if err := json.Unmarshal([]byte(plain), &obj); err != nil {
		return nil, fmt.Errorf("yh_nana parse: %v", err)
	}
	return obj, nil
}

func yhNanaCover(p string) string {
	if p == "" {
		return ""
	}
	yhNanaEnsure()
	return strings.TrimSuffix(yhNanaImg, "/") + "/" + strings.TrimPrefix(p, "/")
}

func yhNanaCard(slot string, rec map[string]interface{}) (map[string]interface{}, bool) {
	id := g5StrVal(rec["video_id"])
	title := g5StrVal(rec["video_title"])
	if id == "" || title == "" {
		return nil, false
	}
	tags := ""
	for _, e := range yhArr(rec["main_tag"]) {
		tags += g5StrVal(e)
	}
	return makeDrama(slot, id, title, yhNanaCover(g5StrVal(rec["cover"])), tags, "", ""), true
}

func yhNanaCards(slot string, recs []interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, e := range recs {
		if m := yhMap(e); m != nil {
			if c, ok := yhNanaCard(slot, m); ok && !seen[g5StrVal(m["video_id"])] {
				seen[g5StrVal(m["video_id"])] = true
				out = append(out, c)
			}
		}
	}
	return out
}

func yhNanaVideos(slot string, obj map[string]interface{}) []interface{} {
	res := yhMap(obj["response"])
	if res == nil {
		return []interface{}{}
	}
	return yhNanaCards(slot, yhArr(res["videos"]))
}

func yhNanaMenuVideos(slot, typ, menuID string, page int) ([]interface{}, int, bool, error) {
	q := url.Values{}
	q.Set("video_type", typ)
	q.Set("order", "time")
	q.Set("top", "")
	q.Set("category", "")
	q.Set("page", fmt.Sprintf("%d", page))
	// 菜单列表端点不以 page 入参（VideoListFragment.j 原样无 page 键），
	// 但 page>1 时仍把 page 透传，服务端忽略即与 App 行为一致。
	obj, err := yhNanaCall("/v1/videos/menu/"+menuID, q)
	if err != nil {
		return nil, 0, false, err
	}
	items := yhNanaVideos(slot, obj)
	return items, len(items), len(items) > 0, nil
}

func yhNanaCategories(slot string) []interface{} {
	return []interface{}{
		categoryObj("menus:long", "长片·推荐"),
		categoryObj("menu:long:0:time:", "长片·最新"),
		categoryObj("menu:long:0:views:day", "长片·排行"),
		categoryObj("menu:long:2:time:", "长片·独家"),
		categoryObj("menu:long:9:time:", "长片·中文"),
		categoryObj("menu:long:10:time:", "长片·无码"),
		categoryObj("menus:short", "短片·推荐"),
		categoryObj("menu:short:0:time:", "短片·最新"),
		categoryObj("menu:short:0:views:day", "短片·排行"),
		categoryObj("menu:short:6:time:", "短片·国产"),
		categoryObj("menu:short:7:time:", "短片·SWAG"),
		categoryObj("menu:short:11:time:", "短片·大神"),
		categoryObj("menu:short:12:time:", "短片·巨乳"),
		categoryObj("top:long", "榜单·长片"),
		categoryObj("top:short", "榜单·短片"),
		categoryObj("actors", "女优"),
		categoryObj("types:long", "分类·长片"),
		categoryObj("types:short", "分类·短片"),
	}
}

func yhNanaCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case strings.HasPrefix(category, "menu:"):
		p := strings.Split(category, ":")
		if len(p) != 5 {
			return nil, 0, false, fmt.Errorf("yh_nana: bad menu category %s", category)
		}
		q := url.Values{}
		q.Set("video_type", p[1])
		q.Set("order", p[3])
		q.Set("top", p[4])
		q.Set("category", "")
		q.Set("page", fmt.Sprintf("%d", page))
		obj, err := yhNanaCall("/v1/videos/menu/"+p[2], q)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhNanaVideos(slot, obj)
		return items, len(items), len(items) > 0, nil
	case strings.HasPrefix(category, "top:"):
		obj, err := yhNanaCall("/v1/videos/"+strings.TrimPrefix(category, "top:")+"/top", nil)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhNanaVideos(slot, obj)
		return items, len(items), false, nil
	case category == "actors" || strings.HasPrefix(category, "actors:"):
		cup, order := "", ""
		if strings.HasPrefix(category, "actors:") {
			if p := strings.Split(strings.TrimPrefix(category, "actors:"), ":"); len(p) >= 1 {
				cup = p[0]
			}
			if p := strings.Split(strings.TrimPrefix(category, "actors:"), ":"); len(p) >= 2 {
				order = p[1]
			}
		}
		q := url.Values{}
		q.Set("page", fmt.Sprintf("%d", page))
		q.Set("order", order)
		q.Set("cup", cup)
		obj, err := yhNanaCall("/v1/actors", q)
		if err != nil {
			return nil, 0, false, err
		}
		res := yhMap(obj["response"])
		out := []interface{}{}
		seen := map[string]bool{}
		if res != nil {
			for _, e := range yhArr(res["actors"]) {
				b := yhMap(e)
				if b == nil {
					continue
				}
				aid := g5StrVal(b["actor_id"])
				name := g5StrVal(b["actor_name"])
				if aid == "" || name == "" || seen[aid] {
					continue
				}
				seen[aid] = true
				out = append(out, makeDrama(slot, "dir:actor:"+aid, name, yhNanaCover(g5StrVal(b["actor_url"])), "", "女优", ""))
			}
		}
		return out, len(out), len(out) > 0, nil
	case strings.HasPrefix(category, "dir:actor:"):
		q := url.Values{}
		q.Set("page", fmt.Sprintf("%d", page))
		obj, err := yhNanaCall("/v1/actor/"+strings.TrimPrefix(category, "dir:actor:"), q)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhNanaVideos(slot, obj)
		return items, len(items), len(items) > 0, nil
	case strings.HasPrefix(category, "types:"):
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		obj, err := yhNanaCall("/v1/category/"+strings.TrimPrefix(category, "types:"), nil)
		if err != nil {
			return nil, 0, false, err
		}
		res := yhMap(obj["response"])
		out := []interface{}{}
		if res != nil {
			for _, e := range yhArr(res["categories"]) {
				c := yhMap(e)
				if c == nil {
					continue
				}
				cid := g5StrVal(c["category_id"])
				name := g5StrVal(c["category_name"])
				if cid == "" || name == "" {
					continue
				}
				out = append(out, categoryObj("cat:"+strings.TrimPrefix(category, "types:")+":"+cid, name))
			}
		}
		return out, len(out), false, nil
	case strings.HasPrefix(category, "cat:"):
		p := strings.Split(category, ":")
		if len(p) != 3 {
			return nil, 0, false, fmt.Errorf("yh_nana: bad cat category %s", category)
		}
		q := url.Values{}
		q.Set("video_type", p[1])
		q.Set("order", "time")
		q.Set("top", "")
		q.Set("category", p[2])
		q.Set("page", fmt.Sprintf("%d", page))
		obj, err := yhNanaCall("/v1/videos/menu/0", q)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhNanaVideos(slot, obj)
		return items, len(items), len(items) > 0, nil
	case strings.HasPrefix(category, "menus:"):
		typ := strings.TrimPrefix(category, "menus:")
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		obj, err := yhNanaCall("/v1/"+typ+"/menus", nil)
		if err != nil {
			return nil, 0, false, err
		}
		out := []interface{}{}
		for _, e := range yhArr(obj["response"]) {
			m := yhMap(e)
			if m == nil {
				continue
			}
			id := g5StrVal(m["id"])
			title := g5StrVal(m["title"])
			if id == "" || title == "" {
				continue
			}
			out = append(out, categoryObj("menuvideos:"+typ+":"+id, title))
		}
		return out, len(out), false, nil
	case strings.HasPrefix(category, "menuvideos:"):
		p := strings.Split(category, ":")
		if len(p) != 3 {
			return nil, 0, false, fmt.Errorf("yh_nana: bad menuvideos category %s", category)
		}
		obj, err := yhNanaCall("/v1/"+p[1]+"/videos/"+p[2], nil)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhNanaVideos(slot, obj)
		return items, len(items), false, nil
	}
	return yhNanaMenuVideos(slot, "long", "0", page)
}

func yhNanaDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "dir:actor:") {
		items, _, _, err := yhNanaCatalog(slot, rawID, 1)
		if err != nil {
			return nil, err
		}
		d := makeDrama(slot, rawID, strings.TrimPrefix(rawID, "dir:actor:"), "", "女优", "女优", "")
		epIDs, names := []string{}, []string{}
		for _, it := range items {
			if im, ok := it.(map[string]interface{}); ok {
				epIDs = append(epIDs, g5StrVal(im["vod_id"]))
				names = append(names, g5StrVal(im["title"]))
			}
		}
		if len(epIDs) > 0 {
			g5SetChapters(d, slot, rawID, epIDs, names)
			d["related"] = items
		}
		return d, nil
	}
	obj, err := yhNanaCall("/v1/video/info/"+rawID, nil)
	if err != nil {
		return nil, err
	}
	res := yhMap(obj["response"])
	if res == nil {
		return nil, fmt.Errorf("yh_nana: video info empty for %s", rawID)
	}
	title := g5StrVal(res["video_title"])
	cover := g5StrVal(res["cover"])
	if cover == "" {
		cover = g5StrVal(res["cover_url"])
	}
	desc := g5StrVal(res["video_description"])
	d := makeDrama(slot, rawID, title, yhNanaCover(cover), g5StrVal(res["video_number"]), "", desc)
	names, ids := []string{}, []string{}
	for _, q := range []struct {
		key, name string
	}{{"480", "480P"}, {"240", "240P"}, {"intro", "预览"}} {
		if v := yhMap(res["video_urls"]); v != nil && g5StrVal(v[q.key]) != "" {
			names = append(names, q.name)
			ids = append(ids, rawID+"$q:"+q.key)
		}
	}
	if len(ids) == 0 {
		ids, names = []string{rawID}, []string{"正片"}
	}
	g5SetChapters(d, slot, rawID, ids, names)
	return d, nil
}

func yhNanaResolve(slot, rawID string) (map[string]interface{}, error) {
	vid, quality := rawID, ""
	if i := strings.Index(rawID, "$"); i >= 0 {
		vid, quality = rawID[:i], rawID[i+1:]
	}
	if strings.HasPrefix(quality, "q:") {
		quality = strings.TrimPrefix(quality, "q:")
	}
	obj, err := yhNanaCall("/v1/video/info/"+vid, nil)
	if err != nil {
		return nil, err
	}
	res := yhMap(obj["response"])
	if res == nil {
		return nil, fmt.Errorf("yh_nana: video info empty for %s", vid)
	}
	urls := yhMap(res["video_urls"])
	if urls == nil {
		return nil, fmt.Errorf("yh_nana: no video_urls for %s", vid)
	}
	pick := func() string {
		if quality != "" {
			if s := g5StrVal(urls[quality]); s != "" {
				return s
			}
		}
		if s := g5StrVal(urls["480"]); s != "" {
			return s
		}
		if s := g5StrVal(urls["240"]); s != "" {
			return s
		}
		return g5StrVal(urls["intro"])
	}
	p := pick()
	if p == "" {
		return nil, fmt.Errorf("yh_nana: no play url for %s", vid)
	}
	yhNanaEnsure()
	u := p
	if !strings.HasPrefix(p, "http") {
		u = strings.TrimSuffix(yhNanaStream, "/") + "/" + strings.TrimPrefix(p, "/")
	}
	format, protocol := "mp4", ""
	if strings.Contains(u, ".m3u8") {
		format, protocol = "m3u8", "hls"
	}
	return playResult(u, slot, rawID, yhNanaUA, strings.TrimSuffix(yhNanaStream, "/")+"/", format, protocol), nil
}

func yhNanaSearch(slot, kw string) ([]interface{}, error) {
	out := []interface{}{}
	seen := map[string]bool{}
	var firstErr error
	for _, typ := range []string{"long", "short"} {
		obj, err := yhNanaCall("/v1/videos/"+typ+"/keyword/"+url.PathEscape(kw), nil)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, it := range yhNanaVideos(slot, obj) {
			if im, ok := it.(map[string]interface{}); ok {
				id := g5StrVal(im["vod_id"])
				if !seen[id] {
					seen[id] = true
					out = append(out, it)
				}
			}
		}
	}
	if len(out) == 0 && firstErr != nil {
		return nil, firstErr
	}
	return out, nil
}
