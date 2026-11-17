package core

// 番茄搜索：复用红果(新)的 JSON 搜索接口（已活验），结果改挂番茄槽。
// 番茄线本身没有独立搜索端点（修仙版亦然，搜索走通用路由），不另写。

import (
	"context"
)

// fetchFanqieSearch：番茄槽搜索入口。返回红果(新)搜索结果改挂后的条目。
func (downloader *Downloader) fetchFanqieSearch(ctx context.Context, keyword string, page int) (hongguoSearchEntry, error) {
	entry, err := downloader.fetchHongguoNewSearchAPI(ctx, keyword, page)
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	entry.Dramas = fanqieRelabelDramas(entry.Dramas)
	return entry, nil
}
