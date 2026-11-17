package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHongguoPlayAuthFromData(t *testing.T) {
	token, expires := hongguoPlayAuthFromData(map[string]any{
		"play_auth_token": "dG9rZW4=",
		"expire_time":     json.Number("1794434705"),
	})
	if token != "dG9rZW4=" || expires != 1794434705 {
		t.Fatalf("number expire: got token=%q expires=%d", token, expires)
	}
	token, expires = hongguoPlayAuthFromData(map[string]any{
		"play_auth_token": "dG9rZW4=",
		"expire_time":     "1794434705",
	})
	if expires != 1794434705 {
		t.Fatalf("string expire: got %d", expires)
	}
	token, expires = hongguoPlayAuthFromData(map[string]any{"expire_time": json.Number("1794434705")})
	if token != "" || expires != 0 {
		t.Fatalf("missing token: got token=%q expires=%d", token, expires)
	}
	token, expires = hongguoPlayAuthFromData(nil)
	if token != "" || expires != 0 {
		t.Fatalf("nil data: got token=%q expires=%d", token, expires)
	}
}

func TestHongguoDecodePlayAuthToken(t *testing.T) {
	plain := "video_id=7503780679541328958&auth=\xfb\xff\xfe"
	forms := map[string]string{
		"std":     base64.StdEncoding.EncodeToString([]byte(plain)),
		"urlsafe": base64.URLEncoding.EncodeToString([]byte(plain)),
		"raw":     base64.RawStdEncoding.EncodeToString([]byte(plain)),
		"rawurl":  base64.RawURLEncoding.EncodeToString([]byte(plain)),
	}
	if forms["std"] == forms["urlsafe"] || forms["raw"] == forms["rawurl"] {
		t.Fatalf("fixture payload must distinguish std/urlsafe forms: %+v", forms)
	}
	for name, encoded := range forms {
		decoded, err := hongguoDecodePlayAuthToken(encoded)
		if err != nil || decoded != plain {
			t.Fatalf("%s: got %q err=%v", name, decoded, err)
		}
	}
	if _, err := hongguoDecodePlayAuthToken("!!!not-base64!!!"); err == nil {
		t.Fatalf("invalid base64 must fail")
	}
	if _, err := hongguoDecodePlayAuthToken(""); err == nil {
		t.Fatalf("empty token must fail")
	}
}

func hongguoPlayAuthTestServer(t *testing.T, body string, status int, hits *int) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	old := hongguoPlayAuthAPIBase
	hongguoPlayAuthAPIBase = server.URL + "/"
	t.Cleanup(func() { hongguoPlayAuthAPIBase = old })
	return server
}

func TestHongguoResolvePlayAuthSecondStage(t *testing.T) {
	ctx := context.Background()
	token := base64.StdEncoding.EncodeToString([]byte("video_id=7503780679541328958&auth=xyz"))
	future := time.Now().Unix() + 3600
	d := &Downloader{client: &http.Client{}}

	hits := 0
	hongguoPlayAuthTestServer(t, `{"data":{"play_url":"https://v3-reading-video.qznovelvod.com/x/playlist.m3u8","backup":"https://v3-reading-video.qznovelvod.com/x/video.mp4"}}`, http.StatusOK, &hits)
	address, err := d.hongguoResolvePlayAuthSecondStage(ctx, token, future)
	if err != nil || address != "https://v3-reading-video.qznovelvod.com/x/playlist.m3u8" {
		t.Fatalf("json m3u8 preferred: got %q err=%v", address, err)
	}
	if hits != 1 {
		t.Fatalf("expected 1 call, got %d", hits)
	}

	hits = 0
	hongguoPlayAuthTestServer(t, `https://v3-reading-video.qznovelvod.com/y/video.mp4`, http.StatusOK, &hits)
	address, err = d.hongguoResolvePlayAuthSecondStage(ctx, token, future)
	if err != nil || address != "https://v3-reading-video.qznovelvod.com/y/video.mp4" {
		t.Fatalf("plain text url: got %q err=%v", address, err)
	}

	hits = 0
	hongguoPlayAuthTestServer(t, `{"error":"nope"}`, http.StatusInternalServerError, &hits)
	if _, err := d.hongguoResolvePlayAuthSecondStage(ctx, token, future); err == nil {
		t.Fatalf("500 must fail")
	}

	hits = 0
	hongguoPlayAuthTestServer(t, `{}`, http.StatusOK, &hits)
	if _, err := d.hongguoResolvePlayAuthSecondStage(ctx, token, time.Now().Unix()-10); err == nil {
		t.Fatalf("expired token must fail without calling")
	}
	if hits != 0 {
		t.Fatalf("expired token must not call, got %d calls", hits)
	}
	if _, err := d.hongguoResolvePlayAuthSecondStage(ctx, "", future); err == nil {
		t.Fatalf("empty token must fail")
	}
}

func TestHongguoApplyPlayAuth(t *testing.T) {
	ctx := context.Background()
	token := base64.StdEncoding.EncodeToString([]byte("video_id=7503780679541328958&auth=xyz"))
	future := time.Now().Unix() + 3600
	d := &Downloader{client: &http.Client{}}
	direct := providerMedia{URL: "https://v3-reading-video.qznovelvod.com/direct/video.mp4"}

	unchanged := d.hongguoApplyPlayAuth(ctx, direct, map[string]any{"expire_time": future})
	if unchanged.URL != direct.URL || unchanged.PlayAuthToken != "" {
		t.Fatalf("no token must leave media unchanged: %+v", unchanged)
	}

	hits := 0
	hongguoPlayAuthTestServer(t, `{"url":"https://v3-reading-video.qznovelvod.com/second/playlist.m3u8"}`, http.StatusOK, &hits)
	applied := d.hongguoApplyPlayAuth(ctx, direct, map[string]any{"play_auth_token": token, "expire_time": future})
	if applied.URL != "https://v3-reading-video.qznovelvod.com/second/playlist.m3u8" {
		t.Fatalf("second stage must replace url: got %q", applied.URL)
	}
	if applied.PlayAuthToken != token || applied.PlayAuthExpires != future {
		t.Fatalf("token fields must be carried: %+v", applied)
	}

	hits = 0
	hongguoPlayAuthTestServer(t, `{}`, http.StatusInternalServerError, &hits)
	fallback := d.hongguoApplyPlayAuth(ctx, direct, map[string]any{"play_auth_token": token, "expire_time": future})
	if fallback.URL != direct.URL {
		t.Fatalf("second stage failure must keep direct url: got %q", fallback.URL)
	}
	if fallback.PlayAuthToken != token {
		t.Fatalf("token must still be carried on failure: %+v", fallback)
	}
}

// V5 口径：单腿直取，不再分 tab/multi 全签、video_model 免签三腿；
// 请求只带 V5 签名头（无 X-Gorgon），匿名直取不带播放鉴权、设备不轮换。
func TestHongguoVideoModelPlayerOnlyDirect(t *testing.T) {
	var requests []string
	sawV5Headers := false
	sawLegacySigning := false
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		requests = append(requests, "model@"+request.URL.Query().Get("device_id"))
		if request.Header.Get("X-Helios") != "" && request.Header.Get("X-Medusa") != "" {
			sawV5Headers = true
		}
		if request.Header.Get("X-Gorgon") != "" || request.Header.Get("X-Argus") != "" {
			sawLegacySigning = true
		}
		return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("V5 direct must return the stream", media)
	}
	if media.PlayAuthToken != "" || media.PlayAuthExpires != 0 {
		t.Fatalf("anonymous direct must carry no play auth token: %+v", media)
	}
	if !sawV5Headers {
		t.Fatal("V5 request must carry helios/medusa headers", requests)
	}
	if sawLegacySigning {
		t.Fatal("V5 request must not carry legacy gorgon/argus headers", requests)
	}
	if len(requests) != 1 || requests[0] != "model@7" {
		t.Fatal("V5 success must cost exactly one request on the current device", requests)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("V5 direct must not burn device rotations", state)
	}
}
