package core

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

func m3u8HeaderLines(duration int) []string {
	return []string{"#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:" + strconv.Itoa(duration)}
}

func TestAdFilterRemovesForeignSegments(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	builder = append(builder, "#EXT-X-MEDIA-SEQUENCE:0")
	for index := 0; index < 8; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	// 插播广告：两个来自另一目录的分片
	builder = append(builder, "#EXT-X-DISCONTINUITY", "#EXTINF:5.0,", "https://cdn.main.com/ads/1.ts")
	builder = append(builder, "#EXTINF:5.0,", "https://cdn.main.com/ads/2.ts")
	for index := 8; index < 12; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/vod/index.m3u8")
	if removed != 2 {
		t.Fatalf("应移除 2 个广告分片，实际 %d:\n%s", removed, cleaned)
	}
	if !strings.Contains(cleaned, "/vod/0.ts") || !strings.Contains(cleaned, "/vod/11.ts") {
		t.Fatalf("主分片不应被删:\n%s", cleaned)
	}
	if strings.Contains(cleaned, "/ads/") {
		t.Fatalf("广告分片未被移除:\n%s", cleaned)
	}
	if strings.Contains(cleaned, "#EXT-X-DISCONTINUITY") {
		t.Fatalf("广告段前置标签应一并移除:\n%s", cleaned)
	}
	if !strings.Contains(cleaned, "#EXT-X-ENDLIST") {
		t.Fatalf("尾部标签应保留:\n%s", cleaned)
	}
}

func TestAdFilterRelativeSegments(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 5; index++ {
		builder = append(builder, "#EXTINF:10.0,", "seg/"+strconv.Itoa(index)+".ts")
	}
	original := strings.Join(builder, "\n")
	// 相对地址与主清单同源，不该被删
	cleaned, removed := nativeFilterAdSegments(original, "https://host.example/vod/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("全同源不应改动: removed=%d\n%s", removed, cleaned)
	}
}

func TestAdFilterMasterUntouched(t *testing.T) {
	master := strings.Join([]string{
		"#EXTM3U",
		"#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720",
		"720p.m3u8",
		"#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080",
		"1080p.m3u8",
	}, "\n")
	cleaned, removed := nativeFilterAdSegments(master, "https://host.example/vod/index.m3u8")
	if removed != 0 || cleaned != master {
		t.Fatalf("master 清单应原样放行: removed=%d\n%s", removed, cleaned)
	}
}

func TestAdFilterLowDominanceSkip(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	// 三种来源各 3 片，主来源占比 3/9=33% < 40%，应放弃清洗
	for index := 0; index < 3; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://a.example/x/"+strconv.Itoa(index)+".ts")
	}
	for index := 0; index < 3; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://b.example/x/"+strconv.Itoa(index)+".ts")
	}
	for index := 0; index < 3; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://c.example/x/"+strconv.Itoa(index)+".ts")
	}
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://a.example/x/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("主来源占比 <40%% 时应放弃清洗: removed=%d", removed)
	}
}

func TestAdFilterKeyPropagation(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	builder = append(builder, `#EXT-X-KEY:METHOD=AES-128,URI="https://k.example/main.key"`)
	for index := 0; index < 6; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	// 广告分片自带另一个 KEY，应连同前置标签一起删
	builder = append(builder, "#EXT-X-DISCONTINUITY")
	builder = append(builder, `#EXT-X-KEY:METHOD=AES-128,URI="https://k.example/ad.key"`)
	builder = append(builder, "#EXTINF:5.0,", "https://cdn.main.com/ads/1.ts")
	for index := 6; index < 10; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	cleaned, removed := nativeFilterAdSegments(strings.Join(builder, "\n"), "https://cdn.main.com/vod/index.m3u8")
	if removed != 1 {
		t.Fatalf("应移除 1 个广告分片，实际 %d:\n%s", removed, cleaned)
	}
	if strings.Contains(cleaned, "ad.key") {
		t.Fatalf("广告 KEY 应一并移除:\n%s", cleaned)
	}
	if !strings.Contains(cleaned, "main.key") {
		t.Fatalf("主 KEY 应保留:\n%s", cleaned)
	}
}

func TestAdFilterNativeAdCleanedRespectsSwitch(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 6; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXTINF:5.0,", "https://cdn.main.com/ads/1.ts")
	original := strings.Join(builder, "\n")
	// 开关关闭：原样返回
	if got := nativeAdCleaned(&nativeStreamSession{adBlock: false}, original, "https://cdn.main.com/vod/index.m3u8"); got != original {
		t.Fatalf("关闭去广告时不应改写:\n%s", got)
	}
	// 开关开启：广告被清洗
	if got := nativeAdCleaned(&nativeStreamSession{adBlock: true}, original, "https://cdn.main.com/vod/index.m3u8"); strings.Contains(got, "/ads/") {
		t.Fatalf("开启去广告时应移除广告:\n%s", got)
	}
	// 空会话安全
	if got := nativeAdCleaned(nil, original, "https://cdn.main.com/vod/index.m3u8"); got != original {
		t.Fatalf("空会话应原样返回:\n%s", got)
	}
}

// TestAdFilterPreRollKeepsHeader 复现「贴片广告」（第一个分片就是广告）场景：
// 广告前置的注释里混着整个清单的头部标签（#EXTM3U/#EXT-X-VERSION/#EXT-X-TARGETDURATION），
// 只应删除广告自己的分片级标签（DISCONTINUITY/EXTINF），头部标签必须保留，
// 否则删掉必需要素会让清单整体失效、正片也无法播放。
func TestAdFilterPreRollKeepsHeader(t *testing.T) {
	var builder []string
	builder = append(builder, "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10")
	builder = append(builder, "#EXT-X-DISCONTINUITY", "#EXTINF:5.0,", "https://cdn.main.com/ads/preroll.ts")
	for index := 0; index < 8; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/vod/index.m3u8")
	if removed != 1 {
		t.Fatalf("应移除 1 个贴片分片，实际 %d:\n%s", removed, cleaned)
	}
	// 广告分片与其 EXTINF/DISCONTINUITY 被删
	if strings.Contains(cleaned, "/ads/") || strings.Contains(cleaned, "#EXT-X-DISCONTINUITY") {
		t.Fatalf("贴片分片及其前置标签应被移除:\n%s", cleaned)
	}
	// 头部标签必须保留（否则清单失效）
	for _, required := range []string{"#EXTM3U", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION", "#EXT-X-ENDLIST"} {
		if !strings.Contains(cleaned, required) {
			t.Fatalf("头部标签 %s 不应被删:\n%s", required, cleaned)
		}
	}
	if !strings.Contains(cleaned, "/vod/0.ts") || !strings.Contains(cleaned, "/vod/7.ts") {
		t.Fatalf("主分片应保留:\n%s", cleaned)
	}
}

// TestAdFilterRemovalRatioCap 保守总闸一：待移除分片占全清单 40%（>35%）
// 时整单放弃清洗。构造：正片 6 片（主指纹占比 60%，已过 40% 门槛）、
// 异源 4 片；没有总闸时会被删掉 4 片，总闸应拦下。
func TestAdFilterRemovalRatioCap(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 6; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	for index := 0; index < 4; index++ {
		builder = append(builder, "#EXTINF:5.0,", "https://ads.other.com/spot/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/vod/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("移除占比 >35%% 应整单放弃清洗: removed=%d\n%s", removed, cleaned)
	}
}

// TestAdFilterDurationCap 保守总闸二：待移除总时长 120 秒（>90 秒）时
// 整单放弃清洗。构造：正片 20 片 ×10 秒、异源 3 片 ×40 秒，
// 移除占比仅 3/23≈13%，只有时长总闸能拦下。
func TestAdFilterDurationCap(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 20; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	for index := 0; index < 3; index++ {
		builder = append(builder, "#EXTINF:40.0,", "https://ads.other.com/long/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/vod/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("移除总时长 >90 秒应整单放弃清洗: removed=%d\n%s", removed, cleaned)
	}
}

// TestAdFilterTwoCDNLegitNotFiltered 正片分片本身在两个 CDN 目录间
// 均分（5/5）时，主指纹占比 50% 虽过门槛，但待移除占比 50% 触发
// 总闸——正片一片都不能少。这是总闸要防的典型误杀形态。
func TestAdFilterTwoCDNLegitNotFiltered(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 5; index++ {
		builder = append(builder, "#EXTINF:10.0,", "https://cdn1.main.com/vod/"+strconv.Itoa(index)+".ts")
		builder = append(builder, "#EXTINF:10.0,", "https://cdn2.main.com/vod/"+strconv.Itoa(index)+".ts")
	}
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn1.main.com/vod/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("双 CDN 均分正片不应被清洗: removed=%d\n%s", removed, cleaned)
	}
}

// TestAdFilterByterangeUntouched #EXT-X-BYTERANGE 清单删分片会错位
// 字节偏移，整单放行（哪怕清单里有明显的异源分片）。
func TestAdFilterByterangeUntouched(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(10)...)
	for index := 0; index < 6; index++ {
		builder = append(builder, "#EXTINF:10.0,", "#EXT-X-BYTERANGE:1000@"+strconv.Itoa(index*1000), "https://cdn.main.com/vod/full.mp4")
	}
	builder = append(builder, "#EXTINF:5.0,", "https://ads.other.com/spot/1.ts")
	builder = append(builder, "#EXT-X-ENDLIST")
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/vod/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("BYTERANGE 清单应整单放行: removed=%d\n%s", removed, cleaned)
	}
}

// TestAdFilterLowLatencyUntouched 低延迟 LL-HLS 清单带 #EXT-X-PART /
// #EXT-X-PRELOAD-HINT，与播放器状态强绑定，整单放行。
func TestAdFilterLowLatencyUntouched(t *testing.T) {
	var builder []string
	builder = append(builder, m3u8HeaderLines(4)...)
	builder = append(builder, `#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0`)
	builder = append(builder, `#EXT-X-PART-INF:PART-TARGET=1.0`)
	for index := 0; index < 6; index++ {
		builder = append(builder, "#EXTINF:4.0,", "https://cdn.main.com/live/"+strconv.Itoa(index)+".ts")
		builder = append(builder, `#EXT-X-PART:DURATION=1.0,URI="https://cdn.main.com/live/p`+strconv.Itoa(index)+`.ts"`)
	}
	builder = append(builder, "#EXTINF:5.0,", "https://ads.other.com/spot/1.ts")
	builder = append(builder, `#EXT-X-PRELOAD-HINT:TYPE=PART,URI="https://cdn.main.com/live/p6.ts"`)
	original := strings.Join(builder, "\n")
	cleaned, removed := nativeFilterAdSegments(original, "https://cdn.main.com/live/index.m3u8")
	if removed != 0 || cleaned != original {
		t.Fatalf("LL-HLS 清单应整单放行: removed=%d\n%s", removed, cleaned)
	}
}

// 真实站点清单验证（2026-11-25 抓取）：非凡资源 ffm3u8 源
// 《爱·回家之三代同糖粤语》第 01 集的 mixed.m3u8，340 个分片，
// 全部同目录相对地址，中间有 #EXT-X-DISCONTINUITY 拼接块
// （同源混编，来源指纹无法区分）。过滤器对这种真实清单必须
// 一片不删——宁可漏掉同源广告，也绝不误杀正片。
const realPlaylistBaseURL = "https://vod.ffzy-bofang.com/20260811/1859_537de305/3000k/hls/mixed.m3u8"

func loadRealPlaylist(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("testdata/ffzy_mixed_real.m3u8")
	if err != nil {
		t.Fatalf("读真实清单 fixture 失败: %v", err)
	}
	text := string(data)
	if count := strings.Count(text, "#EXTINF"); count != 340 {
		t.Fatalf("真实清单 fixture 应有 340 个分片，实际 %d", count)
	}
	return text
}

func TestAdFilterRealPlaylistNoFalsePositive(t *testing.T) {
	original := loadRealPlaylist(t)
	cleaned, removed := nativeFilterAdSegments(original, realPlaylistBaseURL)
	if removed != 0 || cleaned != original {
		t.Fatalf("真实清单不应被改动: removed=%d", removed)
	}
}

func TestAdFilterRealPlaylistForeignAdsRemoved(t *testing.T) {
	original := loadRealPlaylist(t)
	// 在第一个正片分片后注入两个异源广告分片（真实清单 + 合成广告）。
	marker := ".ts\n"
	index := strings.Index(original, marker)
	if index < 0 {
		t.Fatal("真实清单里找不到分片行")
	}
	injected := original[:index+len(marker)] +
		"#EXT-X-DISCONTINUITY\n#EXTINF:5.0,\nhttps://ads.other.com/spot/1.ts\n#EXTINF:5.0,\nhttps://ads.other.com/spot/2.ts\n" +
		original[index+len(marker):]
	cleaned, removed := nativeFilterAdSegments(injected, realPlaylistBaseURL)
	if removed != 2 {
		t.Fatalf("应只移除 2 个注入广告分片，实际 %d", removed)
	}
	if strings.Contains(cleaned, "ads.other.com") {
		t.Fatal("注入广告未被移除")
	}
	// 正片 340 片一片不能少。
	if count := strings.Count(cleaned, "#EXTINF"); count != 340 {
		t.Fatalf("清洗后正片应有 340 片，实际 %d", count)
	}
	for _, line := range strings.Split(original, "\n") {
		if strings.HasSuffix(line, ".ts") && !strings.Contains(cleaned, line) {
			t.Fatalf("正片分片被误删: %s", line)
		}
	}
}
