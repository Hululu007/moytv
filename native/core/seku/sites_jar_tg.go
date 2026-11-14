package seku

// TG频道 — bespoke gateway over Telegram channel mirrors,
// recipe verified live 2026-10-24:
//   Mirror: https://tg.i-c-a.su (ext "mirror" of the jar config).
//   Catalog: GET {mirror}/json/{user}?limit=50&page={n} answers an
//   MTProto-shaped payload {count, messages:[{id, message, media}]}
//   (verified: cctv_av count 62019). Messages whose media is a video
//   document become cards; text is ad-filtered with the jar's keyword
//   list (isAd in the jar class).
//   Cover: {mirror}/media/{user}/{id}/preview/thumb.jpeg
//   Play:  {mirror}/media/{user}/{id}/video.mp4 (the jar's videoUrl
//   also knows a /media?ch=&id= form; the RESTful form matches the
//   mirror's own /media/{ch}/{id}/ routes used by its RSS mode).
//   Channels are the jar config's ext channels (91, formerly the
//   jar registration's ext list).
//   Search: the jar filters channel message text locally; here the
//   first page of every channel is scanned for the keyword.

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

const tgMirror = "https://tg.i-c-a.su"
const tgUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
const tgPageSize = 50

var tgChannels = []htmlCat{
	{ID: "cctv_av", Name: "超清AV"},
	{ID: "zfjp1024", Name: "那些极品姐姐"},
	{ID: "madougirl", Name: "麻豆 girl"},
	{ID: "hgmanju", Name: "黄果漫剧"},
	{ID: "hjgc0", Name: "海角 AV"},
	{ID: "wmav91", Name: "无码 91"},
	{ID: "shoucangav", Name: "收藏 AV"},
	{ID: "wwhjieym", Name: "精选网红御姐美女免费视频！"},
	{ID: "jav_all", Name: "日本精品av|中文字幕|Jav"},
	{ID: "onlyjavzh", Name: "JAV中字"},
	{ID: "lvmaodjw", Name: "夫妻社绿帽换妻"},
	{ID: "hing475", Name: "海角少妇御姐少女"},
	{ID: "JableTVB", Name: "日本AV|母子乱伦|巨乳调教💯"},
	{ID: "xunhuanzyk", Name: "推特X日本素人"},
	{ID: "AVGQWM8", Name: "日本 AV💋 无码 高清"},
	{ID: "hbzh66", Name: "时光网🔞女主播的另一面"},
	{ID: "NEWFC2", Name: "无码FC2｜优质精选｜高画质｜磁力链接｜115·迅雷·PikPak"},
	{ID: "AiHg1", Name: "ai短剧 黄果短剧"},
	{ID: "nsbwg29999", Name: "反差女神博物馆"},
	{ID: "javbest", Name: "AV番号精选-种子磁链下载"},
	{ID: "avpush2", Name: "AV日报-无码|步兵|种子|磁链|下载|高清|日本"},
	{ID: "craimgd", Name: "AI成人短剧/黄果短剧/黄豆魔改短剧"},
	{ID: "bbbjhbgq", Name: "推特精选"},
	{ID: "tgtgxiuren", Name: "推特X极品姐姐"},
	{ID: "cili8888", Name: "磁力链接精选福利集"},
	{ID: "seliao212", Name: "抖音网红丨色料吃瓜"},
	{ID: "haijiao133", Name: "糖心丨麻豆丨swag丨国产AV"},
	{ID: "jianhuangxxiaoz", Name: "鉴黄小镇"},
	{ID: "hg678678", Name: "网红主播直播"},
	{ID: "lspjsn", Name: "淫妻反差俱乐部"},
	{ID: "porncloud004", Name: "🎥日本AV| JAV |中文字幕|番号资源库"},
	{ID: "av8plus", Name: "🎥 色情云|日本AV| JAV |中文字幕|番号资源库"},
	{ID: "AVkanpian01", Name: "日本 AV 一本道"},
	{ID: "muziLL01", Name: "母子乱伦|伦理|妈妈"},
	{ID: "s4tv5Wm2ACBw", Name: "绿帽精选🅥少妇人妻"},
	{ID: "youwu1av", Name: "AV｜有码AV｜无码AV"},
	{ID: "duanjvshev1", Name: "🅰️明星短剧|Ai短剧社🅰️"},
	{ID: "link_ces", Name: "甄选AI | AI成人短剧 |黄果短剧"},
	{ID: "xianfeng192", Name: "酒店 监控 直播 偷窥 大学城"},
	{ID: "knapianzhibo", Name: "网红 肛交 直播 泄密"},
	{ID: "aivovvo", Name: "AI短剧丨成人AI丨成人短剧"},
	{ID: "ASC2256", Name: "AI成人短剧 免费看 【黄果短剧】"},
	{ID: "flapxz3", Name: "糖心丨AV小站"},
	{ID: "DuanJuPD", Name: "短剧在线看(短剧频道）"},
	{ID: "JMFCXMG", Name: "绝美反差学生少妇"},
	{ID: "avwmjav", Name: "AV无码原片-日本"},
	{ID: "tuite_onlyfans_vlog", Name: "推特| onlyfans | 糖心 | 各大传媒 综合福利群"},
	{ID: "zhuzhuxia999666", Name: "猪猪侠 GG Bond"},
	{ID: "AV688", Name: "AV收藏|优质精选|无码破解|中文字幕|番号磁力大全"},
	{ID: "dyxfvip", Name: "电影先锋"},
	{ID: "seqingtvb", Name: "飞鸟社备用"},
	{ID: "mic6388av", Name: "🇭🇰男人唔咸濕AV專線"},
	{ID: "ai6944", Name: "ai短剧 成人漫改"},
	{ID: "avjx_zongbu", Name: "AV精选|AI短剧|中文字幕|无码|破解|国产|直播|欧美"},
	{ID: "tbheji", Name: "日本AV"},
	{ID: "laochenzukong", Name: "推特of国产丝袜足交"},
	{ID: "huangmangaix", Name: "银河舰のai成人短剧制作"},
	{ID: "FLJMRGX", Name: "推特onlyfans网红福利姬"},
	{ID: "JMsfJZY", Name: "推特|fansone|福利分享"},
	{ID: "wumingzhidao123", Name: "日本AV丨破解无码丨巨乳颜值"},
	{ID: "snwohu", Name: "AI成人短剧（黄果短剧最全版）"},
	{ID: "sese0002", Name: "国产成人短剧🔞Ai精选"},
	{ID: "cosfulimax", Name: "中文字幕 | 日本AV即是正义！"},
	{ID: "AV_cao", Name: "AV/番号/无码/高清💿"},
	{ID: "mugouyinqiesf1245", Name: "AI短剧⭕️真人擦边短剧"},
	{ID: "chengdudiyi8", Name: "海角社区母子强奸乱伦俱乐部"},
	{ID: "Lovese1", Name: "涩涩之家｜推特｜网红｜福利"},
	{ID: "kzwbx8", Name: "尤物私密档案の收藏研究所"},
	{ID: "rbjx336", Name: "日本精选无码优质av资源分享"},
	{ID: "kbxzs8", Name: "甜心俱乐部の私密收藏基地"},
	{ID: "fcii91", Name: "反差白虎母狗少妇合集"},
	{ID: "SURENrenqi01", Name: "人妻|素人|少妇"},
	{ID: "pikpaklove", Name: "PIKPAK成人磁力资源大全"},
	{ID: "rbav00", Name: "日本AV中文学习资料"},
	{ID: "CosSSDZH", Name: "Cos涩涩大杂烩"},
	{ID: "tuite905", Name: "推特反差淫妻"},
	{ID: "misscctav", Name: "日本AV｜中文字幕｜无码高清"},
	{ID: "AV114514", Name: "国产AV｜优质精选｜@AV114514"},
	{ID: "ZWmeiriDS", Name: "每日大赛|中文福利"},
	{ID: "TG1178", Name: "电影天堂|电影视界|超清影视"},
	{ID: "ahmufa18", Name: "经典电影|影视天地|影视精选"},
	{ID: "diiejl", Name: "涩涩窝窝"},
	{ID: "bisequcom", Name: "BiBi色区🔞丨自拍丨熟女丨国产"},
	{ID: "yujiezy", Name: "极品-互联网珍藏"},
	{ID: "xianyu44", Name: "全网精选资源🔞"},
	{ID: "LSJTV1", Name: "老司机电视剧-归档"},
	{ID: "haijiaojingxuan", Name: "海角社区|偷情乱伦精选"},
	{ID: "PornhubSexCN", Name: "人妻少妇绿帽"},
	{ID: "yesluvip", Name: "🔞反差|吃瓜|探花|直播|偷拍|口交🥵"},
	{ID: "HTPorn13", Name: "熟女人妻少妇"},
	{ID: "dsju123", Name: "电视剧频道"},
	{ID: "cabianduanjuheji", Name: "擦边短剧"},
	{ID: "yjns52", Name: "御姐女神"},
	{ID: "qweasd886688", Name: "肉棒/母狗/女友/小妹🧿"},
	{ID: "edxrfcvgt666", Name: "白虎 美乳 大秀 国产"},
	{ID: "tmfcjjy", Name: "AI成人短剧 红果短剧 反差"},
	{ID: "Hhd728299", Name: "国产精品『网红 嫩妹 情侣』"},
	{ID: "juru95", Name: "口爆🫦颜射"},
	{ID: "sdohsdposn_985", Name: "监控公寓 大学城直播"},
	{ID: "swzj8", Name: "丝袜足交"},
	{ID: "wmAV98", Name: "日本AV高清无码（中文字幕）"},
	{ID: "xiaoeizzz", Name: "日本AV|中文字幕|女优资源库"},
	{ID: "afxvf364", Name: "反差少女（母狗泄密）"},
	{ID: "maozi9294", Name: "反差约炮海角吃瓜"},
	{ID: "meimeisea", Name: "真实乱伦日本AV母亲妈妈近亲"},
	{ID: "RBJX668", Name: "日本无码破解AV精选"},
	{ID: "nygsp200", Name: "🥑牛油果·优质甄选"},
	{ID: "rmskgq", Name: "热门4K高清电影大全"},
	{ID: "Japanfc22", Name: "欧美剧情中文网/AV字幕精选"},
	{ID: "SJAV66", Name: "太古体育冠名/三级电影精品复古世家/TG/电子/真人/捕鱼"},
}

func tgChannelName(user string) string {
	for _, c := range tgChannels {
		if c.ID == user {
			return c.Name
		}
	}
	return user
}

func tgHeaders() map[string]string {
	return map[string]string{
		"User-Agent": tgUA,
		"Accept":     "application/json, text/plain, */*",
		"Referer":    tgMirror + "/",
	}
}

// tgAdWords is the jar's isAd keyword list (trimmed to the strongest
// signals) plus its @mention / group-lure regex behaviour.
var tgAdWords = []string{
	"博彩", "首存", "彩金", "返水", "招代理", "代理加盟", "包网", "招商",
	"加群", "客服", "下载app", "app下载", "看片神器", "发布页", "防失联",
	"备用域名", "永久域名", "资源站", "点击链接", "刷单", "日结", "外围",
	"楼凤", "推广", "广告位", "资源群", "进群", "电报", "订阅", "点赞",
	"获取更多", "更多资源", "最新地址", "导航", "防走失", "加微信", "微信号",
	"娱乐城", "真人荷官", "百家乐", "棋牌", "首充", "充值送", "官方直营",
	"秒到账", "注册送", "商务合作",
}

func tgIsAd(text string) bool {
	for _, w := range tgAdWords {
		if strings.Contains(text, w) {
			return true
		}
	}
	return false
}

type tgDocAttr struct {
	Type     string  `json:"_"`
	FileName string  `json:"file_name"`
	Duration float64 `json:"duration"`
	W        int     `json:"w"`
	H        int     `json:"h"`
}

type tgMessage struct {
	ID      int    `json:"id"`
	Message string `json:"message"`
	Media   *struct {
		Type     string `json:"_"`
		Document *struct {
			MimeType   string      `json:"mime_type"`
			Size       int64       `json:"size"`
			Attributes []tgDocAttr `json:"attributes"`
		} `json:"document"`
		Photo *json.RawMessage `json:"photo"`
	} `json:"media"`
}

type tgBlockResp struct {
	Count    int         `json:"count"`
	Messages []tgMessage `json:"messages"`
}

func tgFetchBlock(user string, page int) (*tgBlockResp, error) {
	return tgFetchBlockTO(user, page, 0)
}

var tgMu sync.Mutex
var tgLastReq time.Time

func tgThrottle() {
	tgMu.Lock()
	defer tgMu.Unlock()
	if d := time.Since(tgLastReq); d < time.Second {
		time.Sleep(time.Second - d)
	}
	tgLastReq = time.Now()
}

func tgFetchBlockTO(user string, page int, timeout time.Duration) (*tgBlockResp, error) {
	tgThrottle()
	u := fmt.Sprintf("%s/json/%s?limit=%d&page=%d", tgMirror, user, tgPageSize, page)
	var body []byte
	var code int
	var err error
	if timeout > 0 {
		body, code, _, err = httpGetTimeout(u, tgHeaders(), timeout)
	} else {
		body, code, _, err = httpGet(u, tgHeaders())
	}
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("tg http %d for %s", code, u)
	}
	var resp tgBlockResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("tg parse: %v", err)
	}
	return &resp, nil
}

func tgCard(slot string, user string, m tgMessage) map[string]interface{} {
	if m.Media == nil || m.Media.Document == nil {
		return nil
	}
	doc := m.Media.Document
	if !strings.HasPrefix(doc.MimeType, "video/") && !strings.HasSuffix(doc.MimeType, "mp4") {
		return nil
	}
	text := strings.TrimSpace(m.Message)
	if tgIsAd(text) {
		return nil
	}
	var fileName string
	var dur float64
	var w, h int
	for _, a := range doc.Attributes {
		if a.FileName != "" {
			fileName = a.FileName
		}
		if a.Duration > 0 {
			dur = a.Duration
		}
		if a.W > 0 {
			w, h = a.W, a.H
		}
	}
	title := ""
	if text != "" {
		title = strings.SplitN(text, "\n", 2)[0]
	}
	if title == "" {
		title = fileName
	}
	if title == "" {
		title = "视频 " + strconv.Itoa(m.ID)
	}
	title = cleanText(title)
	if len([]rune(title)) > 80 {
		title = string([]rune(title)[:80])
	}
	remark := ""
	if doc.Size > 0 {
		remark = fmt.Sprintf("%.1fMB", float64(doc.Size)/1048576)
	}
	if dur > 0 {
		if remark != "" {
			remark += " · "
		}
		remark += strconv.Itoa(int(dur)/60) + "分钟"
	}
	if w > 0 {
		if remark != "" {
			remark += " · "
		}
		remark += strconv.Itoa(w) + "x" + strconv.Itoa(h)
	}
	rawID := user + ":" + strconv.Itoa(m.ID)
	pic := fmt.Sprintf("%s/media/%s/%d/preview/thumb.jpeg", tgMirror, user, m.ID)
	d := makeDrama(slot, rawID, title, pic, remark, tgChannelName(user), cleanText(text))
	return d
}

func tgCatalog(slot, category string, page int) ([]interface{}, int, bool, error) {
	if page < 1 {
		page = 1
	}
	user := category
	if user == "" {
		user = tgChannels[0].ID
	}
	resp, err := tgFetchBlock(user, page)
	if err != nil {
		return nil, 0, false, err
	}
	items := []interface{}{}
	for _, m := range resp.Messages {
		if c := tgCard(slot, user, m); c != nil {
			items = append(items, c)
		}
	}
	return items, resp.Count, page*tgPageSize < resp.Count, nil
}

func tgSplitRaw(rawID string) (string, string, bool) {
	user, id, found := strings.Cut(rawID, ":")
	if !found || user == "" || id == "" {
		return "", "", false
	}
	return user, id, true
}

func tgDetail(slot, rawID string) (map[string]interface{}, error) {
	user, id, ok := tgSplitRaw(rawID)
	if !ok {
		return nil, fmt.Errorf("tg: bad id %q", rawID)
	}
	// The message may live on any recent page; scan the first pages
	// for the id (messages are newest-first, ids descend).
	for page := 1; page <= 3; page++ {
		resp, err := tgFetchBlock(user, page)
		if err != nil {
			return nil, err
		}
		for _, m := range resp.Messages {
			if strconv.Itoa(m.ID) == id {
				if c := tgCard(slot, user, m); c != nil {
					return c, nil
				}
				return nil, fmt.Errorf("tg: message %s is not a playable video", rawID)
			}
		}
	}
	// Not found in recent pages (older post opened from cache/search):
	// still hand back a playable shell — resolve needs only the id.
	pic := fmt.Sprintf("%s/media/%s/%s/preview/thumb.jpeg", tgMirror, user, id)
	return makeDrama(slot, rawID, "视频 "+id, pic, "", tgChannelName(user), ""), nil
}

func tgResolve(slot, rawID string) (map[string]interface{}, error) {
	user, id, ok := tgSplitRaw(rawID)
	if !ok {
		return nil, fmt.Errorf("tg: bad id %q", rawID)
	}
	u := fmt.Sprintf("%s/media/%s/%s/video.mp4", tgMirror, user, id)
	return playResult(u, slot, rawID, tgUA, tgMirror+"/", "mp4", "file"), nil
}

func tgSearch(slot, kw string) ([]interface{}, error) {
	kw = strings.TrimSpace(kw)
	if kw == "" {
		return []interface{}{}, nil
	}
	items := []interface{}{}
	for _, ch := range tgChannels {
		resp, err := tgFetchBlockTO(ch.ID, 1, 8*time.Second)
		if err != nil {
			continue
		}
		for _, m := range resp.Messages {
			if !strings.Contains(m.Message, kw) {
				continue
			}
			if c := tgCard(slot, ch.ID, m); c != nil {
				items = append(items, c)
			}
		}
		if len(items) >= 40 {
			break
		}
	}
	return items, nil
}

func init() {
	impl := &siteImpl{
		Key: "tg", Name: "🔞tg频道", DefaultCat: tgChannels[0].ID, HomeURL: tgMirror + "/",
		Headers: tgHeaders,
	}
	impl.Categories = func(slot string) []interface{} {
		out := []interface{}{}
		for _, c := range tgChannels {
			out = append(out, categoryObj(c.ID, c.Name))
		}
		return out
	}
	impl.Catalog = tgCatalog
	impl.Detail = tgDetail
	impl.Resolve = tgResolve
	impl.Search = tgSearch
	registerSite("tg", impl, "tg", "tg频道")
}
