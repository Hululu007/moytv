package seku

import "testing"

// SupJav 免代兜底接线回归（离线确定性部分）：
//   - CF 新版验证页签名 "Performing security verification" 须能被公共
//     挑战识别命中（jinaFallback 的触发条件之一）；
//   - supjavJinaRetry 对不带挑战签名的正文必须拒绝触发兜底（不浪费
//     代抓、不把正常页误送重抓）。
//
// 活体口径（2026-10-24 本机出口实测）：直连 supjav.com 回 403，
// r.jina.ai 代抓回的也是挑战页、被兜底验收逻辑正确拒绝——本地出口
// 双路皆挡，兜底的实际放行待用户侧网络验，本测试不冒充活体已通。
func TestSupjavFallbackWiring(t *testing.T) {
	challenge := "<html><head><title>Performing security verification</title></head>" +
		"<body>Attention Required! Cloudflare</body></html>"
	if !isChallengePage(challenge) {
		t.Fatal("isChallengePage missed the security-verification interstitial")
	}
	if !supjavIsCFBlock(challenge) {
		t.Fatal("supjavIsCFBlock missed its own block page")
	}
	if got := supjavJinaRetry("https://supjav.com/", "", "<html><body>normal page</body></html>"); got != "" {
		t.Fatalf("jina retry must decline non-challenge bodies, got %q", got)
	}
}

// v55 起口径反转：iOS 包源表明文列着 supjav，sites_v54_ios8.go 用仓库里
// 现成的成套实现把它注册了回来。这里锁定「必须注册且能按对外 id 路由回槽」，
// 免得以后又被人当成废弃槽删掉，站表里少一格。
func TestSupjavSlotRegistered(t *testing.T) {
	if implForSlot("supjav") == nil {
		t.Fatal("slot supjav must be registered (v55 iOS source set)")
	}
	if impl := implForSlot("supjav"); impl.Key == "" {
		t.Fatal("slot supjav registered without a provider key")
	}
}
