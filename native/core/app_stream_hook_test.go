package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"moyi/native/core/seku"
)

type testStreamHook struct {
	sign    func(string) (string, error)
	refresh func(string) (string, bool)
	short   bool
}

func (h testStreamHook) SignSegment(raw string) (string, error) {
	if h.sign == nil {
		return raw, nil
	}
	return h.sign(raw)
}

func (h testStreamHook) RefreshPlaylist(failed string) (string, bool) {
	if h.refresh == nil {
		return "", false
	}
	return h.refresh(failed)
}

func (h testStreamHook) ShortRefetch() bool { return h.short }

func relayGet(t *testing.T, url string) (int, []byte) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, body
}

func TestRelayHookSignsSegmentFetch(t *testing.T) {
	var tokenSeen bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/pl.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, "#EXTM3U\n#EXTINF:10,\nseg.ts\n")
		case "/seg.ts":
			if r.URL.Query().Get("token") != "good" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			tokenSeen = true
			_, _ = w.Write([]byte("segment-bytes"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	hook := testStreamHook{sign: func(raw string) (string, error) {
		if strings.Contains(raw, "?") {
			return raw + "&token=good", nil
		}
		return raw + "?token=good", nil
	}}
	relayURL, _ := stream.nativeOpen(providerMedia{URL: upstream.URL + "/pl.m3u8", Referer: "https://example.test/", Hook: hook}, false)
	status, playlist := relayGet(t, relayURL)
	if status != http.StatusOK || !strings.HasPrefix(string(playlist), "#EXTM3U") {
		t.Fatalf("playlist: %d %q", status, playlist)
	}
	var segmentURL string
	for _, line := range strings.Split(string(playlist), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			segmentURL = line
		}
	}
	if segmentURL == "" || strings.Contains(segmentURL, upstream.URL) {
		t.Fatalf("segment must be a relay URL: %q", segmentURL)
	}
	status, body := relayGet(t, segmentURL)
	if status != http.StatusOK || string(body) != "segment-bytes" || !tokenSeen {
		t.Fatalf("segment: %d %q tokenSeen=%v", status, body, tokenSeen)
	}
}

func TestRelayPlaylistRefreshOnFailure(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/dead.m3u8":
			w.WriteHeader(http.StatusNotFound)
		case "/live.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, "#EXTM3U\n#EXTINF:10,\nseg.ts\n")
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	hook := testStreamHook{refresh: func(failed string) (string, bool) {
		if strings.HasSuffix(failed, "/dead.m3u8") {
			return upstream.URL + "/live.m3u8", true
		}
		return "", false
	}}
	relayURL, _ := stream.nativeOpen(providerMedia{URL: upstream.URL + "/dead.m3u8", Referer: "https://example.test/", Hook: hook}, false)
	status, playlist := relayGet(t, relayURL)
	if status != http.StatusOK || !strings.Contains(string(playlist), "#EXTM3U") {
		t.Fatalf("refreshed playlist: %d %q", status, playlist)
	}
}

func TestRelayShortRefetchKeepsLongest(t *testing.T) {
	hits := 0
	full := strings.Repeat("s", 1000)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/pl.m3u8" {
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = io.WriteString(w, "#EXTM3U\n#EXTINF:10,\nseg.ts\n")
			return
		}
		hits++
		if hits <= 2 {
			_, _ = w.Write([]byte(strings.Repeat("x", 100)))
			return
		}
		_, _ = w.Write([]byte(full))
	}))
	defer upstream.Close()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	relayURL, _ := stream.nativeOpen(providerMedia{URL: upstream.URL + "/pl.m3u8", Referer: "https://example.test/", Hook: testStreamHook{short: true}}, false)
	_, playlist := relayGet(t, relayURL)
	var segmentURL string
	for _, line := range strings.Split(string(playlist), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			segmentURL = line
		}
	}
	status, body := relayGet(t, segmentURL)
	if status != http.StatusOK || string(body) != full {
		t.Fatalf("short refetch: %d len=%d hits=%d", status, len(body), hits)
	}
}

type blockingReader struct{ release chan struct{} }

func (r blockingReader) Read(p []byte) (int, error) {
	<-r.release
	return 0, io.EOF
}

func TestIdleTimeoutReaderErrorsOnStall(t *testing.T) {
	reader := &nativeIdleTimeoutReader{reader: blockingReader{release: make(chan struct{})}, idle: 50 * time.Millisecond}
	start := time.Now()
	if _, err := reader.Read(make([]byte, 16)); err == nil {
		t.Fatal("stalled read must error")
	} else if time.Since(start) > 5*time.Second {
		t.Fatalf("idle timeout took too long: %v", time.Since(start))
	}
}

func TestNativeOpenPlaybackEmitsOriginalURL(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	first := providerMedia{URL: "https://first.test/video.mp4", Referer: "https://first.test/", Quality: 1080}
	second := providerMedia{URL: "https://second.test/video.mp4", Referer: "https://second.test/", Quality: 720}
	first.Variants = []providerMedia{second}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(first, 0))
	if err != nil {
		t.Fatal(err)
	}
	if plan.OriginalURL != first.URL || plan.URL == first.URL {
		t.Fatalf("originalUrl must be the upstream address, plan URL the relay: %+v", plan)
	}
	next, err := engine.nativeSelectRoute(context.Background(), plan.Session, 1)
	if err != nil {
		t.Fatal(err)
	}
	if next.OriginalURL != second.URL {
		t.Fatalf("route switch must update originalUrl: %+v", next)
	}
var _ seku.StreamHook = testStreamHook{}
}
