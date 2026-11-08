package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseHongguoComments(t *testing.T) {
	raw := `{"data":{"data_list":[{"comment":{"comment_id":"1","common":{"content":{"text":"好看"},"create_timestamp":1793387830,"user_info":{"base_info":{"user_name":"阿甲","user_avatar":"https://example.com/a.jpg"}}}}},{"comment":{"comment_id":"2","common":{"content":{"text":""},"create_timestamp":1,"user_info":{"base_info":{"user_name":"空"}}}}}],"common_list_info":{"cursor":"{\"offset\":20}","has_more":true,"total":4664},"extra":{"collectors_count":1873638,"credibility_score":9.5,"credibility_score_count":19655}}}`
	var result map[string]any
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	page := parseHongguoComments(result)
	if len(page.Items) != 1 {
		t.Fatalf("items = %d, want 1", len(page.Items))
	}
	item := page.Items[0]
	if item.ID != "1" || item.Text != "好看" || item.UserName != "阿甲" || item.Avatar != "https://example.com/a.jpg" || item.TimeSec != 1793387830 {
		t.Fatalf("item = %+v", item)
	}
	if page.Cursor != `{"offset":20}` || !page.HasMore || page.Total != 4664 {
		t.Fatalf("page meta = %+v", page)
	}
	if page.CollectorsCount != 1873638 || page.Score != 9.5 || page.ScoreCount != 19655 {
		t.Fatalf("extra = %+v", page)
	}
}

func TestParseHongguoCommentsWithUseNumber(t *testing.T) {
	raw := `{"data":{"data_list":[{"comment":{"comment_id":"1","common":{"content":{"text":"好看"},"create_timestamp":1793387830,"user_info":{"base_info":{"user_name":"阿甲","user_avatar":"https://example.com/a.jpg"}}}}}],"common_list_info":{"cursor":"{\"offset\":20}","has_more":true,"total":5232},"extra":{"collectors_count":2187646,"credibility_score":9.5,"credibility_score_count":19655}}}`
	var result map[string]any
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		t.Fatal(err)
	}
	page := parseHongguoComments(result)
	if len(page.Items) != 1 || page.Items[0].TimeSec != 1793387830 {
		t.Fatalf("items = %+v", page.Items)
	}
	if page.Total != 5232 || page.CollectorsCount != 2187646 || page.Score != 9.5 || page.ScoreCount != 19655 {
		t.Fatalf("page meta = %+v", page)
	}
}
