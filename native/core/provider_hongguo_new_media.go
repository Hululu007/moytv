package core

// 红果(新)取流：App 模型链 + 网页兜底 + 头条直链。
//
// 对照 py（hongguo_full_177_5sc7.py）：
//   - _play_url_of：行 1578-1592（取模型 → 解链 → 按清晰度偏好选档）
//   - playerContent：行 1649-1714（头条直链 / 下载解密播）
// 核内形态差异（能力不丢）：py 的“下载整文件 + 本地 CENC 解密 + file:// 缓存播”
// 由核内 CENC 中继流式解密替代（app_cenc_stream.go），不下载整文件；
// 五档清晰度由 resolveHongguoAppMedia 返回的 Variants 全体承载，播放路由供切换。
// 取流本体（签名/模型/key_seed/spade）全部复用旧槽同款函数，本文件只做新槽分发。

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// resolveHongguoNewMedia：新槽取流入口，接线点见 LANDING.md（resolveProviderMedia 新分支，
// 必须放在 hongguo-cenc:// 通用分支之前）。
func (downloader *Downloader) resolveHongguoNewMedia(ctx context.Context, task Task) (providerMedia, error) {
	// 头条单集：章节 VideoURL 已是直链（详情现取现放），直接放行并带头条 Referer。
	if isProviderHTTPMediaURL(task.Chapter.VideoURL) {
		return providerMedia{
			URL:     task.Chapter.VideoURL,
			Referer: firstNonEmpty(task.Chapter.Referer, "https://www.toutiao.com/"),
		}, nil
	}
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, hongguoNewCENCURLPrefix)
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceHongguoNew || !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("红果(新)章节 ID 无效，请重新获取章节")
	}
	// 与旧槽 resolveHongguoMedia 相同的三段链：App 模型 → 网页兜底 → 网页取流。
	// 不做跨集预取（py 也没有）；V5 单腿的设备重试与暂态重试都在 App 模型函数内部处理。
	media, nativeErr := downloader.resolveHongguoAppMedia(ctx, videoID)
	if nativeErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, fallbackErr := downloader.resolveHongguoWebFallback(ctx, seriesID, videoID)
	if fallbackErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, pageErr := downloader.resolveHongguoWebMedia(ctx, seriesID, videoID)
	if pageErr == nil {
		return media, nil
	}
	detail := fmt.Errorf("红果(新) App 取流失败：%v；网页兜底取流失败：%v；网页取流失败：%v", publicError(nativeErr), publicError(fallbackErr), publicError(pageErr))
	if errors.Is(fallbackErr, errHongguoWebFallbackUnavailable) || strings.Contains(nativeErr.Error(), "限流") || downloader.hongguoPlayerSuspended() {
		return providerMedia{}, fmt.Errorf("%w；设备或游客会话可能被限流，请稍后重试", detail)
	}
	return providerMedia{}, detail
}
