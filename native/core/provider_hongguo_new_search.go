package core

// 红果(新)搜索：官网 JSON 搜索接口。
//
// 对照 py（hongguo_full_177_5sc7.py）：
//   - searchContent：行 1473-1490（GET /api/search/result?query=&page=，searchList）
//   - _item_search：行 547-560（video_data 优先、keyword 兜底、去重）
// 新槽只用这一条搜索腿（与 py 一致），不复用旧槽的联想 + SSR 页两条腿。

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
)

// hongguoNewSearchAPIBaseURL：搜索 JSON 接口基址，默认官网；测试可替换为本地服务。
var hongguoNewSearchAPIBaseURL = hongguoBaseURL

// fetchHongguoNewSearchAPI：新槽搜索入口，接线点见 LANDING.md（nativeSearchSource 新 case）。
func (downloader *Downloader) fetchHongguoNewSearchAPI(ctx context.Context, keyword string, page int) (hongguoSearchEntry, error) {
	if page < 1 {
		page = 1
	}
	query := url.Values{"query": {keyword}, "page": {strconv.Itoa(page)}}
	address := hongguoNewSearchAPIBaseURL + "/api/search/result?" + query.Encode()
	body, err := downloader.fetchProviderText(ctx, address, hongguoBaseURL+"/")
	if err != nil {
		return hongguoSearchEntry{}, err
	}
	return parseHongguoNewSearchAPIResponse(body)
}

// parseHongguoNewSearchAPIResponse：解析 /api/search/result 的 JSON，映射后改挂新槽。
// py 不读 totalCount，核内补上（接口返回时用，没有则用条数）；行里无可识别剧集时报错，
// 与旧槽 SSR 搜索页的语义一致。
func parseHongguoNewSearchAPIResponse(body string) (hongguoSearchEntry, error) {
	var decoded map[string]any
	decoder := json.NewDecoder(strings.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return hongguoSearchEntry{}, errors.New("红果(新)搜索接口未返回有效数据")
	}
	rows := anyList(decoded["searchList"])
	entry := hongguoSearchEntry{Dramas: make([]Drama, 0, len(rows))}
	seen := make(map[string]bool, len(rows))
	for _, row := range rows {
		drama := hongguoNewRelabelDrama(hongguoDramaFromAny(row, "短剧"))
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		entry.Dramas = append(entry.Dramas, drama)
	}
	if len(rows) > 0 && len(entry.Dramas) == 0 {
		return hongguoSearchEntry{}, errors.New("红果(新)搜索结果中没有可识别的剧集")
	}
	entry.Total, _ = strconv.Atoi(mapString(decoded, "totalCount"))
	entry.Limited = entry.Total > len(entry.Dramas)
	if entry.Total < len(entry.Dramas) {
		entry.Total = len(entry.Dramas)
	}
	return entry, nil
}
