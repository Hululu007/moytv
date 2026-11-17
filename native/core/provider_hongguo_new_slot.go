package core

// 红果(新)槽位：新原生源，与树里已有的红果源（sourceHongguo）并存，不替换、不改旧槽。
//
// 移植自用户 2026-11-17 发来的 hongguo_full_177_5sc7.py（1757 行，全集 + 五档清晰度版）。
// 本文件只放槽位定义、分类表、映射与筛选；目录/详情/取流/搜索/头条/自检见同名前缀的其它文件。
//
// 复用（不重复造轮子）：签名全套（SixGod）、multi_video_model 三腿、key_seed 解链、
// spade_a 派生、CENC 中继解密、设备注册与轮换、SSR 解析（parseRouterData / routerLoaderMap）、
// hongguoDramaFromAny 映射、fetchProviderText 传输。新增的只是本槽自己的分发外壳与 py 独有能力
// （搜索 JSON 接口、榜单作分类、服务端 topic 筛选、头条精选 a_bogus、自检分类）。

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"
)

// sourceHongguoNew：红果(新)槽位 id。Dart 侧 SourceSite id 同名（见 LANDING.md）。
const sourceHongguoNew = "hongguo_new"

// hongguoNewChannelName：新槽剧集的频道显示名。
const hongguoNewChannelName = "红果(新)"

// hongguoNewCENCURLPrefix：新槽分集的 VideoURL 前缀，与旧槽的 hongguo-cenc:// 区分，
// 避免分发与弹幕门控误认。取流时只取前缀后的 vid。
const hongguoNewCENCURLPrefix = "hongguo-new-cenc://"

// hongguoNewCategories：分类表与 py CATS（行 73-82）逐项对应，id 与名字都不改。
var hongguoNewCategories = []nativeCategory{
	{ID: "c:real-drama", Name: "真人剧"},
	{ID: "c:comic-drama", Name: "漫剧"},
	{ID: "c:ai-drama", Name: "AI剧"},
	{ID: "c:comic", Name: "漫画"},
	{ID: "r:hot-drama", Name: "热播总榜"},
	{ID: "r:hot-real-drama", Name: "真人剧榜"},
	{ID: "r:hot-comic-drama", Name: "漫剧榜"},
	{ID: "r:hot-ai-drama", Name: "AI剧榜"},
	{ID: "t:jx", Name: "头条精选"},
	{ID: "c:__diag__", Name: "自检诊断"},
}

// validHongguoNewCategory：空分类（首页）与上表 id 放行，其余拒绝。
func validHongguoNewCategory(category string) bool {
	if category == "" {
		return true
	}
	for _, entry := range hongguoNewCategories {
		if category == entry.ID {
			return true
		}
	}
	return false
}

// hongguoNewRelabelDrama：把 hongguoDramaFromAny 映射出的旧槽剧集改挂到新槽。
// 只改身份三字段（ID/Source/频道名），标题/封面/简介/标签等原样。
func hongguoNewRelabelDrama(drama Drama) Drama {
	if drama.SourceID == "" {
		return drama
	}
	drama.ID = providerDramaID(sourceHongguoNew, drama.SourceID)
	drama.Source = sourceHongguoNew
	drama.ChannelName = hongguoNewChannelName
	return drama
}

// hongguoNewRelabelDramas：批量改挂，跳过无 SourceID 的行。
func hongguoNewRelabelDramas(dramas []Drama) []Drama {
	out := make([]Drama, 0, len(dramas))
	for _, drama := range dramas {
		if drama.SourceID == "" {
			continue
		}
		out = append(out, hongguoNewRelabelDrama(drama))
	}
	return out
}

// hongguoNewDedupDramas：按 ID 去重（py _dedup），保持首次出现顺序。
func hongguoNewDedupDramas(dramas []Drama) []Drama {
	seen := make(map[string]bool, len(dramas))
	out := make([]Drama, 0, len(dramas))
	for _, drama := range dramas {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		out = append(out, drama)
	}
	return out
}

// ---- 服务端 topic 筛选（py homeContent 行 1301-1322）----
// 选项现取自 /category/real-drama 的 selectorList（show_name + category_json_ids[0]），
// 30 分钟缓存，避免每次目录请求都多拉一页；拉失败时只剩“全部”，不让目录失败。

var hongguoNewTopicCache struct {
	mu      sync.Mutex
	options []nativeFilterOption
	at      time.Time
}

const hongguoNewTopicCacheTTL = 30 * time.Minute

func hongguoNewFilterGroups(ctx context.Context, downloader *Downloader) []nativeFilterGroup {
	return []nativeFilterGroup{{Key: "topic", Name: "主题", Options: hongguoNewTopicOptions(ctx, downloader)}}
}

// hongguoNewTopicOptionsFromPage：从分类页 loader 里取 selectorList 的主题选项。
// selectorList 是行列表，每行的 items 是选项列表（show_name + category_json_ids[0]）。
// 注意 items 是列表不是字典，不能走 nestedMap（旧写法因此永远取不到选项，活测实证
// options 恒为 1）。
func hongguoNewTopicOptionsFromPage(page map[string]any) []nativeFilterOption {
	var options []nativeFilterOption
	for _, row := range anyList(page["selectorList"]) {
		rowMap, _ := row.(map[string]any)
		if rowMap == nil {
			continue
		}
		for _, item := range anyList(rowMap["items"]) {
			m, _ := item.(map[string]any)
			if m == nil {
				continue
			}
			name := mapString(m, "show_name")
			ids := anyList(m["category_json_ids"])
			if name == "" || len(ids) == 0 {
				continue
			}
			id := strings.TrimSpace(fmt.Sprint(ids[0]))
			if id == "" || id == "<nil>" {
				continue
			}
			options = append(options, nativeFilterOption{ID: id, Name: name})
		}
	}
	return options
}

func hongguoNewTopicOptions(ctx context.Context, downloader *Downloader) []nativeFilterOption {
	hongguoNewTopicCache.mu.Lock()
	if time.Since(hongguoNewTopicCache.at) < hongguoNewTopicCacheTTL && len(hongguoNewTopicCache.options) > 0 {
		cached := append([]nativeFilterOption(nil), hongguoNewTopicCache.options...)
		hongguoNewTopicCache.mu.Unlock()
		return cached
	}
	hongguoNewTopicCache.mu.Unlock()

	options := []nativeFilterOption{{ID: "", Name: "全部"}}
	if body, err := downloader.fetchProviderText(ctx, hongguoBaseURL+"/category/real-drama", hongguoBaseURL+"/"); err == nil {
		page := routerLoaderMap(parseRouterData(body), "category_page", "category_$")
		options = append(options, hongguoNewTopicOptionsFromPage(page)...)
	}
	if len(options) > 1 {
		hongguoNewTopicCache.mu.Lock()
		hongguoNewTopicCache.options = append([]nativeFilterOption(nil), options...)
		hongguoNewTopicCache.at = time.Now()
		hongguoNewTopicCache.mu.Unlock()
	}
	return options
}
