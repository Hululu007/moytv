package core

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

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

// 假传输：按 URL 分流返回 canned 响应，测 resolveHGTVMedia 的取流链。
// App 档（设备注册/取流）与未知地址一律 404；播放页 200 但
// video_player_info 为空（站方改版后的现状）；备用接口按配置回包。
type fakeHGTVRoundTripper struct {
	fallbackStatus int
	fallbackBody   string
}

func (fake fakeHGTVRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	path := request.URL.Path
	status := http.StatusNotFound
	body := ""
	switch {
	case request.Method == http.MethodPost && strings.HasSuffix(path, "/api/video/protected/fallback-play-info"):
		status = fake.fallbackStatus
		body = fake.fallbackBody
	case strings.HasPrefix(path, "/player/"):
		status = http.StatusOK
		body = `<html><script>window._ROUTER_DATA = {"loaderData":{"player_page":{"vid":"456","series_id":"123","video_player_info":{}}}};</script></html>`
	}
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
		Request:    request,
	}, nil
}

func newFakeHGTVDownloader(fallbackStatus int, fallbackBody string) *Downloader {
	return &Downloader{
		cfg:           Config{Retries: 1},
		client:        &http.Client{Transport: fakeHGTVRoundTripper{fallbackStatus: fallbackStatus, fallbackBody: fallbackBody}},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
}

func TestResolveHGTVMediaUsesFallbackPlayInfo(t *testing.T) {
	downloader := newFakeHGTVDownloader(http.StatusOK, `{"main_url":"https://example.test/full.mp4"}`)
	media, err := downloader.resolveHGTVMedia(context.Background(), Task{DramaID: "hgtv:123", Chapter: Chapter{VideoURL: "hongguo-cenc://456"}})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://example.test/full.mp4" {
		t.Fatalf("主地址 %q，应为备用接口的 main_url", media.URL)
	}
	if len(media.Variants) == 0 || media.Variants[len(media.Variants)-1].URL != hongguoBaseURL+"/video/public/456/360p.mp4" {
		t.Fatalf("末档应为 360p 兜底，实际 variants %+v", media.Variants)
	}
}

func TestResolveHGTVMediaFallbackFailureKeeps360p(t *testing.T) {
	downloader := newFakeHGTVDownloader(http.StatusInternalServerError, "")
	media, err := downloader.resolveHGTVMedia(context.Background(), Task{DramaID: "hgtv:123", Chapter: Chapter{VideoURL: "hongguo-cenc://456"}})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != hongguoBaseURL+"/video/public/456/360p.mp4" {
		t.Fatalf("备用接口失败时主地址应退回 360p，实际 %q", media.URL)
	}
}
