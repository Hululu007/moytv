package core

// 头条精选（py 分类 t:jx）：a_bogus 签名 + 头条 PC 推荐流。
//
// 对照 py（hongguo_full_177_5sc7.py）：_ABogus 行 704-828，ToutiaoFeed 行 829-1003。
//
// 字节等价性说明：py 版全程按 str/ord/chr 运算，个别中间值超过 255（如 _list4 里
// 的 et>>32）。但 _result 的 4 个 sextet 只取决于每个字符的低 8 位，且 RC4 输出的
// 低 8 位只取决于输入的低 8 位，因此 []byte 移植与 py 版输出逐字节等价。
// 唯一行为差异：py _sample 用 8 线程并行拉 24 页；Go 版顺序拉（出口规则禁并行 burst），
// 并设 50 秒软预算（超时则用已拉到的条目），见 hongguoNewToutiaoSample。

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const toutiaoFeedUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
const toutiaoFeedAPI = "https://www.toutiao.com/api/pc/list/feed"
const toutiaoFeedChannelID = "94349560412"
const toutiaoFeedTimeout = 15 * time.Second
const toutiaoFeedCacheTTL = 600 * time.Second
const toutiaoFeedSampleBudget = 50 * time.Second

// a_bogus 自定义 base64 表（py _ABogus.__str）。实际只用 s3（UA 码）与 s4（最终签名），
// 其余三张原样保留，与 py 定义一致。
const (
	abogusTableS0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
	abogusTableS1 = "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe="
	abogusTableS2 = "Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe="
	abogusTableS3 = "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe"
	abogusTableS4 = "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe"
)

var _ = abogusTableS0
var _ = abogusTableS1
var _ = abogusTableS2

type toutiaoABogus struct {
	uaCode      []byte
	browserLen  int
	browserCode []byte
}

func newToutiaoABogus(userAgent, platform string) *toutiaoABogus {
	browser := abogusBrowserInfo(platform)
	return &toutiaoABogus{
		uaCode:      abogusUACode(userAgent),
		browserLen:  len(browser),
		browserCode: []byte(browser),
	}
}

// abogusSM3：py _sm3_arr。hongguoSM3 与 py sm3 同为标准 SM3（py 自检向量见 VERIFY.md）。
func abogusSM3(data []byte) []byte {
	sum := hongguoSM3(data)
	return sum[:]
}

// abogusRC4：py _rc4，标准 RC4，[]byte 版。
func abogusRC4(plain, key []byte) []byte {
	var s [256]byte
	for i := range s {
		s[i] = byte(i)
	}
	j := 0
	for i := 0; i < 256; i++ {
		j = (j + int(s[i]) + int(key[i%len(key)])) % 256
		s[i], s[j] = s[j], s[i]
	}
	i, j := 0, 0
	out := make([]byte, len(plain))
	for k := range plain {
		i = (i + 1) % 256
		j = (j + int(s[i])) % 256
		s[i], s[j] = s[j], s[i]
		out[k] = s[(int(s[i])+int(s[j]))%256] ^ plain[k]
	}
	return out
}

// abogusResult：py _result。自定义 base64，每 3 字节编 4 字，末尾补 '='。
func abogusResult(data []byte, table string) string {
	var r []byte
	masks := []int{0xFC0000, 0x03F000, 0x0FC0, 0x3F}
	for i := 0; i < len(data); i += 3 {
		var n int
		if i+2 < len(data) {
			n = int(data[i])<<16 | int(data[i+1])<<8 | int(data[i+2])
		} else if i+1 < len(data) {
			n = int(data[i])<<16 | int(data[i+1])<<8
		} else {
			n = int(data[i]) << 16
		}
		for k, j := range []int{18, 12, 6, 0} {
			if j == 6 && i+1 >= len(data) {
				break
			}
			if j == 0 && i+2 >= len(data) {
				break
			}
			r = append(r, table[(n&masks[k])>>j])
		}
	}
	for len(r)%4 != 0 {
		r = append(r, '=')
	}
	return string(r)
}

// abogusUACode：py _ua_code。key 为 chr(0)+chr(1)+chr(14)。
func abogusUACode(userAgent string) []byte {
	rc := abogusRC4([]byte(userAgent), []byte{0, 1, 14})
	return abogusSM3([]byte(abogusResult(rc, abogusTableS3)))
}

// abogusRandFloat：[0, 10000) 均匀随机数，替代 py random.random()*10000。
func abogusRandFloat() float64 {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return float64(time.Now().UnixNano()%10000) + 0.5
	}
	return float64(binary.LittleEndian.Uint64(buf[:])) / float64(1<<64) * 10000
}

// abogusRandInt：闭区间随机整数，替代 py random.randint。
func abogusRandInt(min, max int) int {
	if max <= min {
		return min
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(max-min+1)))
	if err != nil {
		return min + int(time.Now().UnixNano()%int64(max-min+1))
	}
	return min + int(n.Int64())
}

// abogusRandList：py _rand_list。
func abogusRandList(b, c, d, e, f, g int) []int {
	r := abogusRandFloat()
	v1 := int(r) & 255
	v2 := int(r) >> 8
	return []int{(v1 & b) | d, (v1 & c) | e, (v2 & b) | f, (v2 & c) | g}
}

// abogusStr1：py _str1，12 个随机字节。
func abogusStr1() []byte {
	out := []int{}
	out = append(out, abogusRandList(170, 85, 1, 2, 5, 45&170)...)
	out = append(out, abogusRandList(170, 85, 1, 0, 0, 0)...)
	out = append(out, abogusRandList(170, 85, 1, 0, 5, 0)...)
	raw := make([]byte, len(out))
	for i, v := range out {
		raw[i] = byte(v)
	}
	return raw
}

// abogusBrowserInfo：py _browser_info。
func abogusBrowserInfo(platform string) string {
	iw := abogusRandInt(1280, 1920)
	ih := abogusRandInt(720, 1080)
	ow := abogusRandInt(iw, 1920)
	oh := abogusRandInt(ih, 1080)
	choice := 0
	if abogusRandInt(0, 1) == 1 {
		choice = 30
	}
	vals := []string{
		strconv.Itoa(iw), strconv.Itoa(ih), strconv.Itoa(ow), strconv.Itoa(oh),
		"0", strconv.Itoa(choice), "0", "0",
		strconv.Itoa(ow), strconv.Itoa(oh), strconv.Itoa(ow), strconv.Itoa(oh),
		strconv.Itoa(iw), strconv.Itoa(ih), "24", "24", platform,
	}
	return strings.Join(vals, "|")
}

// abogusList4：py _list4，44 元固定模板。
func abogusList4(a, b, c, d, e, f, g, h, i, j, k, m, n, o, p, q, r int) []int {
	return []int{44, a, 0, 0, 0, 0, 24, b, n, 0, c, d, 0, 0, 0, 1, 0, 239,
		e, o, f, g, 0, 0, 0, 0, h, 0, 0, 14, i, j, 0, k, m, 3, p, 1, q, 1, r, 0, 0, 0}
}

func (a *toutiaoABogus) str2List(urlParams, method string) []int {
	st := time.Now().UnixMilli()
	et := st + int64(abogusRandInt(4, 8))
	pa := abogusSM3(abogusSM3([]byte(urlParams + "cus")))
	ma := abogusSM3(abogusSM3([]byte(method + "cus")))
	return abogusList4(
		int((et>>24)&255), int(pa[21]), int(a.uaCode[23]),
		int((et>>16)&255), int(pa[22]), int(a.uaCode[24]),
		int((et>>8)&255), int(et&255),
		int((st>>24)&255), int((st>>16)&255), int((st>>8)&255), int(st&255),
		int(ma[21]), int(ma[22]),
		int(et>>32),
		int(st>>32),
		a.browserLen,
	)
}

func (a *toutiaoABogus) str2(urlParams, method string) []byte {
	arr := a.str2List(urlParams, method)
	chk := 0
	for _, x := range arr {
		chk ^= x
	}
	raw := make([]byte, 0, len(arr)+len(a.browserCode)+1)
	for _, x := range arr {
		raw = append(raw, byte(x))
	}
	raw = append(raw, a.browserCode...)
	raw = append(raw, byte(chk))
	return abogusRC4(raw, []byte("y"))
}

// generate：py generate。queryString 必须是最终发出的 urlencoded 参数串（顺序固定），
// 签名与发出串不一致服务端会验签失败。
func (a *toutiaoABogus) generate(queryString string) string {
	s := append(abogusStr1(), a.str2(queryString, "GET")...)
	return abogusResult(s, abogusTableS4)
}

// ---- 推荐流 ----

type toutiaoFeedEntry struct {
	itemID   string
	title    string
	abstract string
	cover    string
	url      string
	expire   int
	duration int
}

type toutiaoFeedState struct {
	mu    sync.Mutex
	items map[string]map[string]any
	list  []toutiaoFeedEntry
	at    time.Time
}

var toutiaoFeedCache = &toutiaoFeedState{items: map[string]map[string]any{}}

func toutiaoMSToken() string {
	const pool = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	raw := make([]byte, 107)
	if _, err := rand.Read(raw); err != nil {
		for i := range raw {
			raw[i] = pool[time.Now().UnixNano()%int64(len(pool))]
		}
		return string(raw) + "=="
	}
	for i, b := range raw {
		raw[i] = pool[int(b)%len(pool)]
	}
	return string(raw) + "=="
}

// toutiaoFeedQuery：参数顺序与 py _fetch 的 dict 顺序一致，签名与发出串同一条。
func toutiaoFeedQuery(offset, cursor int) string {
	pairs := [][2]string{
		{"min_behot_time", strconv.Itoa(cursor)},
		{"offset", strconv.Itoa(offset)},
		{"channel_id", toutiaoFeedChannelID},
		{"category", "pc_profile_channel"},
		{"disable_raw_data", "true"},
		{"client_extra_params", `{"playparam":"codec_type:0,enable_dash:1,unwatermark:1"}`},
		{"aid", "24"},
		{"app_name", "toutiao_web"},
		{"msToken", toutiaoMSToken()},
	}
	parts := make([]string, 0, len(pairs))
	for _, pair := range pairs {
		parts = append(parts, pair[0]+"="+url.QueryEscape(pair[1]))
	}
	return strings.Join(parts, "&")
}

func (downloader *Downloader) toutiaoHTTPClient() *http.Client {
	if downloader.client != nil {
		return downloader.client
	}
	return http.DefaultClient
}

// toutiaoFetchPage：py _fetch。返回原始条目（map），并写入条目缓存。
func (downloader *Downloader) toutiaoFetchPage(ctx context.Context, offset, cursor int) ([]map[string]any, error) {
	query := toutiaoFeedQuery(offset, cursor)
	sign := newToutiaoABogus(toutiaoFeedUA, "Win32").generate(query)
	address := toutiaoFeedAPI + "?" + query + "&a_bogus=" + url.QueryEscape(sign)
	callCtx, cancel := context.WithTimeout(ctx, toutiaoFeedTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(callCtx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", toutiaoFeedUA)
	request.Header.Set("Referer", "https://www.toutiao.com/")
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	response, err := downloader.toutiaoHTTPClient().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("头条推荐流返回 HTTP %d", response.StatusCode)
	}
	var decoded map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, errors.New("头条推荐流未返回有效数据")
	}
	rows := anyList(decoded["data"])
	items := make([]map[string]any, 0, len(rows))
	toutiaoFeedCache.mu.Lock()
	for _, row := range rows {
		m, _ := row.(map[string]any)
		if m == nil {
			continue
		}
		items = append(items, m)
		if id := toutiaoAnyString(m["item_id"]); id != "" {
			toutiaoFeedCache.items[id] = m
		}
	}
	if len(toutiaoFeedCache.items) > 5000 {
		toutiaoFeedCache.items = map[string]map[string]any{}
		for _, m := range items {
			if id := toutiaoAnyString(m["item_id"]); id != "" {
				toutiaoFeedCache.items[id] = m
			}
		}
	}
	toutiaoFeedCache.mu.Unlock()
	return items, nil
}

// hongguoNewToutiaoSample：py _sample 的顺序版。逐页拉，50 秒软预算内尽早停。
func (downloader *Downloader) hongguoNewToutiaoSample(ctx context.Context, start, pages, step int) []map[string]any {
	started := time.Now()
	seen := map[string]bool{}
	var out []map[string]any
	for i := 0; i < pages; i++ {
		if err := ctx.Err(); err != nil {
			break
		}
		if i > 0 && len(out) >= 10 && time.Since(started) > toutiaoFeedSampleBudget {
			break
		}
		items, err := downloader.toutiaoFetchPage(ctx, start+i*step, 0)
		if err != nil {
			continue
		}
		for _, item := range items {
			id := toutiaoAnyString(item["item_id"])
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, item)
		}
	}
	return out
}

func toutiaoAnyString(value any) string {
	switch item := value.(type) {
	case string:
		return item
	case json.Number:
		return item.String()
	case float64:
		return strconv.FormatInt(int64(item), 10)
	case nil:
		return ""
	default:
		return strings.TrimSpace(fmt.Sprint(item))
	}
}

func toutiaoAnyInt(value any) int {
	switch item := value.(type) {
	case json.Number:
		n, _ := item.Int64()
		return int(n)
	case float64:
		return int(item)
	case int:
		return item
	case int64:
		return int(item)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(item))
		return n
	default:
		return 0
	}
}

// toutiaoFirstURL：py _first_url。字符串直取；对象取 url_list 首个 url。
func toutiaoFirstURL(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	m, _ := value.(map[string]any)
	if m == nil {
		return ""
	}
	for _, row := range anyList(m["url_list"]) {
		switch item := row.(type) {
		case string:
			if item != "" {
				return item
			}
		case map[string]any:
			if u := mapString(item, "url"); u != "" {
				return u
			}
		}
	}
	return ""
}

func toutiaoPlay(item map[string]any) (string, int, int) {
	video := nestedMap(item, "video")
	rawURL := toutiaoFirstURL(video["play_addr"])
	if rawURL == "" {
		rawURL = toutiaoFirstURL(video["download_addr"])
	}
	return rawURL, toutiaoAnyInt(video["url_expire"]), toutiaoAnyInt(video["duration"])
}

func toutiaoCover(item map[string]any) string {
	video := nestedMap(item, "video")
	if u := toutiaoFirstURL(video["origin_cover"]); u != "" {
		return u
	}
	if u := toutiaoFirstURL(video["dynamic_cover"]); u != "" {
		return u
	}
	for _, key := range []string{"large_image_list", "thumb_image_list", "first_frame_image_list"} {
		rows := anyList(item[key])
		if len(rows) > 0 {
			if u := toutiaoFirstURL(rows[0]); u != "" {
				return u
			}
		}
	}
	return toutiaoFirstURL(item["image_url"])
}

var (
	toutiaoTitleHash   = regexp.MustCompile(`#[^#\s]{1,40}#?`)
	toutiaoTitleSpaces = regexp.MustCompile(`\s+`)
	toutiaoTitleTail   = regexp.MustCompile(`[\s，,]*了?短剧[\s，,]*$`)
	toutiaoTitleChars  = regexp.MustCompile(`[#\s]+`)
)

// toutiaoCleanTitle：py _clean_title。
func toutiaoCleanTitle(raw string) string {
	if raw == "" {
		return ""
	}
	x := toutiaoTitleHash.ReplaceAllString(raw, " ")
	x = toutiaoTitleSpaces.ReplaceAllString(x, " ")
	x = strings.Trim(x, " -|")
	x = toutiaoTitleTail.ReplaceAllString(x, "")
	x = strings.TrimSpace(x)
	if x == "" {
		x = strings.TrimSpace(toutiaoTitleChars.ReplaceAllString(raw, " "))
		if len([]rune(x)) > 40 {
			x = string([]rune(x)[:40])
		}
	}
	if x == "" {
		return "头条视频"
	}
	return x
}

// hongguoNewToutiaoList：py list_vods。600 秒缓存；force 刷新；30 秒以下跳过；按时长倒序。
func (downloader *Downloader) hongguoNewToutiaoList(ctx context.Context, force bool) ([]Drama, error) {
	toutiaoFeedCache.mu.Lock()
	if !force && len(toutiaoFeedCache.list) > 0 && time.Since(toutiaoFeedCache.at) < toutiaoFeedCacheTTL {
		cached := append([]toutiaoFeedEntry(nil), toutiaoFeedCache.list...)
		toutiaoFeedCache.mu.Unlock()
		return toutiaoFeedEntriesToDramas(cached), nil
	}
	toutiaoFeedCache.mu.Unlock()

	items := downloader.hongguoNewToutiaoSample(ctx, 0, 24, 10)
	entries := []toutiaoFeedEntry{}
	seen := map[string]bool{}
	n := 0
	for _, item := range items {
		playURL, expire, dur := toutiaoPlay(item)
		if playURL == "" || (dur > 0 && dur < 30) {
			continue
		}
		id := toutiaoAnyString(item["item_id"])
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		n++
		title := toutiaoCleanTitle(toutiaoAnyString(item["title"]))
		if len([]rune(title)) < 4 {
			title = fmt.Sprintf("头条视频 %02d", n)
		}
		entries = append(entries, toutiaoFeedEntry{
			itemID: id, title: title, abstract: toutiaoAnyString(item["abstract"]),
			cover: toutiaoCover(item), url: playURL, expire: expire, duration: dur,
		})
	}
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].duration > entries[j].duration })
	toutiaoFeedCache.mu.Lock()
	toutiaoFeedCache.list = append([]toutiaoFeedEntry(nil), entries...)
	toutiaoFeedCache.at = time.Now()
	toutiaoFeedCache.mu.Unlock()
	if len(entries) == 0 {
		return nil, errors.New("头条精选暂未返回视频")
	}
	return toutiaoFeedEntriesToDramas(entries), nil
}

func toutiaoFeedEntriesToDramas(entries []toutiaoFeedEntry) []Drama {
	out := make([]Drama, 0, len(entries))
	for _, entry := range entries {
		remark := ""
		if entry.duration >= 60 {
			remark = fmt.Sprintf("%d分钟", entry.duration/60)
		} else if entry.duration > 0 {
			remark = fmt.Sprintf("%d秒", entry.duration)
		}
		sourceID := "tt_" + entry.itemID
		abstract := entry.abstract
		if abstract == "" {
			abstract = entry.title
		}
		out = append(out, Drama{
			ID: providerDramaID(sourceHongguoNew, sourceID), Source: sourceHongguoNew, SourceID: sourceID,
			Title: entry.title, Name: entry.title, Desc: abstract, Intro: abstract,
			Cover: entry.cover, CoverURL: entry.cover,
			CategoryName: "头条精选", ChannelName: hongguoNewChannelName, Remark: remark,
		})
	}
	return out
}

// hongguoNewToutiaoFind：py find。缓存命中直接取，否则顺序采样 12 页再找。
func (downloader *Downloader) hongguoNewToutiaoFind(ctx context.Context, itemID string) (map[string]any, bool) {
	toutiaoFeedCache.mu.Lock()
	item, ok := toutiaoFeedCache.items[itemID]
	toutiaoFeedCache.mu.Unlock()
	if ok {
		return item, true
	}
	downloader.hongguoNewToutiaoSample(ctx, 0, 12, 10)
	toutiaoFeedCache.mu.Lock()
	item, ok = toutiaoFeedCache.items[itemID]
	toutiaoFeedCache.mu.Unlock()
	return item, ok
}

// fetchHongguoNewToutiaoDetail：py _tt_detail。单集“正片”，直链现取现放。
func (downloader *Downloader) fetchHongguoNewToutiaoDetail(ctx context.Context, itemID string) (Drama, []Chapter, error) {
	item, ok := downloader.hongguoNewToutiaoFind(ctx, itemID)
	if !ok {
		return Drama{}, nil, errors.New("头条视频不存在或已下架")
	}
	playURL, _, dur := toutiaoPlay(item)
	if playURL == "" {
		return Drama{}, nil, errors.New("头条视频没有可播放的地址")
	}
	title := toutiaoCleanTitle(toutiaoAnyString(item["title"]))
	if title == "" {
		title = "头条视频"
	}
	remark := ""
	if dur >= 60 {
		remark = fmt.Sprintf("%d分钟", dur/60)
	} else if dur > 0 {
		remark = fmt.Sprintf("%d秒", dur)
	}
	abstract := toutiaoAnyString(item["abstract"])
	if abstract == "" {
		abstract = title
	}
	sourceID := "tt_" + itemID
	drama := Drama{
		ID: providerDramaID(sourceHongguoNew, sourceID), Source: sourceHongguoNew, SourceID: sourceID,
		Title: title, Name: title, Desc: abstract, Intro: abstract,
		Cover: toutiaoCover(item), CoverURL: toutiaoCover(item),
		CategoryName: "头条精选", ChannelName: hongguoNewChannelName, Remark: remark,
	}
	chapter := Chapter{
		ID:             providerChapterID(sourceHongguoNew, sourceID, "1"),
		Source:         sourceHongguoNew,
		Title:          "正片",
		VideoURL:       playURL,
		Referer:        "https://www.toutiao.com/",
		CurrentEpisode: rawEpisode(1),
	}
	return drama, []Chapter{chapter}, nil
}
