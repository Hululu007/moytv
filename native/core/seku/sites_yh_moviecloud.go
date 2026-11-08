package seku

// ---- 影视云 movieCloud (yh_moviecloud) — 纯搜索聚合，无自有目录 ----
//
// 形态（文件头先说清）：本模块在 App 内只有一个搜索界面
// （VideoSearchActivity），没有任何分类页/榜单页/首页频道；唯一的
// 可浏览面是 XX 源的热门行（/search?page=1）。因此 Categories 只给
// 其源站维度：xx:hot（小小热门，唯一可浏览面）；爱美剧（AMJ）腿在
// 本模块内只有搜索（vod/index?key=），无独立可浏览分类，故不为其
// 造假分类——AMJ 内容只经 Search 腿合并返回。
//
// 配方出欲火 APK jadx 实证（q4/a ApiService + q4/b NetHelper +
// q4/c XXInterceptor + VideoSearchActivity/PlayActivity）：
//   基址 XX：https://android.xiaoxiaoapps.com（h6.b f8239c，URL_XX）
//   拦截器：每请求附 X-Forwarded-For: <随机 0-254 四段 IP>。
//   GET /search?page=1                    -> XXList（热门行，d()）
//   GET /search?page=<n>&wd=<词>          -> XXList（XX 搜索，a()）
//   GET /vod/show/{id}                    -> XXPlay（XX 详情，e()）
//   GET /vod/reqplay/{id}?playindex=<idx> -> PlayIndex{data.httpurl}（b()）
//   GET https://mjapp.mjomj.com/index.php/app/ios/vod/index
//       ?size=20&page=<n>&key=<词>        -> AMJList（AMJ 搜索，c()，
//       绝对地址，仍走同一 Retrofit 客户端，故同样附 X-Forwarded-For）
//   GET https://mjapp.mjomj.com/index.php/app/ios/vod/show
//       ?token=&id=<id>                   -> AMJPlay（AMJ 详情，f()；
//       PlayActivity 实证 token 传空串）
// 选集：XXPlay vodrow.playlist[] 的 PlayListBean 转换实证为
//   name=play_name, uri=playindex（XXPlay.java:232）；AMJPlay 的
//   PlayListBean 转换实证为 name=ji.name, uri=ji.purl（AMJPlay.java:301）。
//   故 XX 选集 id 形如 "xx:<vodid>#<playindex>"，Resolve 经 reqplay
//   换 httpurl；AMJ 选集 id 形如 "amj:<id>#<ji序号>"，Resolve 直接取
//   对应 ji.purl（movieCloud 的 AMJ 播放不走 aimeiju 模块的
//   wsSecret 拦截器，PlayActivity.a 直接 setPlayUri(purl)，不签名）。
// 付费：XX playlist 项含 view_price、vodrow 含 isvip/limit_free；
//   Go 侧 Resolve 遇 view_price>0 的选集直接拒解析（不播付费集），
//   目录卡片保留（与 App 列表行为一致），备注标明价格。
//
// 验证门（2026-10-24 本机实测）：
//   直连 https://android.xiaoxiaoapps.com 与 https://mjapp.mjomj.com
//   均 000（本机沙箱对两域返回假 IP 198.18.79.176 段、连接超时；
//   同批百度亦 000，属沙箱出口类问题）；独立公共 DNS 双路核查：
//   Google DNS 与 Cloudflare DNS 均回 NXDOMAIN（android.
//   xiaoxiaoapps.com、mjapp.mjomj.com），HTTP-DNS（119.28.28.28）
//   回 "0"（无记录）。即：域名在公共解析层面已死亡，非仅本机
//   出口问题——代码按 jadx 逐行实证实现，活体冒烟须待域名恢复或
//   新基址下发后补验；本文件不把“域名已死”写成“代码未验”以外的
//   任何已验结论。各腿状态：Categories（代码级，源站维度如实）/
//   Catalog/Search/Detail/Resolve 均为代码实证、活体未验（域名
//   NXDOMAIN）。封面：XX coverpic/coverpic2、AMJ pic 为明文 URL，
//   无加密形态，无需 CoverFetch。

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/url"
	"strconv"
	"strings"
)

const yhMCXXBase = "https://android.xiaoxiaoapps.com"
const yhMCAMJBase = "https://mjapp.mjomj.com"
const yhMCUA = "okhttp/4.9.0"

func yhMCHeaders() map[string]string {
	return map[string]string{
		"User-Agent":      yhMCUA,
		"X-Forwarded-For": fmt.Sprintf("%d.%d.%d.%d", rand.Intn(255), rand.Intn(255), rand.Intn(255), rand.Intn(255)),
	}
}

func yhMCGet(rawurl string) (map[string]interface{}, error) {
	b, code, _, err := httpGet(rawurl, yhMCHeaders())
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_moviecloud http %d", code)
	}
	var obj map[string]interface{}
	if err := json.Unmarshal(b, &obj); err != nil {
		return nil, fmt.Errorf("yh_moviecloud parse: %v", err)
	}
	return obj, nil
}

func yhMCXXList(slot string, obj map[string]interface{}) []interface{} {
	data := yhMap(obj["data"])
	if data == nil {
		return []interface{}{}
	}
	out := []interface{}{}
	seen := map[string]bool{}
	for _, e := range yhArr(data["vodrows"]) {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		vid := g5StrVal(rec["vodid"])
		title := g5StrVal(rec["title"])
		if vid == "" || title == "" || seen[vid] {
			continue
		}
		seen[vid] = true
		cover := g5StrVal(rec["coverpic"])
		if cover == "" {
			cover = g5StrVal(rec["coverpic2"])
		}
		remark := g5StrVal(rec["catename"])
		if pc := g5StrVal(rec["playcount_total"]); pc != "" {
			if remark != "" {
				remark += " "
			}
			remark += pc + "播放"
		}
		out = append(out, makeDrama(slot, "xx:"+vid, title, cover, remark, g5StrVal(rec["catename"]), g5StrVal(rec["intro"])))
	}
	return out
}

func yhMCAMJList(slot string, obj map[string]interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, e := range yhArr(obj["data"]) {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		id := g5StrVal(rec["id"])
		name := g5StrVal(rec["name"])
		if id == "" || name == "" || seen[id] {
			continue
		}
		seen[id] = true
		remark := g5StrVal(rec["state"])
		if h := g5StrVal(rec["hits"]); h != "" {
			if remark != "" {
				remark += " "
			}
			remark += h + "播放"
		}
		out = append(out, makeDrama(slot, "amj:"+id, name, g5StrVal(rec["pic"]), remark, g5StrVal(rec["type"]), g5StrVal(rec["info"])))
	}
	return out
}

func yhMCCategories(slot string) []interface{} {
	return []interface{}{
		categoryObj("xx:hot", "小小热门"),
	}
}

func yhMCCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	if category != "" && category != "xx:hot" {
		return nil, 0, false, fmt.Errorf("yh_moviecloud: unknown category %s (AMJ leg is search-only)", category)
	}
	var obj map[string]interface{}
	var err error
	if page == 1 {
		obj, err = yhMCGet(yhMCXXBase + "/search?page=1")
	} else {
		obj, err = yhMCGet(yhMCXXBase + fmt.Sprintf("/search?page=%d&wd=", page))
	}
	if err != nil {
		return nil, 0, false, err
	}
	items := yhMCXXList(slot, obj)
	return items, 0, len(items) > 0, nil
}

// yhMCXXShow 取 XX 详情 vodrow；返回 (vodrow, playlist[])。
func yhMCXXShow(vid string) (map[string]interface{}, []interface{}, error) {
	obj, err := yhMCGet(yhMCXXBase + "/vod/show/" + url.PathEscape(vid))
	if err != nil {
		return nil, nil, err
	}
	data := yhMap(obj["data"])
	if data == nil {
		return nil, nil, fmt.Errorf("yh_moviecloud: xx show empty for %s", vid)
	}
	row := yhMap(data["vodrow"])
	if row == nil {
		return nil, nil, fmt.Errorf("yh_moviecloud: xx vodrow empty for %s", vid)
	}
	return row, yhArr(row["playlist"]), nil
}

// yhMCAMJShow 取 AMJ 详情；返回 (data, 全部 ji 扁平列表)。
func yhMCAMJShow(id string) (map[string]interface{}, []interface{}, error) {
	obj, err := yhMCGet(yhMCAMJBase + "/index.php/app/ios/vod/show?token=&id=" + url.QueryEscape(id))
	if err != nil {
		return nil, nil, err
	}
	data := yhMap(obj["data"])
	if data == nil {
		return nil, nil, fmt.Errorf("yh_moviecloud: amj show empty for %s", id)
	}
	jis := []interface{}{}
	for _, z := range yhArr(data["zu"]) {
		zm := yhMap(z)
		if zm == nil {
			continue
		}
		jis = append(jis, yhArr(zm["ji"])...)
	}
	return data, jis, nil
}

func yhMCDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "xx:") {
		vid := strings.TrimPrefix(rawID, "xx:")
		row, playlist, err := yhMCXXShow(vid)
		if err != nil {
			return nil, err
		}
		cover := g5StrVal(row["coverpic"])
		if cover == "" {
			cover = g5StrVal(row["coverpic2"])
		}
		d := makeDrama(slot, rawID, g5StrVal(row["title"]), cover, g5StrVal(row["catename"]), g5StrVal(row["catename"]), g5StrVal(row["intro"]))
		epIDs := []string{}
		epNames := []string{}
		for _, p := range playlist {
			pm := yhMap(p)
			if pm == nil {
				continue
			}
			idx := g5StrVal(pm["playindex"])
			if idx == "" {
				continue
			}
			name := g5StrVal(pm["play_name"])
			if name == "" {
				name = "第" + idx + "集"
			}
			if vp := g5StrVal(pm["view_price"]); vp != "" && vp != "0" {
				name += "（付费" + vp + "）"
			}
			epIDs = append(epIDs, "xx:"+vid+"#"+idx)
			epNames = append(epNames, name)
		}
		if len(epIDs) > 0 {
			g5SetChapters(d, slot, rawID, epIDs, epNames)
		}
		return d, nil
	}
	if strings.HasPrefix(rawID, "amj:") {
		id := strings.TrimPrefix(rawID, "amj:")
		data, jis, err := yhMCAMJShow(id)
		if err != nil {
			return nil, err
		}
		d := makeDrama(slot, rawID, g5StrVal(data["name"]), g5StrVal(data["pic"]), g5StrVal(data["state"]), g5StrVal(data["type"]), g5StrVal(data["text"]))
		epIDs := []string{}
		epNames := []string{}
		for i, j := range jis {
			jm := yhMap(j)
			if jm == nil {
				continue
			}
			name := g5StrVal(jm["name"])
			if name == "" {
				name = fmt.Sprintf("第%d集", i+1)
			}
			epIDs = append(epIDs, "amj:"+id+"#"+strconv.Itoa(i))
			epNames = append(epNames, name)
		}
		if len(epIDs) > 0 {
			g5SetChapters(d, slot, rawID, epIDs, epNames)
		}
		return d, nil
	}
	return nil, fmt.Errorf("yh_moviecloud: unknown id %s", rawID)
}

func yhMCResolve(slot, rawID string) (map[string]interface{}, error) {
	ep := rawID
	if i := strings.Index(ep, "$"); i >= 0 {
		ep = ep[i+1:]
	}
	if strings.HasPrefix(ep, "xx:") {
		rest := strings.TrimPrefix(ep, "xx:")
		vid, idx, _ := strings.Cut(rest, "#")
		row, playlist, err := yhMCXXShow(vid)
		if err != nil {
			return nil, err
		}
		_ = row
		var playIdx string
		for _, p := range playlist {
			pm := yhMap(p)
			if pm == nil {
				continue
			}
			if idx == "" || g5StrVal(pm["playindex"]) == idx {
				playIdx = g5StrVal(pm["playindex"])
				if vp := g5StrVal(pm["view_price"]); vp != "" && vp != "0" {
					return nil, fmt.Errorf("yh_moviecloud: paid episode refused (view_price=%s)", vp)
				}
				break
			}
		}
		if playIdx == "" {
			return nil, fmt.Errorf("yh_moviecloud: no playindex for %s", ep)
		}
		obj, err := yhMCGet(yhMCXXBase + "/vod/reqplay/" + url.PathEscape(vid) + "?playindex=" + url.QueryEscape(playIdx))
		if err != nil {
			return nil, err
		}
		u := g5StrVal(yhMap(obj["data"])["httpurl"])
		if u == "" {
			return nil, fmt.Errorf("yh_moviecloud: reqplay empty for %s", ep)
		}
		format, protocol := "mp4", ""
		if strings.Contains(u, ".m3u8") {
			format, protocol = "m3u8", "hls"
		}
		return playResult(u, slot, rawID, yhMCUA, yhMCXXBase+"/", format, protocol), nil
	}
	if strings.HasPrefix(ep, "amj:") {
		rest := strings.TrimPrefix(ep, "amj:")
		id, idxStr, _ := strings.Cut(rest, "#")
		_, jis, err := yhMCAMJShow(id)
		if err != nil {
			return nil, err
		}
		idx := 0
		if idxStr != "" {
			if n, err := strconv.Atoi(idxStr); err == nil {
				idx = n
			}
		}
		if idx < 0 || idx >= len(jis) {
			return nil, fmt.Errorf("yh_moviecloud: amj episode %d out of range", idx)
		}
		u := g5StrVal(yhMap(jis[idx])["purl"])
		if u == "" {
			return nil, fmt.Errorf("yh_moviecloud: amj purl empty for %s", ep)
		}
		format, protocol := "mp4", ""
		if strings.Contains(u, ".m3u8") {
			format, protocol = "m3u8", "hls"
		}
		return playResult(u, slot, rawID, yhMCUA, yhMCAMJBase+"/", format, protocol), nil
	}
	return nil, fmt.Errorf("yh_moviecloud: unknown id %s", rawID)
}

func yhMCSearch(slot, kw string) ([]interface{}, error) {
	out := []interface{}{}
	if obj, err := yhMCGet(yhMCXXBase + "/search?page=1&wd=" + url.QueryEscape(kw)); err == nil {
		out = append(out, yhMCXXList(slot, obj)...)
	} else {
		return out, err
	}
	if obj, err := yhMCGet(yhMCAMJBase + "/index.php/app/ios/vod/index?size=20&page=1&key=" + url.QueryEscape(kw)); err == nil {
		out = append(out, yhMCAMJList(slot, obj)...)
	}
	return out, nil
}

func init() {
	registerSite("yh_moviecloud", &siteImpl{
		Key:        "yh_moviecloud",
		Name:       "影视云",
		DefaultCat: "xx:hot",
		HomeURL:    yhMCXXBase + "/",
		Categories: yhMCCategories,
		Catalog:    yhMCCatalog,
		Detail:     yhMCDetail,
		Resolve:    yhMCResolve,
		Search:     yhMCSearch,
		Headers:    yhMCHeaders,
	}, "yh_moviecloud", "movieCloud", "影视云")
}
