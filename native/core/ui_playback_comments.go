package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

type hongguoCommentItem struct {
	ID       string `json:"id"`
	Text     string `json:"text"`
	UserName string `json:"userName"`
	Avatar   string `json:"avatar"`
	TimeSec  int64  `json:"timeSec"`
}

type hongguoCommentPage struct {
	Items           []hongguoCommentItem `json:"items"`
	Cursor          string               `json:"cursor"`
	HasMore         bool                 `json:"hasMore"`
	Total           int64                `json:"total"`
	CollectorsCount int64                `json:"collectorsCount"`
	Score           float64              `json:"score"`
	ScoreCount      int64                `json:"scoreCount"`
}

func hongguoAnyMap(value any) map[string]any {
	if m, ok := value.(map[string]any); ok {
		return m
	}
	return nil
}

func hongguoAnyString(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	return ""
}

func hongguoAnyInt(value any) int64 {
	switch v := value.(type) {
	case float64:
		return int64(v)
	case int64:
		return v
	case int:
		return int64(v)
	case json.Number:
		if n, err := v.Int64(); err == nil {
			return n
		}
		if f, err := v.Float64(); err == nil {
			return int64(f)
		}
		return 0
	case string:
		var n int64
		fmt.Sscanf(v, "%d", &n)
		return n
	}
	return 0
}

func hongguoAnyFloat(value any) float64 {
	switch v := value.(type) {
	case float64:
		return v
	case int64:
		return float64(v)
	case int:
		return float64(v)
	case json.Number:
		if f, err := v.Float64(); err == nil {
			return f
		}
		return 0
	}
	return 0
}

func parseHongguoComments(result map[string]any) hongguoCommentPage {
	page := hongguoCommentPage{Items: []hongguoCommentItem{}}
	data := hongguoAnyMap(result["data"])
	if data == nil {
		return page
	}
	if rows, ok := data["data_list"].([]any); ok {
		for _, r := range rows {
			comment := hongguoAnyMap(hongguoAnyMap(r)["comment"])
			if comment == nil {
				continue
			}
			common := hongguoAnyMap(comment["common"])
			if common == nil {
				continue
			}
			content := hongguoAnyMap(common["content"])
			userInfo := hongguoAnyMap(common["user_info"])
			baseInfo := hongguoAnyMap(userInfo["base_info"])
			text := hongguoAnyString(content["text"])
			if text == "" {
				continue
			}
			page.Items = append(page.Items, hongguoCommentItem{
				ID:       hongguoAnyString(comment["comment_id"]),
				Text:     text,
				UserName: hongguoAnyString(baseInfo["user_name"]),
				Avatar:   hongguoAnyString(baseInfo["user_avatar"]),
				TimeSec:  hongguoAnyInt(common["create_timestamp"]),
			})
		}
	}
	info := hongguoAnyMap(data["common_list_info"])
	if info != nil {
		page.Cursor = hongguoAnyString(info["cursor"])
		if v, ok := info["has_more"].(bool); ok {
			page.HasMore = v
		}
		page.Total = hongguoAnyInt(info["total"])
	}
	extra := hongguoAnyMap(data["extra"])
	if extra != nil {
		page.CollectorsCount = hongguoAnyInt(extra["collectors_count"])
		page.Score = hongguoAnyFloat(extra["credibility_score"])
		page.ScoreCount = hongguoAnyInt(extra["credibility_score_count"])
	}
	return page
}

func (d *Downloader) hongguoComments(ctx context.Context, seriesID, cursor string) (hongguoCommentPage, error) {
	if !hongguoNumericID.MatchString(seriesID) {
		return hongguoCommentPage{}, errors.New("评论请求参数无效")
	}
	if err := ctx.Err(); err != nil {
		return hongguoCommentPage{}, err
	}
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	ctx = context.WithValue(ctx, hongguoCommentKey{}, true)
	body := map[string]any{
		"comment_source": 1, "server_channel": 34, "group_id": seriesID, "group_type": 1,
		"comment_type": 2, "sort": 1, "count": 20, "cursor": cursor, "aid": 8662, "compliance_status": 0,
		"business_param": map[string]any{"book_id": seriesID, "need_count": true},
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodPost, "/novel/commentapi/comment/list/"+seriesID+"/v1/", nil, body)
	if err != nil {
		return hongguoCommentPage{}, err
	}
	return parseHongguoComments(result), nil
}

func (engine *nativeEngine) nativeComments(ctx context.Context, input nativeInput) (hongguoCommentPage, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[input.PlaybackSession]
	engine.mu.Unlock()
	if !exists || time.Since(choice.created) > 12*time.Hour {
		return hongguoCommentPage{}, errors.New("播放会话已过期")
	}
	if choice.danmakuSeries == "" {
		return hongguoCommentPage{}, errors.New("本集暂不支持评论")
	}
	page, err := engine.downloader.hongguoComments(ctx, choice.danmakuSeries, input.Cursor)
	if err != nil {
		return hongguoCommentPage{}, err
	}
	engine.mu.Lock()
	_, exists = engine.playbacks[input.PlaybackSession]
	engine.mu.Unlock()
	if !exists {
		return hongguoCommentPage{}, errors.New("播放会话已过期")
	}
	return page, ctx.Err()
}
