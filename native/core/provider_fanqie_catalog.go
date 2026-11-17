package core

// 番茄目录：单条排行榜单流，无分类、无筛选组。

import (
	"context"
	"errors"
)

// fetchFanqieCatalogPage：番茄槽目录入口。category 只接受空（全部）；
// page 1 走首屏链路（plan 取种 + change），page > 1 走游标翻页。
// 返回（剧集，有无下一页，筛选组恒 nil，错误）。
func (downloader *Downloader) fetchFanqieCatalogPage(ctx context.Context, category string, page int) ([]Drama, bool, []nativeFilterGroup, error) {
	if page < 1 {
		page = 1
	}
	if !validFanqieCategory(category) {
		return nil, false, nil, errors.New("番茄分类无效")
	}
	items, hasMore, err := downloader.fetchFanqieFeed(ctx, page > 1)
	if err != nil {
		return nil, false, nil, err
	}
	return items, hasMore, nil, nil
}
