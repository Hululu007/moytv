package seku

// ---- 爱美剧 aimeiju (yh_aimeiju) — ThinkPHP 接口 + 动态基址 + token 签名 ----
//
// 配方出欲火 APK jadx 实证（j0/e ApiService + j0/f NetHelper +
// j0/c AMJPlayerInterceptor + AMJLauncherActivity + 各 Activity）：
//   动态基址（实证 i0.a/AMJLauncherActivity 逻辑）：启动时先 GET
//     https://mjapp.52youye.com/index.php/app/android/ver/change
//     -> BaseUrlBean{data.baseUrl}，取 baseUrl 删掉子串
//     "/index.php/app/ios/" 后作为 API 基址；失败则用默认基址并
//     提示「获取配置失败，使用默认配置」。随后 GET
//     {base}/index.php/app/ios/m3u8/index -> PlayKey{data.key}（
//     启动校验，返回值在代码中未被后续消费，故 Go 侧仅尽力预热）。
//   默认基址：http://api.bjxkhc.com（h6.b f8241d，URL_AMJ；远程
//     配置可覆盖）。全部接口为 GET（ud.f=GET，ud.u=QueryMap）：
//     GET {base}/index.php/app/ios/vod/index?size=10&zid=1&id=<tab>
//         -> BannerBean（HomeFragment 横幅，c()）
//     GET {base}/index.php/app/ios/topic/index?size=20&vsize=6&id=1
//         -> ListBean（0 号页签专题，g()）
//     GET {base}/index.php/app/ios/type/index?size=20&vsize=6&id=<tab>
//         -> ListBean（1/2 号页签分类，h()）
//     GET {base}/index.php/app/ios/vod/index?size=18&page=<n>&key=<词>
//         -> VideoList（搜索结果，SearchResultActivity，a()）
//     GET {base}/index.php/app/ios/vod/index?size=18&page=<n>&id=<专题id>
//         &desc=hits&ztid=0
//         -> VideoList（专题详情分页，TopicActivity，b()）
//     GET {base}/index.php/app/ios/vod/index?size=10&desc=rhits&cid=0
//         -> VideoList（搜索页热门提示，SearchActivity，e()）
//     GET {base}/index.php/app/ios/vod/show?id=<id>&token=
//         -> VideoDetail（MovieDetailActivity，d()；token 传空串）
//   详情选集：只取 data.zu[0].ji[]（MovieDetailActivity 实证），
//     ji.name 为集名、ji.purl 为地址；单集时直接播。
//   播放签名（j0/c 拦截器，逐行复刻）：播放地址含 ".m3u" 且不含
//     "wsSecret" 时追加 ?wsSecret=<md5>&wsTime=<秒>，其中
//     wsTime = (nowMs+300000) 截前 10 位（秒），
//     wsSecret = MD5hex("cb877c68fae08369125b645d694ed625"
//       + host + url中第一个 "com" 之后的子串 + wsTime)。
//   App 导航 1:1：底部三页签（id 0/1/2；菜单文本在 jadx 源码中
//     只剩 R.id 引用未留存，此处按端点行为命名：0 走 topic/index
//     专题，1/2 走 type/index 分类）。专题/类型页在 App 内是分组
//     行（组名+横滑卡片），Go 侧扁平化为卡片流，分组名写进卡片
//     category 字段；专题分页详情经 dir:topic:<id> 可达（Detail 内
//     调 b() 第 1 页并以 related 附作品）。
//
// 验证门（2026-10-24 本机实测）：
//   直连 mjapp.52youye.com、api.bjxkhc.com 均 000（本机沙箱对两
//   域返回假 IP 段、连接超时）；独立公共 DNS 双路核查：Google
//   DNS 与 Cloudflare DNS 均回 NXDOMAIN（mjapp.52youye.com、
//   api.bjxkhc.com），HTTP-DNS（119.28.28.28）回 "0"（无记录）。
//   即：基址与配置源在公共解析层面已死亡，非仅本机出口问题——
//   代码按 jadx 逐行实证实现，活体冒烟须待域名恢复或新基址下发
//   后补验。各腿状态：Categories（代码级，三页签 1:1）/
//   Catalog / Detail / Resolve / Search 均为代码实证、活体未验
//   （域名 NXDOMAIN）。封面为明文 pic URL，无加密形态，无需
//   CoverFetch。

import (
	"crypto/md5"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const yhAMJDefaultBase = "http://api.bjxkhc.com"
const yhAMJConfigURL = "https://mjapp.52youye.com/index.php/app/android/ver/change"
const yhAMJSignKey = "cb877c68fae08369125b645d694ed625"
const yhAMJUA = "okhttp/4.9.0"

var (
	yhAMJBaseMu sync.Mutex
	yhAMJBase   string
)

func yhAMJHeaders() map[string]string {
	return map[string]string{
		"User-Agent": yhAMJUA,
		"Accept":     "application/json, text/plain, */*",
	}
}

// yhAMJBaseURL 启动式基址解析：先拉 ver/change，失败则用默认基址
// （与 App「获取配置失败，使用默认配置」行为一致）。
func yhAMJBaseURL() string {
	yhAMJBaseMu.Lock()
	defer yhAMJBaseMu.Unlock()
	if yhAMJBase != "" {
		return yhAMJBase
	}
	yhAMJBase = yhAMJDefaultBase
	if b, code, _, err := httpGet(yhAMJConfigURL, yhAMJHeaders()); err == nil && code < 300 {
		var obj map[string]interface{}
		if err := json.Unmarshal(b, &obj); err == nil {
			if data := yhMap(obj["data"]); data != nil {
				if bu := g5StrVal(data["baseUrl"]); bu != "" {
					yhAMJBase = strings.Replace(bu, "/index.php/app/ios/", "", 1)
				}
			}
		}
	}
	return yhAMJBase
}

func yhAMJGet(path string, q url.Values) (map[string]interface{}, error) {
	rawurl := yhAMJBaseURL() + path
	if len(q) > 0 {
		rawurl += "?" + q.Encode()
	}
	b, code, _, err := httpGet(rawurl, yhAMJHeaders())
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("yh_aimeiju http %d", code)
	}
	var obj map[string]interface{}
	if err := json.Unmarshal(b, &obj); err != nil {
		return nil, fmt.Errorf("yh_aimeiju parse: %v", err)
	}
	return obj, nil
}

// yhAMJSignURL 复刻 j0/c：对 .m3u 地址追加 wsSecret/wsTime。
func yhAMJSignURL(u string) string {
	if !strings.Contains(u, ".m3u") || strings.Contains(u, "wsSecret") {
		return u
	}
	parsed, err := url.Parse(u)
	if err != nil {
		return u
	}
	host := parsed.Hostname()
	i := strings.Index(u, "com")
	sub := ""
	if i >= 0 && i+3 <= len(u) {
		sub = u[i+3:]
	}
	wsTime := strconv.FormatInt(time.Now().UnixMilli()+300000, 10)
	if len(wsTime) > 3 {
		wsTime = wsTime[:len(wsTime)-3]
	}
	sum := md5.Sum([]byte(yhAMJSignKey + host + sub + wsTime))
	return u + "?wsSecret=" + fmt.Sprintf("%x", sum) + "&wsTime=" + wsTime
}

func yhAMJVodCard(slot string, rec map[string]interface{}, group string) (map[string]interface{}, bool) {
	id := g5StrVal(rec["id"])
	name := g5StrVal(rec["name"])
	if id == "" || name == "" {
		return nil, false
	}
	remark := g5StrVal(rec["state"])
	if h := g5StrVal(rec["hits"]); h != "" {
		if remark != "" {
			remark += " "
		}
		remark += h + "播放"
	}
	if pf := g5StrVal(rec["pf"]); pf != "" {
		if remark != "" {
			remark += " "
		}
		remark += pf + "分"
	}
	return makeDrama(slot, id, name, g5StrVal(rec["pic"]), remark, group, g5StrVal(rec["info"])), true
}

func yhAMJGroupCards(slot string, obj map[string]interface{}) []interface{} {
	out := []interface{}{}
	seen := map[string]bool{}
	for _, g := range yhArr(obj["data"]) {
		gm := yhMap(g)
		if gm == nil {
			continue
		}
		group := g5StrVal(gm["name"])
		for _, e := range yhArr(gm["vod"]) {
			rec := yhMap(e)
			if rec == nil {
				continue
			}
			if c, ok := yhAMJVodCard(slot, rec, group); ok {
				id := g5StrVal(rec["id"])
				if !seen[id] {
					seen[id] = true
					out = append(out, c)
				}
			}
		}
	}
	return out
}

func yhAMJCategories(slot string) []interface{} {
	return []interface{}{
		categoryObj("tab:0", "专题"),
		categoryObj("tab:1", "类型1"),
		categoryObj("tab:2", "类型2"),
	}
}

func yhAMJBanner(slot, tab string) []interface{} {
	q := url.Values{}
	q.Set("size", "10")
	q.Set("zid", "1")
	q.Set("id", tab)
	obj, err := yhAMJGet("/index.php/app/ios/vod/index", q)
	if err != nil {
		return []interface{}{}
	}
	out := []interface{}{}
	for _, e := range yhArr(obj["data"]) {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		if c, ok := yhAMJVodCard(slot, rec, "横幅"); ok {
			out = append(out, c)
		}
	}
	return out
}

func yhAMJCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	switch {
	case strings.HasPrefix(category, "dir:topic:"):
		topicID := strings.TrimPrefix(category, "dir:topic:")
		q := url.Values{}
		q.Set("size", "18")
		q.Set("page", strconv.Itoa(page))
		q.Set("id", topicID)
		q.Set("desc", "hits")
		q.Set("ztid", "0")
		obj, err := yhAMJGet("/index.php/app/ios/vod/index", q)
		if err != nil {
			return nil, 0, false, err
		}
		out := []interface{}{}
		for _, e := range yhArr(obj["data"]) {
			rec := yhMap(e)
			if rec == nil {
				continue
			}
			if c, ok := yhAMJVodCard(slot, rec, "专题"); ok {
				out = append(out, c)
			}
		}
		return out, 0, len(out) > 0, nil
	case category == "" || category == "tab:0" || category == "tab:1" || category == "tab:2":
		tab := strings.TrimPrefix(category, "tab:")
		if tab == "" {
			tab = "0"
		}
		if page > 1 {
			return []interface{}{}, 0, false, nil
		}
		out := yhAMJBanner(slot, tab)
		var obj map[string]interface{}
		var err error
		q := url.Values{}
		q.Set("size", "20")
		q.Set("vsize", "6")
		if tab == "0" {
			q.Set("id", "1")
			obj, err = yhAMJGet("/index.php/app/ios/topic/index", q)
		} else {
			q.Set("id", tab)
			obj, err = yhAMJGet("/index.php/app/ios/type/index", q)
		}
		if err != nil {
			return nil, 0, false, err
		}
		out = append(out, yhAMJGroupCards(slot, obj)...)
		return out, 0, false, nil
	}
	return nil, 0, false, fmt.Errorf("yh_aimeiju: unknown category %s", category)
}

func yhAMJDetailRaw(id string) (map[string]interface{}, []interface{}, error) {
	q := url.Values{}
	q.Set("id", id)
	q.Set("token", "")
	obj, err := yhAMJGet("/index.php/app/ios/vod/show", q)
	if err != nil {
		return nil, nil, err
	}
	data := yhMap(obj["data"])
	if data == nil {
		return nil, nil, fmt.Errorf("yh_aimeiju: show empty for %s", id)
	}
	jis := []interface{}{}
	for _, z := range yhArr(data["zu"]) {
		zm := yhMap(z)
		if zm == nil {
			continue
		}
		jis = append(jis, yhArr(zm["ji"])...)
		break
	}
	return data, jis, nil
}

func yhAMJDetail(slot, rawID string) (map[string]interface{}, error) {
	if strings.HasPrefix(rawID, "dir:topic:") {
		topicID := strings.TrimPrefix(rawID, "dir:topic:")
		items, _, _, err := yhAMJCatalog(slot, rawID, 1)
		if err != nil {
			return nil, err
		}
		_ = topicID
		d := makeDrama(slot, rawID, "专题"+topicID, "", "专题", "专题", "")
		if len(items) > 0 {
			epIDs := []string{}
			epNames := []string{}
			for _, it := range items {
				if im, ok := it.(map[string]interface{}); ok {
					epIDs = append(epIDs, g5StrVal(im["vod_id"]))
					epNames = append(epNames, g5StrVal(im["title"]))
				}
			}
			g5SetChapters(d, slot, rawID, epIDs, epNames)
			d["related"] = items
		}
		return d, nil
	}
	data, jis, err := yhAMJDetailRaw(rawID)
	if err != nil {
		return nil, err
	}
	desc := g5StrVal(data["text"])
	if a := g5StrVal(data["daoyan"]); a != "" {
		desc += "\n导演：" + a
	}
	if a := g5StrVal(data["zhuyan"]); a != "" {
		desc += "\n主演：" + a
	}
	if a := g5StrVal(data["diqu"]); a != "" {
		desc += "\n地区：" + a
	}
	d := makeDrama(slot, rawID, g5StrVal(data["name"]), g5StrVal(data["pic"]), g5StrVal(data["state"]), g5StrVal(data["type"]), desc)
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
		if len(jis) == 1 {
			epIDs = append(epIDs, rawID)
		} else {
			epIDs = append(epIDs, rawID+"#"+strconv.Itoa(i))
		}
		epNames = append(epNames, name)
	}
	if len(epIDs) > 0 {
		g5SetChapters(d, slot, rawID, epIDs, epNames)
	}
	return d, nil
}

func yhAMJResolve(slot, rawID string) (map[string]interface{}, error) {
	ep := rawID
	if i := strings.Index(ep, "$"); i >= 0 {
		ep = ep[i+1:]
	}
	base, idxStr, _ := strings.Cut(ep, "#")
	_, jis, err := yhAMJDetailRaw(base)
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
		return nil, fmt.Errorf("yh_aimeiju: episode %d out of range", idx)
	}
	u := g5StrVal(yhMap(jis[idx])["purl"])
	if u == "" {
		return nil, fmt.Errorf("yh_aimeiju: purl empty for %s", ep)
	}
	u = yhAMJSignURL(u)
	format, protocol := "mp4", ""
	if strings.Contains(u, ".m3u8") {
		format, protocol = "m3u8", "hls"
	}
	return playResult(u, slot, rawID, yhAMJUA, yhAMJBaseURL()+"/", format, protocol), nil
}

func yhAMJSearch(slot, kw string) ([]interface{}, error) {
	q := url.Values{}
	q.Set("size", "18")
	q.Set("page", "1")
	q.Set("key", kw)
	obj, err := yhAMJGet("/index.php/app/ios/vod/index", q)
	if err != nil {
		return nil, err
	}
	out := []interface{}{}
	for _, e := range yhArr(obj["data"]) {
		rec := yhMap(e)
		if rec == nil {
			continue
		}
		if c, ok := yhAMJVodCard(slot, rec, "搜索"); ok {
			out = append(out, c)
		}
	}
	return out, nil
}

func init() {
	registerSite("yh_aimeiju", &siteImpl{
		Key:        "yh_aimeiju",
		Name:       "爱美剧",
		DefaultCat: "tab:0",
		HomeURL:    yhAMJDefaultBase + "/",
		Categories: yhAMJCategories,
		Catalog:    yhAMJCatalog,
		Detail:     yhAMJDetail,
		Resolve:    yhAMJResolve,
		Search:     yhAMJSearch,
		Headers:    yhAMJHeaders,
	}, "yh_aimeiju", "aimeiju", "爱美剧")
}
