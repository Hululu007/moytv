package core

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func streamPortOf(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	_, port, _ := net.SplitHostPort(parsed.Host)
	return port
}

func streamSwapPort(raw, port string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	parsed.Host = "127.0.0.1:" + port
	return parsed.String()
}

func TestStreamSplitPorts(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/seg.ts":
			_, _ = w.Write([]byte("segment-bytes"))
		case "/v.mp4":
			_, _ = w.Write([]byte("mp4-bytes"))
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
	defer stream.passthroughServer.Close()
	rewritePort := streamPortOf(stream.address)
	passthroughPort := streamPortOf(stream.passthroughAddress)
	if rewritePort == "" || passthroughPort == "" || rewritePort == passthroughPort {
		t.Fatalf("ports must differ: rewrite=%q passthrough=%q", rewritePort, passthroughPort)
	}
	playlistURL, _ := stream.nativeOpen(providerMedia{URL: upstream.URL + "/pl.m3u8", Referer: "https://example.test/", Playlist: "#EXTM3U\n#EXTINF:10,\nseg.ts\n"}, false)
	if streamPortOf(playlistURL) != rewritePort {
		t.Fatalf("playlist entry must use the rewrite port: %q", playlistURL)
	}
	status, playlist := relayGet(t, playlistURL)
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
	if segmentURL == "" || streamPortOf(segmentURL) != passthroughPort {
		t.Fatalf("segment must use the passthrough port: %q", segmentURL)
	}
	status, body := relayGet(t, segmentURL)
	if status != http.StatusOK || string(body) != "segment-bytes" {
		t.Fatalf("segment: %d %q", status, body)
	}
	status, _ = relayGet(t, streamSwapPort(playlistURL, passthroughPort))
	if status != http.StatusNotFound {
		t.Fatalf("playlist on the passthrough port must 404: %d", status)
	}
	status, _ = relayGet(t, streamSwapPort(segmentURL, rewritePort))
	if status != http.StatusNotFound {
		t.Fatalf("segment on the rewrite port must 404: %d", status)
	}
	mp4URL, _ := stream.nativeOpen(providerMedia{URL: upstream.URL + "/v.mp4", Referer: "https://example.test/"}, false)
	if streamPortOf(mp4URL) != passthroughPort {
		t.Fatalf("mp4 entry must use the passthrough port: %q", mp4URL)
	}
	status, body = relayGet(t, mp4URL)
	if status != http.StatusOK || string(body) != "mp4-bytes" {
		t.Fatalf("mp4: %d %q", status, body)
	}
	status, _ = relayGet(t, streamSwapPort(mp4URL, rewritePort))
	if status != http.StatusNotFound {
		t.Fatalf("mp4 on the rewrite port must 404: %d", status)
	}
}
