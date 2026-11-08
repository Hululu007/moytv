package core

import "testing"

func TestHongguoFallbackAPIURL(t *testing.T) {
	if got := hongguoFallbackAPIURL(map[string]any{"fallback_api": "https://example.test/fb"}); got != "https://example.test/fb" {
		t.Fatalf("plain fallback_api %q", got)
	}
	if got := hongguoFallbackAPIURL(map[string]any{"fallback_api": []any{"https://example.test/fb2"}}); got != "https://example.test/fb2" {
		t.Fatalf("array fallback_api %q", got)
	}
	if got := hongguoFallbackAPIURL(map[string]any{"fallback_api": `{"fallback_api":"https://example.test/fb3"}`}); got != "https://example.test/fb3" {
		t.Fatalf("json fallback_api %q", got)
	}
	if got := hongguoFallbackAPIURL(map[string]any{}); got != "" {
		t.Fatalf("missing fallback_api %q", got)
	}
}

func TestHongguoFallbackVideoRows(t *testing.T) {
	rows, err := hongguoFallbackVideoRows(`{"video_info":{"data":{"video_list":{"1080":{"main_url":"https://example.test/v1080.mp4","spade_a":"AAAA"},"720":{"main_url":"https://example.test/v720.mp4"}}}}}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows %d, want 2", len(rows))
	}
	first, _ := rows[0].(map[string]any)
	if first == nil {
		t.Fatal("first row is not a map")
	}
	encrypt, _ := first["encrypt_info"].(map[string]any)
	if encrypt == nil || encrypt["spade_a"] != "AAAA" {
		t.Fatalf("spade_a not normalized into encrypt_info: %+v", first["encrypt_info"])
	}
	if _, err := hongguoFallbackVideoRows(`{"video_info":{"data":{"video_list":{}}}}`); err == nil {
		t.Fatal("empty video_list should fail")
	}
}

func TestParseHGTVWebDetail(t *testing.T) {
	body := `<html><script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"123","series_title":"测试剧","series_cover":"https://example.test/cover.jpg","vid_list":["111","222"]}}}};</script></html>`
	drama, chapters, err := parseHGTVWebDetail(body, "123")
	if err != nil {
		t.Fatal(err)
	}
	if drama.SourceID != "123" || drama.Source != sourceHGTV {
		t.Fatalf("drama %+v", drama)
	}
	if len(chapters) != 2 || chapters[0].VideoURL != "hongguo-cenc://111" || chapters[1].Title != "第2集" {
		t.Fatalf("chapters %+v", chapters)
	}
	if _, _, err := parseHGTVWebDetail(`<html></html>`, "123"); err == nil {
		t.Fatal("missing router data should fail")
	}
}
