package core

// 番茄取流：与红果(新)相同的三段链——App 模型 → 网页兜底 → 网页取流。
// App 模型链就是红果槽的 resolveHongguoAppMedia（V5 单腿：90 秒总预算、
// 401/403 换设备≤3 次、429/5xx 同设备重签名重试、空回包直接报错），
// 本文件只做番茄槽分发，不重复造轮子。
// 免登入原则：取流链不带任何账号会话（回归测试 TestHongguoMediaIgnoresLoginSession
// 已覆盖），登入状态不影响播放。

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// resolveFanqieMedia：番茄槽取流入口，接线点见 provider_media.go（resolveProviderMedia
// 新分支，必须放在 hongguo-cenc:// 通用分支之前，与红果(新)分支同款位置）。
func (downloader *Downloader) resolveFanqieMedia(ctx context.Context, task Task) (providerMedia, error) {
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, fanqieCENCURLPrefix)
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceFanqie || !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("番茄章节 ID 无效，请重新获取章节")
	}
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
	detail := fmt.Errorf("番茄 App 取流失败：%v；网页兜底取流失败：%v；网页取流失败：%v", publicError(nativeErr), publicError(fallbackErr), publicError(pageErr))
	if errors.Is(fallbackErr, errHongguoWebFallbackUnavailable) || strings.Contains(nativeErr.Error(), "限流") || downloader.hongguoPlayerSuspended() {
		return providerMedia{}, fmt.Errorf("%w；设备或游客会话可能被限流，请稍后重试", detail)
	}
	return providerMedia{}, detail
}
