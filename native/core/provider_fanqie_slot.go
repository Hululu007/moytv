package core

// 番茄槽位：番茄短剧发现流路（plan 取种 → cell/change 合并）的 Go 核实现，
// 与树里已有的红果槽（sourceHongguo）与红果(新)槽（sourceHongguoNew）并存，
// 不替换、不改旧槽。
//
// 移植自修仙版旁支的 Rust 实现（只读参考，未改修仙版树）：
//   - 路由 fanqie-plan / fanqie-feed：huoyi_juhe rust/src/endpoints/router.rs
//   - plan 取种 + cell/change 合并：rust/src/endpoints/home.rs（fanqie_plan_params、
//     fanqie_video_plan、fanqie_video_feed），2026-11-08 活体实测能通。
//   - 取流三腿（video_tab / multi_video_model / video_model）与红果槽同一批接口，
//     本槽不另写，直接复用 resolveHongguoAppMedia（含刚落树的恢复环：90 秒总预算、
//     三腿同乘一轮换环、轮换退避）；详情复用红果(新)的 SSR 详情；搜索复用红果(新)
//     的 JSON 搜索接口。本槽新增的只是发现流路与分发外壳。
//
// 身份口径（2026-11-17 活站探针实证）：plan/v 与 cell/change/v 用现有凤凰身份
// （aid 8662）经 hongguoAppRequest 直接通 code 0，无需龙身份（aid 1967）与签名改动；
// 签名一字不动。探针证据见 ~/workspace/fanqie_probe_20261117/probe1.log。

import (
	"strings"
)

// sourceFanqie：番茄槽位 id。Dart 侧 SourceSite id 同名（待接线，见终局回报）。
const sourceFanqie = "fanqie"

// fanqieChannelName：番茄槽剧集的频道显示名。
const fanqieChannelName = "番茄"

// fanqieCENCURLPrefix：番茄槽分集的 VideoURL 前缀，与旧槽的 hongguo-cenc:// 与
// 新槽的 hongguo-new-cenc:// 区分，避免分发误认。取流时只取前缀后的 vid。
const fanqieCENCURLPrefix = "fanqie-cenc://"

// fanqieFeedKey：番茄流在 hongguoCatalogState.Feeds 里的游标键。游标复用旧槽
// 的 hongguoCatalogCursor：SessionID 存 change 会话，LastID 存 cell_id_str，
// Offset 存 next_offset。restoreHongguoCatalog 只认旧槽分类键，番茄游标在恢复时
// 被丢弃——丢了只会重取 plan 种子，不影响正确性。
const fanqieFeedKey = "fanqie"

// validFanqieCategory：番茄只有一条排行榜单流，空分类（全部）放行，其余拒绝。
func validFanqieCategory(category string) bool {
	return category == ""
}

// fanqieRelabelDrama：把其它红果系映射出的剧集改挂到番茄槽。
// 只改身份三字段（ID/Source/频道名），标题/封面/简介/标签等原样。
func fanqieRelabelDrama(drama Drama) Drama {
	if drama.SourceID == "" {
		return drama
	}
	drama.ID = providerDramaID(sourceFanqie, drama.SourceID)
	drama.Source = sourceFanqie
	drama.ChannelName = fanqieChannelName
	return drama
}

// fanqieRelabelDramas：批量改挂，跳过无 SourceID 的行。
func fanqieRelabelDramas(dramas []Drama) []Drama {
	out := make([]Drama, 0, len(dramas))
	for _, drama := range dramas {
		if drama.SourceID == "" {
			continue
		}
		out = append(out, fanqieRelabelDrama(drama))
	}
	return out
}

// fanqieDedupDramas：按 ID 去重，保持首次出现顺序。
func fanqieDedupDramas(dramas []Drama) []Drama {
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

// fanqieRelabelChapters：把红果(新)详情出的分集表改挂到番茄槽：章节 ID 与
// VideoURL 前缀换成番茄槽，标题与集序原样。
func fanqieRelabelChapters(chapters []Chapter, sourceID string) []Chapter {
	out := make([]Chapter, 0, len(chapters))
	for _, chapter := range chapters {
		vid := strings.TrimPrefix(chapter.VideoURL, hongguoNewCENCURLPrefix)
		vid = strings.TrimPrefix(vid, "hongguo-cenc://")
		if !hongguoNumericID.MatchString(vid) {
			continue
		}
		chapter.ID = providerChapterID(sourceFanqie, sourceID, vid)
		chapter.Source = sourceFanqie
		chapter.VideoURL = fanqieCENCURLPrefix + vid
		out = append(out, chapter)
	}
	return out
}
