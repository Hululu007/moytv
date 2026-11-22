package seku

import (
	"regexp"
	"strings"
)

// ---- v52 第一批移植源（真果鉴 → 魔蚁片库）----
//
// 三站全部逐条实测（2026-11-22，出境直连，非猜测）：
//   youguo 柚果 youavhub.com  —— 标准苹果CMS JSON 接口，10.1 万条；
//           分类/列表/详情/播放(m3u8)/搜索全通，详情带完整简介。
//   llsp   榴莲视频 www.llsp.me —— 模板站；列表 28 条/页、37 个分类、
//           分页 /vodtype/{cat}-{page}.html 实测两页无重合；播放页的
//           m3u8 是 JSON 转义串（https:\/\/...），由 PlayFix 反转义。
//   ririlu 日日撸 ririlu.cc    —— 模板站；列表 24 条/页、6 个分类、
//           分页 /vodshow/{cat}-----------/page/{n}/ 实测无重合；
//           卡片自带标题，详情页 <title> 里夹着书名号标题。

// 柚果：苹果CMS JSON 接口。
var youguoImpl = mcAPIImpl("youguo", "🔞柚果", &mcAPIConfig{
	Base: "https://youavhub.com",
	UA:   z2UA,
})

// unescapePlay 还原播放地址里的 JSON 转义（\/ → /）。
func unescapePlay(u string) string {
	u = strings.ReplaceAll(u, `\/`, "/")
	u = strings.ReplaceAll(u, `\u0026`, "&")
	return strings.TrimSpace(u)
}

var (
	// 播放页里的 m3u8（可能带转义），取整串再交给 unescapePlay。
	newBatchM3U8Re = regexp.MustCompile(`https?:\\?/\\?/[^"'<>\s]+?\.m3u8[^"'<>\s]*`)
)

// ---- 榴莲视频 www.llsp.me ----

var llspCats = []htmlCat{
	{ID: "3", Name: "国产精品"},
	{ID: "4", Name: "国产自拍"},
	{ID: "5", Name: "国产偷拍"},
	{ID: "6", Name: "探花视频"},
	{ID: "7", Name: "主播福利"},
	{ID: "8", Name: "丝袜恋足"},
	{ID: "9", Name: "网红爆料"},
	{ID: "10", Name: "明星换脸"},
	{ID: "11", Name: "母狗调教"},
	{ID: "12", Name: "国产乱伦"},
	{ID: "13", Name: "学生嫩妹"},
	{ID: "14", Name: "人妻少妇"},
	{ID: "15", Name: "港台美女"},
	{ID: "16", Name: "抖阴视频"},
	{ID: "17", Name: "麻豆传媒"},
	{ID: "18", Name: "日韩情色"},
	{ID: "20", Name: "日本无码"},
	{ID: "21", Name: "韩国无码"},
	{ID: "22", Name: "欧美无码"},
	{ID: "23", Name: "中文字幕"},
	{ID: "24", Name: "黄色动漫"},
	{ID: "25", Name: "三级伦理"},
	{ID: "26", Name: "香港三级"},
	{ID: "27", Name: "韩国三级"},
	{ID: "28", Name: "丝袜制服"},
	{ID: "29", Name: "童颜巨乳"},
	{ID: "30", Name: "熟女人妻"},
	{ID: "31", Name: "少女萝莉"},
	{ID: "32", Name: "强奸乱伦"},
	{ID: "33", Name: "变态调教"},
	{ID: "34", Name: "女优高清"},
	{ID: "35", Name: "淫乱群交"},
	{ID: "36", Name: "口交颜射"},
	{ID: "37", Name: "男同女同"},
	{ID: "38", Name: "淫语解说"},
	{ID: "39", Name: "第一视角"},
	{ID: "40", Name: "女优大全"},
}

var llspProfile = &htmlProfile{
	Base:    "https://www.llsp.me",
	UA:      z2UA,
	Cats:    llspCats,
	ListURL: "/vodtype/{cat}-{page}.html",
	ItemRe: regexp.MustCompile(
		`href="/vodplay/(?P<id>\d+)-\d+-\d+\.html"[^>]*title="(?P<title>[^"]*)"[\s\S]{0,400}?<img src="(?P<cover>[^"]+)"`),
	DetailURL: "/vodplay/{id}-1-1.html",
	TitleRe:   regexp.MustCompile(`(?s)<h1[^>]*>([^<]+)</h1>`),
	PlayRes:   []*regexp.Regexp{newBatchM3U8Re},
	PlayFix:   unescapePlay,
	SearchURL: "/vodsearch/-------------.html?wd={kw}",
	Format:    "m3u8",
}

// ---- 日日撸 ririlu.cc ----

var ririluCats = []htmlCat{
	{ID: "28", Name: "中文字幕"},
	{ID: "20", Name: "国产"},
	{ID: "21", Name: "日本有码"},
	{ID: "22", Name: "日本无码"},
	{ID: "23", Name: "欧美"},
	{ID: "24", Name: "动漫"},
}

var ririluProfile = &htmlProfile{
	Base:    "https://ririlu.cc",
	UA:      z2UA,
	Cats:    ririluCats,
	ListURL: "/vodshow/{cat}-----------/page/{page}/",
	ItemRe: regexp.MustCompile(
		`href="/vodplay/(?P<id>\d+)-1-1/"[^>]*>[\s\S]{0,600}?data-src="(?P<cover>[^"]+)"[\s\S]{0,600}?<div class="desc">(?P<title>[^<]+)</div>`),
	DetailURL: "/vodplay/{id}-1-1/",
	TitleRe:   regexp.MustCompile(`《([^》]+)》`),
	PlayRes:   []*regexp.Regexp{newBatchM3U8Re},
	PlayFix:   unescapePlay,
	SearchURL: "/vodsearch/-------------.html?wd={kw}",
	Format:    "m3u8",
}

func init() {
	registerSite("youguo", youguoImpl, "柚果", "youavhub")
	registerSite("llsp", htmlProfileImpl("llsp", "🔞榴莲视频", llspProfile), "榴莲视频", "llsp")
	registerSite("ririlu", htmlProfileImpl("ririlu", "🔞日日撸", ririluProfile), "日日撸", "ririlu")
}
