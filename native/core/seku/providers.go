package seku

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var httpClient = &http.Client{Timeout: 20 * time.Second}

var noRedirectClient = &http.Client{
	Timeout: 20 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

func httpGet(url string, headers map[string]string) ([]byte, int, http.Header, error) {
	return httpDo("GET", url, nil, headers)
}

// httpGetTimeout is httpGet with a per-request timeout, for fetchers
// whose retry loops would otherwise stack the shared client's 20s
// timeout once per candidate host (v5 device fix: a blackholed first
// host must not eat minutes before the next host is tried).
func httpGetTimeout(url string, headers map[string]string, timeout time.Duration) ([]byte, int, http.Header, error) {
	headers = zkShieldTicketHeaders(zkShieldHostOf(url), crackMergedHeaders(url, headers))
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, 0, nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	cl := &http.Client{Timeout: timeout}
	resp, err := cl.Do(req)
	if err != nil {
		if b, code, hdr, jerr, ok := jinaFallback(url, headers, nil, 0, err); ok {
			return b, code, hdr, jerr
		}
		return nil, 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		if jb, jcode, jhdr, jerr, ok := jinaFallback(url, headers, b, resp.StatusCode, err); ok {
			return jb, jcode, jhdr, jerr
		}
		return nil, resp.StatusCode, resp.Header, err
	}
	if jb, jcode, jhdr, jerr, ok := jinaFallback(url, headers, b, resp.StatusCode, nil); ok {
		return jb, jcode, jhdr, jerr
	}
	return b, resp.StatusCode, resp.Header, nil
}

// httpDo 是所有 Go 核站点的统一请求出口。
//
// 它做三件通用的事（不针对任何具体站点，新加的站点自动继承）：
//  1. 直连时带上票池里的通行证（cf_clearance + 签发时的 UA）；
//  2. 撞上挑战页就上报给 App 的解盾队列，并把该 host 标记为「有盾」；
//  3. 直连拿不到正文时，交给盾层多通道（relay / 网关 / 渲染）兜底取回。
//
// 以前这些能力只存在于各站自己的取页函数里，所以每到新站就要重写一遍，
// 漏写的站被盾一挡就是白页。收到这里之后，站点实现只管解析。
func httpDo(method, url string, body io.Reader, headers map[string]string) ([]byte, int, http.Header, error) {
	first, code, hdr, err := httpDoDirect(method, url, body, headers)
	if method != http.MethodGet {
		return first, code, hdr, err
	}

	host := zkShieldHostOf(url)
	text := string(first)
	lower := strings.ToLower(text)
	// 只有明确的人机校验特征才算撞盾。不能用「正文短/为空」或裸 403 当依据：
	// 不少站点的小接口本来就返回几十字节，而 403 更常见的是防盗链/风控，
	// 那些由站点自己的镜像/重试逻辑处理；误判会把正常响应替换掉，
	// 直接表现就是列表变空（实测 av123 就是这样被误伤的）。
	marker := httpShieldMarker(text) ||
		(code == 403 && len(text) < 20000 && strings.Contains(lower, "cloudflare"))
	if !marker {
		return first, code, hdr, err
	}

	zkShieldMarkShielded(host)
	zkShieldReportChallenge(url)

	// 有票时立刻重试一次：票就是刚才自动解盾回填的，带上就能拿到原文。
	// 没票就原样返回，绝不在这里等、也不拿中转内容顶替——
	// 站点自己的镜像/重试逻辑要拿到真实响应才正常，
	// 被替换成「看起来能解析」的中转内容反而会把列表搞空（av123 实测踩过）。
	if _, ok := zkShieldTicketHeaders(host, headers)["Cookie"]; ok {
		if b, c, h, e := httpDoDirect(method, url, nil, headers); e == nil &&
			!httpShieldMarker(string(b)) {
			return b, c, h, e
		}
	}

	// 盾层多通道只作为最后一道兜底，而且只在直连完全没内容时才用；
	// 有了上面那条，正常站点完全不受影响。
	if len(strings.TrimSpace(text)) == 0 {
		if alt := zkShieldFetch(url, headers, "", 20000, false); alt != "" {
			return []byte(alt), http.StatusOK, hdr, nil
		}
	}
	return first, code, hdr, err
}

// httpShieldMarker 只认真正的人机校验页面特征。
//
// 两个容易踩的坑都在这里挡掉：
//   - 不能看响应长短就判定（小接口本来就几十字节）；
//   - 不能只要页面里出现 challenge-platform 就当挑战页——接了 Cloudflare
//     的正常站点首页照样会引用那段脚本。人机校验页必然是「很小 + 带特征」，
//     所以先卡长度，正常内容页直接放行。
func httpShieldMarker(body string) bool {
	if body == "" || len(body) > 8000 {
		return false
	}
	head := body
	if len(head) > 6000 {
		head = head[:6000]
	}
	lower := strings.ToLower(head)
	for _, m := range []string{
		"just a moment",
		"cf_chl_opt",
		"cf-browser-verification",
		"challenge-platform",
		"enable javascript and cookies to continue",
		"attention required",
		"cf-error-details",
	} {
		if strings.Contains(lower, m) {
			return true
		}
	}
	return false
}

// httpDoDirect 是不带盾层兜底的直连实现：只做票池补头、加密配置合并，
// 和改造前的行为一致（jina 中转失败自动降级直连仍在其中）。
func httpDoDirect(method, url string, body io.Reader, headers map[string]string) ([]byte, int, http.Header, error) {
	headers = zkShieldTicketHeaders(zkShieldHostOf(url), crackMergedHeaders(url, headers))
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, 0, nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		if method == "GET" {
			if b, code, hdr, jerr, ok := jinaFallback(url, headers, nil, 0, err); ok {
				return b, code, hdr, jerr
			}
		}
		return nil, 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		// A shielded response whose body stream dies mid-read (seen
		// live with javrate: 403 + unexpected EOF) is still a failed
		// direct fetch — give the smart-route fallback its chance.
		if method == "GET" {
			if jb, jcode, jhdr, jerr, ok := jinaFallback(url, headers, b, resp.StatusCode, err); ok {
				return jb, jcode, jhdr, jerr
			}
		}
		return nil, resp.StatusCode, resp.Header, err
	}
	if method == "GET" {
		if jb, jcode, jhdr, jerr, ok := jinaFallback(url, headers, b, resp.StatusCode, nil); ok {
			return jb, jcode, jhdr, jerr
		}
	}
	return b, resp.StatusCode, resp.Header, nil
}

// ---- smart routing: shared "免代" fetch fallback (v5) ----
//
// What the ZakaTV jar's "免代/免翻" labels actually are (evidence in
// batch/v5work/note: ZakaSec table + class strings): per-site
// official mirror-domain pools with /status.html probing — data,
// not a shared transport — PLUS one genuinely shared channel:
// ZakaShield fetches blocked pages through the public reader proxy
// https://r.jina.ai/. The jar's only private relay (MissAV's
// missav.ws286.ystv.top) is dead (410). So the core-layer equivalent
// is: direct first; when a GET demonstrably fails (transport error,
// or a 401/403/503 carrying a Cloudflare challenge signature), retry
// once through r.jina.ai with x-respond-with: html (raw HTML back).
// Binary/media URLs never take the fallback on transport errors
// (playlists, segments, keys, images are not reader material).
// Per-host negative cache (60s) stops dead hosts from doubling
// latency on every request; there is no positive stickiness —
// direct stays the default route and recovers automatically.
var jinaNegMu sync.Mutex
var jinaNegCache = map[string]time.Time{}

var jinaBinaryExts = []string{".ts", ".m3u8", ".mp4", ".m4s", ".key", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".zip", ".so", ".bin", ".ico"}

func jinaHostOf(rawurl string) string {
	u, err := url.Parse(rawurl)
	if err != nil {
		return ""
	}
	return u.Host
}

func jinaFallback(rawurl string, headers map[string]string, body []byte, code int, terr error) ([]byte, int, http.Header, error, bool) {
	if strings.Contains(rawurl, "r.jina.ai") {
		return nil, 0, nil, nil, false
	}
	host := jinaHostOf(rawurl)
	if host == "" {
		return nil, 0, nil, nil, false
	}
	trigger := false
	if terr != nil {
		trigger = true
		lower := strings.ToLower(rawurl)
		if q := strings.Index(lower, "?"); q >= 0 {
			lower = lower[:q]
		}
		for _, ext := range jinaBinaryExts {
			if strings.HasSuffix(lower, ext) {
				return nil, 0, nil, nil, false
			}
		}
	} else if (code == 401 || code == 403 || code == 503) && len(body) > 0 && isChallengePage(string(body)) {
		trigger = true
	}
	if !trigger {
		return nil, 0, nil, nil, false
	}
	jinaNegMu.Lock()
	if t, ok := jinaNegCache[host]; ok && time.Since(t) < 60*time.Second {
		jinaNegMu.Unlock()
		return nil, 0, nil, nil, false
	}
	jinaNegMu.Unlock()
	h := map[string]string{"x-respond-with": "html"}
	if headers != nil {
		if ua := headers["User-Agent"]; ua != "" {
			h["User-Agent"] = ua
		}
	}
	req, err := http.NewRequest("GET", "https://r.jina.ai/"+rawurl, nil)
	if err != nil {
		return nil, 0, nil, nil, false
	}
	for k, v := range h {
		req.Header.Set(k, v)
	}
	cl := &http.Client{Timeout: 30 * time.Second}
	resp, err := cl.Do(req)
	if err != nil {
		jinaNegMu.Lock()
		jinaNegCache[host] = time.Now()
		jinaNegMu.Unlock()
		return nil, 0, nil, nil, false
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil || resp.StatusCode != 200 || len(b) == 0 || isChallengePage(string(b)) {
		jinaNegMu.Lock()
		jinaNegCache[host] = time.Now()
		jinaNegMu.Unlock()
		return nil, 0, nil, nil, false
	}
	return b, 200, resp.Header, nil, true
}

func cleanText(s string) string {
	s = strings.ReplaceAll(s, "&amp;", "&")
	s = strings.ReplaceAll(s, "&quot;", "\"")
	s = strings.ReplaceAll(s, "&#39;", "'")
	s = strings.ReplaceAll(s, "&lt;", "<")
	s = strings.ReplaceAll(s, "&gt;", ">")
	s = strings.ReplaceAll(s, "&nbsp;", " ")
	return strings.TrimSpace(s)
}

// ---- slots ----
//
// v4 slot model: the Dart UI has a static directory of 23 SourceSites
// (models.dart, objs.txt: hongguo, ikanbot, a123, hanxiaoquan, guipian,
// huangdou, huangju, yeguo, dsd, huangguo-video, huangguoai, cloudfront,
// yaguo, maoguo, fanguo, guanguo, heguo, xingguo, huaguo, niuguo, wangguo,
// faguo, wuguo). Content can only be attached to ids in that directory —
// dramas whose "source" is an unknown id are dropped by the UI's
// per-source views (LocalStore.allowsSource -> SourceSite.isAvailable).
// The batch build therefore registers every ported site into one of the
// 23 slots (see registry.go slotSites — the one mapping table).

const (
	slotHsck   = "a123"    // 黄色仓库 hsck123.com (ZakaHsckAmns)
	slotDayday = "guipian" // 天天A片 vjav.tube (ZakaDaydayAmns)
)

// dartSlotNames is what the Dart directory displays for each slot id.
// Payloads keep it only as a harmless extra key; the UI never reads the
// name from the core.
var dartSlotNames = map[string]string{
	"hongguo": "红果", "ikanbot": "爱看机器人", "a123": "A123",
	"hanxiaoquan": "韩小圈", "guipian": "鬼片", "huangdou": "whos识图",
	"huangju": "剧果", "yeguo": "野果", "dsd": "帝果",
	"huangguo-video": "黄果视频", "huangguoai": "黄果 AI",
	"cloudfront": "黄果旧版", "yaguo": "芽果", "maoguo": "猫果",
	"fanguo": "饭果", "guanguo": "观果", "heguo": "河果",
	"xingguo": "星果", "huaguo": "花果", "niuguo": "牛果",
	"wangguo": "网果", "faguo": "发果", "wuguo": "伍果",
}

// slotForSource maps any incoming source spelling to a registered slot.
// Returns "" for sources this core does not implement.
func slotForSource(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	if s == "" {
		return ""
	}
	if _, ok := slotSites[s]; ok {
		return s
	}
	if slot, ok := keyToSlot[s]; ok {
		return slot
	}
	return ""
}

func providerForSlot(slot string) string {
	if impl := implForSlot(slot); impl != nil {
		return impl.Key
	}
	return ""
}

func slotDisplayName(slot string) string {
	if n, ok := dartSlotNames[slot]; ok {
		return n
	}
	return slot
}

func defaultCategory(slot string) string {
	if impl := implForSlot(slot); impl != nil {
		return impl.DefaultCat
	}
	return ""
}

func makeDrama(slot, rawID, title, cover, remark, categoryName, desc string) map[string]interface{} {
	cid := dramaID(slot, rawID)
	// Chapter object aligned with the original core's core.Chapter model.
	ep := map[string]interface{}{
		"episodeId": rawID,
		"id":        cid,
		"dramaId":   cid,
		"sourceId":  slot,
		"source":    slot,
		"title":     "正片",
		"name":      "正片",
		"index":     1,
		"episode":   1,
		"url":       "",
		"videoUrl":  "",
		"mediaSize": 0,
	}
	// Drama object aligned with the Dart Drama.fromJson field table
	// (models.dart @0x431688): id, source (default "hongguo"), sourceId,
	// title, description, cover, episodes (int count!), category, vip,
	// metadataSchema, heat, views, onlineDate, tags, releaseStatus, peers.
	// The canonical cover key is "cover" (not coverUrl); both are given.
	d := map[string]interface{}{
		"metadataSchema": 1,
		"dramaId":        cid,
		"id":             cid,
		"vod_id":         rawID,
		"title":          title,
		"name":           title,
		"coverUrl":       cover,
		"cover":          cover,
		"vod_pic":        cover,
		"pic":            cover,
		"thumb":          cover,
		"sourceId":       slot,
		"source":         slot,
		"sourceName":     slotDisplayName(slot),
		"category":       categoryName,
		"categoryName":   categoryName,
		"typeName":       categoryName,
		"remark":         remark,
		"remarks":        remark,
		"vod_remarks":    remark,
		"desc":           desc,
		"description":    desc,
		"intro":          desc,
		"episodeCount":   1,
		"chapterCount":   1,
		"totalEpisode":   1,
		"totalEpisodes":  1,
		"episodes":       1,
		"chapters":       []interface{}{ep},
		"episodeList":    []interface{}{ep},
		"vip":            false,
		"tags":           []interface{}{},
	}
	return d
}

func categoryObj(id, name string) map[string]interface{} {
	return map[string]interface{}{
		"category":     id,
		"categoryId":   id,
		"id":           id,
		"typeId":       id,
		"type_id":      id,
		"name":         name,
		"categoryName": name,
		"typeName":     name,
		"title":        name,
	}
}

// markerCatID is the v4 slot-identity marker category. The Dart UI's
// 23 slot display names are compiled into libapp.so and cannot be
// renamed safely (variable-length snapshot string rewrite, unverifiable
// without a Flutter runtime — see batch notes v4). Instead every slot's
// category list starts with a marker entry named "全部·<真实站名>"
// that behaves exactly like the slot's default category, so the user
// can see which real site a slot carries right in the tab bar.
const markerCatID = "__all"

func providerCategories(slot string) []interface{} {
	impl := implForSlot(slot)
	if impl == nil || impl.Categories == nil {
		return []interface{}{}
	}
	out := impl.Categories(slot)
	if out == nil {
		return []interface{}{}
	}
	marker := categoryObj(markerCatID, "全部·"+strings.TrimPrefix(impl.Name, "🔞"))
	return append([]interface{}{marker}, out...)
}

// providerCategoryIDs returns just the ids, in display order.
func providerCategoryIDs(slot string) []string {
	ids := []string{}
	for _, c := range providerCategories(slot) {
		if m, ok := c.(map[string]interface{}); ok {
			if id, _ := m["id"].(string); id != "" {
				ids = append(ids, id)
			}
		}
	}
	return ids
}

func providerCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	impl := implForSlot(slot)
	if impl == nil || impl.Catalog == nil {
		return []interface{}{}, 0, false, fmt.Errorf("unknown provider")
	}
	if category == markerCatID {
		category = impl.DefaultCat
	}
	return impl.Catalog(slot, category, page)
}

func providerCatalogFiltered(slot, category string, page int, filters map[string]string) ([]interface{}, int, bool, error) {
	impl := implForSlot(slot)
	if impl == nil {
		return []interface{}{}, 0, false, fmt.Errorf("unknown provider")
	}
	if category == markerCatID {
		category = impl.DefaultCat
	}
	if impl.CatalogFiltered != nil {
		return impl.CatalogFiltered(slot, category, page, filters)
	}
	if impl.Catalog == nil {
		return []interface{}{}, 0, false, fmt.Errorf("unknown provider")
	}
	return impl.Catalog(slot, category, page)
}

func providerDetail(slot, rawID string) (map[string]interface{}, error) {
	impl := implForSlot(slot)
	if impl == nil || impl.Detail == nil {
		return nil, fmt.Errorf("unknown provider")
	}
	return impl.Detail(slot, rawID)
}

func providerResolve(slot, rawID string) (map[string]interface{}, error) {
	impl := implForSlot(slot)
	if impl == nil || impl.Resolve == nil {
		return nil, fmt.Errorf("unknown provider")
	}
	return impl.Resolve(slot, rawID)
}

func providerSearch(slot, kw string) ([]interface{}, error) {
	impl := implForSlot(slot)
	if impl == nil || impl.Search == nil {
		return []interface{}{}, fmt.Errorf("unknown provider")
	}
	return impl.Search(slot, kw)
}

// providerHomeURL / providerHeaders are used by the health check.
func providerHomeURL(slot string) string {
	if impl := implForSlot(slot); impl != nil {
		return impl.HomeURL
	}
	return ""
}

func providerHeaders(slot string) map[string]string {
	if impl := implForSlot(slot); impl != nil && impl.Headers != nil {
		return impl.Headers()
	}
	return map[string]string{}
}
