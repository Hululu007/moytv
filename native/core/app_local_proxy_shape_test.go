package core

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestNativeOpenPlaybackServesLoopbackTokenURL(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v.mp4" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte("hgtv-shape-bytes"))
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	media := providerMedia{URL: upstream.URL + "/v.mp4", Referer: "https://example.test/", Quality: 1080}
	plan, err := engine.nativeOpenPlayback(t.Context(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Hostname() != "127.0.0.1" || parsed.Port() == "" || parsed.Port() == "10010" {
		t.Fatalf("plan URL must be an ephemeral loopback address, got %q", plan.URL)
	}
	if parsed.Path == "/hg.mp4" || !strings.HasSuffix(parsed.Path, ".mp4") {
		t.Fatalf("plan URL must be a token asset path, got %q", plan.URL)
	}
	resp, err := http.Get(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK || string(body) != "hgtv-shape-bytes" {
		t.Fatalf("loopback proxy serve wrong: %d %q", resp.StatusCode, body)
	}
}
