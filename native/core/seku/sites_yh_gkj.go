package seku

// ---- 观看局 gkj (yh_gkj) — 漫画/动漫 JSON API + 响应签名解密 ----
//
// 配方出欲火 APK jadx 实证（d2/c ApiService + d2/e NetHelper +
// d2/d GKJInterceptor + d2/a/b AES 工具 + gkj 各 Fragment/Activity）：
//   基址（节点二选一，GkjLauncherActivity 实证）：
//     节点 1 https://gkj5.zguvink.com（h6.b C，URL_GKJ）
//     节点 2 https://tu5.wednf.com（h6.b D，URL_GKJ2）
//     Go 侧按节点 1→2 顺序回退（App 内为用户手动选节点）。
//   /api/* 为表单 POST（FormUrlEncoded + FieldMap），/cms/* 为 GET：
//     POST /api/view-module
//       {global_type, location:"index", page:"1", limit:"10"}
//       -> ViewModel（ComicTypeFragment 首页模块，j()）
//     POST /api/special-lists {global_type, limit:"16", page}
//       -> ComicList{lists.data[]}（CgFragment，g()）
//     POST /api/comic-lists
//       {global_type, type_id, state, is_pay, sort, limit:"12", page}
//       -> ComicList（ScreenActivity 筛选，a()）
//     POST /api/comic-lists {comic_title:<词>, limit:"14", page}
//       -> ComicList（SearchActivity 搜索，a()）
//     POST /api/comic-rank {global_type}
//       -> ComicList{data[]}（RankFragment，c()；榜单三档：
//       hanman / hman / anime，RankActivity 实证）
//     POST /api/guess-like {global_type:"hanman", limit:"10", page:"1"}
//       -> ComicList（SearchActivity 猜你喜欢，b()）
//     POST /api/comic-image
//       {comic_id, comic_resource_id, global_type:"anime",
//        index:"1", limit:"10000", page:"1"}
//       -> AnimeRead{play_url}（gkj PlayActivity 动漫播放，f()）
//     GET /cms/api/app/conf?newver=1
//       -> ConfBean{content.data.specialNav[{id,navName}]}（首页页签，i()）
//     GET /cms/api/special/nav/article/list
//       ?navId=<id>&page=<n-1>&pageSize=10
//       -> NavBean（HomeTypeFragment，e()；App 页码 0 起）
//     GET /cms/api/cartoon/detail?id=<id>
//       -> ComicDetail{data{chapters[{id,index,name,playIs}],...}}（k()）
//     GET /cms/api/cartoon/play?cid=<章节id>
//       + Header authorization: <内置 Bearer token>
//       -> ComicRead{content.data}（ComicReadActivity 漫画图，m()；
//       content.data 为逗号分隔的图片路径，非 http 者前缀拼
//       基址 + "/resources/"，ComicRead.getDataList() 实证）
//     POST /cms/api/article/search/list（JSON 体）
//       {type, page(0起), pageSize:20, searchName:<词>}
//       -> SpecialBean（SearchResultFragment，d()；type "1"=视频、
//       "0"=漫画，Go 搜索主腿用 comic-lists，此口径备查）
//   响应解密（d2/d 拦截器，逐行复刻）：响应 JSON 若含非空
//     "signKey"，则正文替换为 AES-ECB/PKCS7 解密结果，密钥
//     "0123Encryptionke"，密文先 Base64 解码（h6.e.b 实证）。
//   封面加密（e2/d Glide 加载器实证）：URL 以 ".ceb" 结尾的图片
//     为 AES-ECB 加密字节，密钥 "wPK8CxWaOwPuVzgs"，CoverFetch
//     解密后验明文魔数，解密失败回落原字节。
//   选集分流（未在 jadx 中见 playIs 取值语义，Go 侧如实标注）：
//     章节 playIs=1 时走动漫视频（comic-image），否则走漫画图
//     （cartoon/play 首图）；comic-image 空回退 cartoon/play。
//   付费：列表项 is_pay=1 的作品，Resolve 直接拒解析（不播付费
//     内容）；目录卡片保留并标注「付费」。
//   App 导航：GKJActivity 底部为首页 + 开发中占位（DevelopFragment），
//     首页页签来自 conf specialNav（动态，须活体拉取）；Go 侧
//     Categories = specialNav（动态拉取，失败时回退固定四维）+
//     固定漫画四维（comic/hanman/anime/cg）+ 三榜。
//
// 验证门（2026-10-24 本机实测）：
//   直连 gkj5.zguvink.com、tu5.wednf.com 均 000（本机沙箱对两域
//   返回假 IP 段、连接超时）；独立公共 DNS 双路核查：Google DNS
//   与 Cloudflare DNS 对 gkj5.zguvink.com 均回 NXDOMAIN，对
//   tu5.wednf.com 均回 SERVFAIL（无解析答案），HTTP-DNS
//   （119.28.28.28）回 "0"（无记录）。即：两基址在公共解析层面
//   均已不可用，非仅本机出口问题——代码按 jadx 逐行实证实现，
//   活体冒烟须待基址恢复或新节点下发后补验。各腿状态：
//   Categories（代码级，specialNav 动态 + 固定维）/ Catalog /
//   Detail / Resolve / Search 均为代码实证、活体未验（基址
//   NXDOMAIN/SERVFAIL）。封面：.ceb 加密形态已实现 CoverFetch，
//   明文魔数校验待活体补验。

import (
	"bytes"
	"crypto/aes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
)

var yhGKJBases = []string{"https://gkj5.zguvink.com", "https://tu5.wednf.com"}

const yhGKJRespKey = "0123Encryptionke"
const yhGKJImgKey = "wPK8CxWaOwPuVzgs"

// yhGKJAuth 为 App 内置 cartoon/play 授权头（ComicReadActivity
// f2812i，jadx 实证的静态 Bearer token；占位符由产件脚本在写盘
// 时以 jadx 解码值替换，源文件内不留占位）。
const yhGKJAuth = "Bearer eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiJHdWVzdC1BNTY3OTQ3MCIsImNsYWltcyI6W3siYXV0aG9yaXR5IjoiR3Vlc3QtQTU2Nzk0NzAjMjU1MTk4I2IyNDQ3MTc0YTNjMDRlOGJiZjNlZmVkYzU1Y2IxNGMwIn0seyJhdXRob3JpdHkiOiJVU0VSIn0seyJhdXRob3JpdHkiOiIxNjY2NzA4MjE3NTA1In1dfQ.ZH8F5HZ3vMVsjhtttlHnWBoffOXcTxPqBIkNNVKItUvU2-_8I_H1zADBtnz-qMCAy87UC8xGfpecnm5Fiu-LCQ"

const yhGKJUA = "okhttp/4.9.0"

var yhGKJCache sync.Map // work id -> raw list item (is_pay lookup)

func yhGKJHeaders() map[string]string {
	return map[string]string{
		"User-Agent": yhGKJUA,
		"Accept":     "application/json, text/plain, */*",
	}
}

func yhGKJAESDecrypt(key string, ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher([]byte(key))
	if err != nil {
		return nil, err
	}
	if len(ciphertext)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("yh_gkj: bad ciphertext len %d", len(ciphertext))
	}
	out := make([]byte, len(ciphertext))
	for i := 0; i < len(ciphertext); i += block.BlockSize() {
		block.Decrypt(out[i:i+block.BlockSize()], ciphertext[i:i+block.BlockSize()])
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("yh_gkj: empty plaintext")
	}
	pad := int(out[len(out)-1])
	if pad < 1 || pad > block.BlockSize() || pad > len(out) {
		return nil, fmt.Errorf("yh_gkj: bad pkcs7 pad")
	}
	return out[:len(out)-pad], nil
}

// yhGKJUnwrap 复刻 d2/d：含 signKey 时解密替换正文。
func yhGKJUnwrap(b []byte) ([]byte, error) {
	var obj map[string]interface{}
	if err := json.Unmarshal(b, &obj); err != nil {
		return b, nil
	}
	sk := g5StrVal(obj["signKey"])
	if sk == "" {
		return b, nil
	}
	raw, err := base64.StdEncoding.DecodeString(sk)
	if err != nil {
		return nil, fmt.Errorf("yh_gkj: signKey b64: %v", err)
	}
	plain, err := yhGKJAESDecrypt(yhGKJRespKey, raw)
	if err != nil {
		return nil, err
	}
	return plain, nil
}

func yhGKJParse(b []byte) (map[string]interface{}, error) {
	plain, err := yhGKJUnwrap(b)
	if err != nil {
		return nil, err
	}
	var obj map[string]interface{}
	if err := json.Unmarshal(plain, &obj); err != nil {
		return nil, fmt.Errorf("yh_gkj parse: %v", err)
	}
	return obj, nil
}

func yhGKJForm(path string, form url.Values) (map[string]interface{}, error) {
	var lastErr error
	for _, base := range yhGKJBases {
		h := yhGKJHeaders()
		h["Content-Type"] = "application/x-www-form-urlencoded"
		b, code, _, err := httpDo("POST", base+path, bytes.NewReader([]byte(form.Encode())), h)
		if err != nil {
			lastErr = err
			continue
		}
		if code != 200 {
			lastErr = fmt.Errorf("yh_gkj http %d", code)
			continue
		}
		return yhGKJParse(b)
	}
	return nil, lastErr
}

func yhGKJGet(path string, q url.Values) (map[string]interface{}, error) {
	var lastErr error
	for _, base := range yhGKJBases {
		rawurl := base + path
		if len(q) > 0 {
			rawurl += "?" + q.Encode()
		}
		b, code, _, err := httpGet(rawurl, yhGKJHeaders())
		if err != nil {
			lastErr = err
			continue
		}
		if code != 200 {
			lastErr = fmt.Errorf("yh_gkj http %d", code)
			continue
		}
		return yhGKJParse(b)
	}
	return nil, lastErr
}

func yhGKJComicCards(slot string, recs []interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, e := range recs {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		id := g5StrVal(rec["id"])
		title := g5StrVal(rec["title"])
		if title == "" {
			title = g5StrVal(rec["name"])
		}
		if title == "" {
			title = g5StrVal(rec["nameCn"])
		}
		if id == "" || title == "" || seen[id] {
			continue
		}
		seen[id] = true
		yhGKJCache.Store(id, rec)
		cover := g5StrVal(rec["cover_url"])
		if cover == "" {
			cover = g5StrVal(rec["coverS"])
		}
		remark := ""
		if g5StrVal(rec["is_pay"]) == "1" {
			remark = "付费"
		} else if s := g5StrVal(rec["score"]); s != "" {
			remark = s + "分"
		}
		out = append(out, makeDrama(slot, "comic:"+id, title, cover, remark, g5StrVal(rec["global_type"]), g5StrVal(rec["intro"])))
	}
	return out
}

// yhGKJListItems 兼容 ComicList 两种装箱：lists.data[] 与 data[]。
func yhGKJListItems(obj map[string]interface{}) []interface{} {
	if lists := yhMap(obj["lists"]); lists != nil {
		if arr := yhArr(lists["data"]); arr != nil {
			return arr
		}
	}
	if arr := yhArr(obj["data"]); arr != nil {
		return arr
	}
	return []interface{}{}
}

func yhGKJCategories(slot string) []interface{} {
	out := []interface{}{}
	if obj, err := yhGKJGet("/cms/api/app/conf", url.Values{"newver": {"1"}}); err == nil {
		if content := yhMap(obj["content"]); content != nil {
			if data := yhMap(content["data"]); data != nil {
				for _, e := range yhArr(data["specialNav"]) {
					nm := yhMap(e)
					if nm == nil {
						continue
					}
					if id := g5StrVal(nm["id"]); id != "" {
						out = append(out, categoryObj("nav:"+id, g5StrVal(nm["navName"])))
					}
				}
			}
		}
	}
	out = append(out,
		categoryObj("comic", "漫画"),
		categoryObj("hanman", "韩漫"),
		categoryObj("anime", "动漫"),
		categoryObj("cg", "CG"),
		categoryObj("rank:hanman", "榜单·韩漫"),
		categoryObj("rank:hman", "榜单·H漫"),
		categoryObj("rank:anime", "榜单·动漫"),
	)
	return out
}

func yhGKJNavCards(slot string, obj map[string]interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	var articles []interface{}
	if data := yhMap(obj["data"]); data != nil {
		articles = yhArr(data["articleVOS"])
		if articles == nil {
			articles = yhArr(data["articleVO"])
		}
	} else {
		articles = yhArr(obj["data"])
	}
	for _, e := range articles {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		id := g5StrVal(rec["id"])
		title := g5StrVal(rec["nameCn"])
		if title == "" {
			title = g5StrVal(rec["name"])
		}
		if id == "" || title == "" || seen[id] {
			continue
		}
		seen[id] = true
		yhGKJCache.Store(id, rec)
		cover := g5StrVal(rec["cover"])
		if cover == "" {
			cover = g5StrVal(rec["coverS"])
		}
		remark := g5StrVal(rec["videoTime"])
		out = append(out, makeDrama(slot, "navart:"+id, title, cover, remark, "专题文章", g5StrVal(rec["info"])))
	}
	return out
}

func yhGKJCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case strings.HasPrefix(category, "nav:"):
		q := url.Values{}
		q.Set("navId", strings.TrimPrefix(category, "nav:"))
		q.Set("page", fmt.Sprintf("%d", page-1))
		q.Set("pageSize", "10")
		obj, err := yhGKJGet("/cms/api/special/nav/article/list", q)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhGKJNavCards(slot, obj)
		return items, 0, len(items) > 0, nil
	case category == "" || category == "comic" || category == "hanman" || category == "anime" || category == "cg":
		gt := category
		if gt == "" {
			gt = "comic"
		}
		form := url.Values{}
		form.Set("global_type", gt)
		form.Set("limit", "16")
		form.Set("page", fmt.Sprintf("%d", page))
		obj, err := yhGKJForm("/api/special-lists", form)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhGKJComicCards(slot, yhGKJListItems(obj))
		return items, 0, len(items) > 0, nil
	case strings.HasPrefix(category, "rank:"):
		form := url.Values{}
		form.Set("global_type", strings.TrimPrefix(category, "rank:"))
		obj, err := yhGKJForm("/api/comic-rank", form)
		if err != nil {
			return nil, 0, false, err
		}
		items := yhGKJComicCards(slot, yhGKJListItems(obj))
		return items, 0, false, nil
	}
	return nil, 0, false, fmt.Errorf("yh_gkj: unknown category %s", category)
}

func yhGKJDetailRaw(id string) (map[string]interface{}, error) {
	q := url.Values{}
	q.Set("id", id)
	obj, err := yhGKJGet("/cms/api/cartoon/detail", q)
	if err != nil {
		return nil, err
	}
	data := yhMap(obj["data"])
	if data == nil {
		return nil, fmt.Errorf("yh_gkj: detail empty for %s", id)
	}
	return data, nil
}

func yhGKJDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "navart:") {
		id := strings.TrimPrefix(rawID, "navart:")
		if v, ok := yhGKJCache.Load(id); ok {
			if rec, ok := v.(map[string]interface{}); ok {
				title := g5StrVal(rec["nameCn"])
				if title == "" {
					title = g5StrVal(rec["name"])
				}
				cover := g5StrVal(rec["cover"])
				if cover == "" {
					cover = g5StrVal(rec["coverS"])
				}
				d := makeDrama(slot, rawID, title, cover, g5StrVal(rec["videoTime"]), "专题文章", g5StrVal(rec["info"]))
				g5SetChapters(d, slot, rawID, []string{rawID}, []string{"正片"})
				return d, nil
			}
		}
		return nil, fmt.Errorf("yh_gkj: navart %s not in cache (browse its nav category first)", rawID)
	}
	if !strings.HasPrefix(rawID, "comic:") {
		return nil, fmt.Errorf("yh_gkj: unknown id %s", rawID)
	}
	id := strings.TrimPrefix(rawID, "comic:")
	data, err := yhGKJDetailRaw(id)
	if err != nil {
		return nil, err
	}
	title := g5StrVal(data["nameCn"])
	if title == "" {
		title = g5StrVal(data["name"])
	}
	cover := g5StrVal(data["coverS"])
	if cover == "" {
		cover = g5StrVal(data["coverH"])
	}
	d := makeDrama(slot, rawID, title, cover, "", g5StrVal(data["language"]), g5StrVal(data["info"]))
	epIDs := []string{}
	epNames := []string{}
	for _, ch := range yhArr(data["chapters"]) {
		cm := yhMap(ch)
		if cm == nil {
			continue
		}
		cid := g5StrVal(cm["id"])
		if cid == "" {
			continue
		}
		name := g5StrVal(cm["name"])
		if name == "" {
			name = "第" + g5StrVal(cm["index"]) + "话"
		}
		epIDs = append(epIDs, "comic:"+id+"#"+cid)
		epNames = append(epNames, name)
	}
	if len(epIDs) > 0 {
		g5SetChapters(d, slot, rawID, epIDs, epNames)
	}
	rel := []interface{}{}
	for _, e := range yhArr(data["recommend"]) {
		rel = append(rel, e)
	}
	if len(rel) > 0 {
		d["related"] = rel
	}
	return d, nil
}

// yhGKJCartoonImages 调 cartoon/play，返回图片地址列表。
func yhGKJCartoonImages(chapterID string) ([]string, error) {
	var lastErr error
	for _, base := range yhGKJBases {
		h := yhGKJHeaders()
		h["authorization"] = yhGKJAuth
		b, code, _, err := httpGet(base+"/cms/api/cartoon/play?cid="+url.QueryEscape(chapterID), h)
		if err != nil {
			lastErr = err
			continue
		}
		if code != 200 {
			lastErr = fmt.Errorf("yh_gkj http %d", code)
			continue
		}
		obj, err := yhGKJParse(b)
		if err != nil {
			return nil, err
		}
		content := yhMap(obj["content"])
		if content == nil {
			return nil, fmt.Errorf("yh_gkj: cartoon/play empty for %s", chapterID)
		}
		data := g5StrVal(content["data"])
		imgs := []string{}
		for _, part := range strings.Split(data, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			if strings.HasPrefix(part, "http") {
				imgs = append(imgs, part)
			} else {
				imgs = append(imgs, base+"/resources/"+part)
			}
		}
		return imgs, nil
	}
	return nil, lastErr
}

func yhGKJResolve(slot, rawID string) (map[string]interface{}, error) {
	ep := rawID
	if i := strings.Index(ep, "$"); i >= 0 {
		ep = ep[i+1:]
	}
	if strings.HasPrefix(ep, "navart:") {
		id := strings.TrimPrefix(ep, "navart:")
		if v, ok := yhGKJCache.Load(id); ok {
			if rec, ok := v.(map[string]interface{}); ok {
				res := yhArr(rec["resources"])
				if len(res) == 0 {
					if s := g5StrVal(rec["resources"]); s != "" {
						res = []interface{}{s}
					}
				}
				for _, r := range res {
					if rm := yhMap(r); rm != nil {
						if u := g5StrVal(rm["url"]); u != "" {
							return playResult(u, slot, rawID, yhGKJUA, yhGKJBases[0]+"/", "mp4", ""), nil
						}
					} else if u := g5StrVal(r); u != "" {
						return playResult(u, slot, rawID, yhGKJUA, yhGKJBases[0]+"/", "mp4", ""), nil
					}
				}
			}
		}
		return nil, fmt.Errorf("yh_gkj: navart %s has no cached play resources", rawID)
	}
	if !strings.HasPrefix(ep, "comic:") {
		return nil, fmt.Errorf("yh_gkj: unknown id %s", rawID)
	}
	rest := strings.TrimPrefix(ep, "comic:")
	workID, chapterID, _ := strings.Cut(rest, "#")
	if chapterID == "" {
		return nil, fmt.Errorf("yh_gkj: chapter id required for %s", rawID)
	}
	if v, ok := yhGKJCache.Load(workID); ok {
		if rec, ok := v.(map[string]interface{}); ok {
			if g5StrVal(rec["is_pay"]) == "1" {
				return nil, fmt.Errorf("yh_gkj: paid work refused (is_pay=1)")
			}
		}
	}
	// 动漫视频腿：playIs=1 的章节先走 comic-image。
	data, derr := yhGKJDetailRaw(workID)
	playIsVideo := false
	if derr == nil {
		for _, ch := range yhArr(data["chapters"]) {
			if cm := yhMap(ch); cm != nil && g5StrVal(cm["id"]) == chapterID {
				if p := g5StrVal(cm["playIs"]); p == "1" || p == "true" {
					playIsVideo = true
				}
				break
			}
		}
	}
	if playIsVideo {
		form := url.Values{}
		form.Set("comic_id", workID)
		form.Set("comic_resource_id", chapterID)
		form.Set("global_type", "anime")
		form.Set("index", "1")
		form.Set("limit", "10000")
		form.Set("page", "1")
		if obj, err := yhGKJForm("/api/comic-image", form); err == nil {
			if u := g5StrVal(obj["play_url"]); u != "" {
				format, protocol := "mp4", ""
				if strings.Contains(u, ".m3u8") {
					format, protocol = "m3u8", "hls"
				}
				return playResult(u, slot, rawID, yhGKJUA, yhGKJBases[0]+"/", format, protocol), nil
			}
		}
	}
	imgs, err := yhGKJCartoonImages(chapterID)
	if err != nil {
		return nil, err
	}
	if len(imgs) == 0 {
		return nil, fmt.Errorf("yh_gkj: no images for chapter %s", chapterID)
	}
	return playResult(imgs[0], slot, rawID, yhGKJUA, yhGKJBases[0]+"/", "jpg", ""), nil
}

func yhGKJSearch(slot, kw string) ([]interface{}, error) {
	form := url.Values{}
	form.Set("comic_title", kw)
	form.Set("limit", "14")
	form.Set("page", "1")
	obj, err := yhGKJForm("/api/comic-lists", form)
	if err != nil {
		return nil, err
	}
	return yhGKJComicCards(slot, yhGKJListItems(obj)), nil
}

func yhGKJCoverFetch(rawurl string) ([]byte, error) {
	b, _, _, err := httpGet(rawurl, yhGKJHeaders())
	if err != nil {
		return nil, err
	}
	if !strings.HasSuffix(rawurl, ".ceb") {
		return b, nil
	}
	plain, err := yhGKJAESDecrypt(yhGKJImgKey, b)
	if err != nil {
		return b, nil
	}
	if len(plain) >= 4 && ((plain[0] == 0xFF && plain[1] == 0xD8) || (plain[0] == 0x89 && plain[1] == 0x50) || (plain[0] == 'R' && plain[1] == 'I')) {
		return plain, nil
	}
	return b, nil
}

func init() {
	registerSite("yh_gkj", &siteImpl{
		Key:        "yh_gkj",
		Name:       "观看局",
		DefaultCat: "comic",
		HomeURL:    yhGKJBases[0] + "/",
		Categories: yhGKJCategories,
		Catalog:    yhGKJCatalog,
		Detail:     yhGKJDetail,
		Resolve:    yhGKJResolve,
		Search:     yhGKJSearch,
		Headers:    yhGKJHeaders,
		CoverFetch: yhGKJCoverFetch,
	}, "yh_gkj", "gkj", "观看局")
}
