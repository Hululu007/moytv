package core

// 番茄详情：复用红果(新)的 SSR 详情（已活验：113 集全集），只改挂番茄槽。
// 番茄流里的行与红果(新)是同一批剧（同一 series_id），详情链路无需另写。

import (
	"context"
	"errors"
)

// fetchFanqieDetail：番茄槽详情入口。sourceID 为数字 series_id；
// 详情与分集表取自红果(新) SSR 详情，身份字段改挂番茄槽。
func (downloader *Downloader) fetchFanqieDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}, nil, errors.New("番茄剧集 ID 无效")
	}
	drama, chapters, err := downloader.fetchHongguoNewDetail(ctx, sourceID)
	if err != nil {
		return Drama{}, nil, err
	}
	drama = fanqieRelabelDrama(drama)
	chapters = fanqieRelabelChapters(chapters, sourceID)
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("番茄详情没有返回可播放的分集")
	}
	return drama, chapters, nil
}

// fetchFanqieChapters：GetHuangguoChapters 形态的适配（标题 + 分集）。
func (downloader *Downloader) fetchFanqieChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	drama, chapters, err := downloader.fetchFanqieDetail(ctx, sourceID)
	if err != nil {
		return "", nil, err
	}
	return drama.DisplayTitle(), chapters, nil
}
