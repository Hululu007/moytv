package core

// 红果(新)详情：SSR 详情全集 + 头条单集详情。
//
// 对照 py（hongguo_full_177_5sc7.py）：
//   - detailContent：行 1491-1528（SSR _ROUTER_DATA，vid_list 全集；五档清晰度作五条线路）
//   - _walk：行 1530-1544（全树找 series_name/series_cover/series_intro/episode_cnt/
//     episode_right_text/vid_list，首个非空为准）
//   - _tt_detail：行 1630-1647（头条单集，正片直链）
//
// 核内形态差异（能力不丢）：py 的“五条清晰度线路”在核内由取流的 Variants 承载
// （selectHongguoAppMedia 返回全部档位，播放路由供切换）；详情只出一份分集表，
// 每集的 VideoURL 都是 hongguo-new-cenc://<vid>，取流时现取全部档位。

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// fetchHongguoNewDetail：新槽详情入口，接线点见 LANDING.md（nativeDetail 新 case）。
// sourceID 形态：数字 series_id（红果剧）、tt_<item_id>（头条）、diagN（自检条目，不可播）。
func (downloader *Downloader) fetchHongguoNewDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if strings.HasPrefix(sourceID, "tt_") {
		return downloader.fetchHongguoNewToutiaoDetail(ctx, strings.TrimPrefix(sourceID, "tt_"))
	}
	if strings.HasPrefix(sourceID, "diag") {
		return Drama{}, nil, errors.New("自检条目不可播放")
	}
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}, nil, errors.New("红果(新)剧集 ID 无效")
	}
	return downloader.fetchHongguoNewWebDetail(ctx, sourceID)
}

// fetchHongguoNewChapters：GetHuangguoChapters 形态的适配（标题 + 分集），供源健康检查等调用。
func (downloader *Downloader) fetchHongguoNewChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	drama, chapters, err := downloader.fetchHongguoNewDetail(ctx, sourceID)
	if err != nil {
		return "", nil, err
	}
	return drama.DisplayTitle(), chapters, nil
}

// fetchHongguoNewWebDetail：py detailContent 的 SSR 路。先取 seriesDetail，
// 取不到时按 py _walk 全树找字段；vid_list 嵌套一层列表时取内层（py 同款处理）。
func (downloader *Downloader) fetchHongguoNewWebDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	body, err := downloader.fetchProviderText(ctx, hongguoBaseURL+"/detail?series_id="+sourceID, hongguoBaseURL+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	data := parseRouterData(body)
	page := routerLoaderMap(data, "detail_page", "detail_")
	detail, _ := page["seriesDetail"].(map[string]any)
	box := map[string]any{}
	if len(detail) > 0 {
		box = detail
	} else {
		box = hongguoNewWalkDetail(data)
	}
	name := firstNonEmpty(mapString(box, "series_name", "series_title", "name"), "红果短剧 "+sourceID)
	cover := hongguoNewUnescapeURL(mapString(box, "series_cover", "cover"))
	intro := mapString(box, "series_intro")
	remark := mapString(box, "episode_right_text")
	vids := hongguoNewVidList(box["vid_list"])
	count := firstNonEmpty(mapString(box, "episode_cnt"), strconv.Itoa(len(vids)))
	if remark == "" && count != "" {
		remark = "全" + count + "集"
	}
	if len(vids) == 0 {
		return Drama{}, nil, errors.New("红果(新)详情没有返回剧集 ID")
	}
	chapters := make([]Chapter, 0, len(vids))
	for i, vid := range vids {
		idx := i + 1
		chapters = append(chapters, Chapter{
			ID:             providerChapterID(sourceHongguoNew, sourceID, vid),
			Source:         sourceHongguoNew,
			Title:          fmt.Sprintf("第%d集", idx),
			VideoURL:       hongguoNewCENCURLPrefix + vid,
			CurrentEpisode: rawEpisode(idx),
		})
	}
	drama := Drama{
		ID: providerDramaID(sourceHongguoNew, sourceID), Source: sourceHongguoNew, SourceID: sourceID,
		Title: name, Name: name, Desc: intro, Intro: intro, Cover: cover, CoverURL: cover,
		CategoryName: "短剧", ChannelName: hongguoNewChannelName, Remark: remark,
		TotalEpisode: count, EpisodeCount: count,
	}
	return drama, chapters, nil
}

// hongguoNewWalkDetail：py _walk 的 Go 版。全树深度优先找 6 个详情字段，首个非空值胜出。
func hongguoNewWalkDetail(data map[string]any) map[string]any {
	box := map[string]any{}
	keys := map[string]bool{
		"series_name": true, "series_cover": true, "series_intro": true,
		"episode_cnt": true, "episode_right_text": true, "vid_list": true,
	}
	var walk func(value any)
	walk = func(value any) {
		switch item := value.(type) {
		case map[string]any:
			for key, child := range item {
				if keys[key] {
					if _, done := box[key]; !done && !hongguoNewEmptyValue(child) {
						box[key] = child
					}
				}
				walk(child)
			}
		case []any:
			for _, child := range item {
				walk(child)
			}
		}
	}
	walk(data)
	return box
}

func hongguoNewEmptyValue(value any) bool {
	switch item := value.(type) {
	case nil:
		return true
	case string:
		return item == ""
	case []any:
		return len(item) == 0
	case map[string]any:
		return len(item) == 0
	default:
		return false
	}
}

// hongguoNewVidList：vid_list 归一。元素可能是数字/字符串；首元素是列表时取内层；只留纯数字 id。
func hongguoNewVidList(value any) []string {
	rows := anyList(value)
	if len(rows) > 0 {
		if inner := anyList(rows[0]); len(inner) > 0 {
			rows = inner
		}
	}
	var out []string
	for _, row := range rows {
		vid := strings.TrimSpace(fmt.Sprint(row))
		if hongguoNumericID.MatchString(vid) {
			out = append(out, vid)
		}
	}
	return out
}

// hongguoNewUnescapeURL：py _pic。SSR 里的 \/ 与 \u002F 还原成 /。
func hongguoNewUnescapeURL(raw string) string {
	raw = strings.ReplaceAll(raw, `\/`, "/")
	raw = strings.ReplaceAll(raw, `\u002F`, "/")
	return raw
}
