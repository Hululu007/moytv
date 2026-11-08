package core

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestNativeOpenPlaybackServesMPD(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mpd := `<?xml version="1.0" encoding="UTF-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT127S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="299" bandwidth="8000000" codecs="avc1.64002A" width="1920" height="1080"><BaseURL>https://example.test/v299</BaseURL><SegmentBase indexRange="741-1048"><Initialization range="0-740"/></SegmentBase></Representation></AdaptationSet></Period></MPD>`
	media := providerMedia{URL: "https://www.youtube.com/watch?v=njX2bu-_Vw4/manifest.mpd", Referer: "https://www.youtube.com/", Playlist: mpd, Quality: 2160}
	plan, err := engine.nativeOpenPlayback(t.Context(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Hostname() != "127.0.0.1" || !strings.HasSuffix(parsed.Path, ".mpd") {
		t.Fatalf("MPD plan URL must be loopback .mpd, got %q", plan.URL)
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
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "<MPD") {
		t.Fatalf("MPD serve wrong: %d %q", resp.StatusCode, string(body))
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "dash") {
		t.Fatalf("MPD content type wrong: %q", ct)
	}
}
