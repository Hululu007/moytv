package seku

import (
	"os"
	"strings"
	"testing"
)

func ytTestAdaptive() []interface{} {
	mk := func(itag float64, mime, url string, w, h, fps, br float64, initR, indexR map[string]interface{}) map[string]interface{} {
		return map[string]interface{}{"itag": itag, "mimeType": mime, "url": url, "width": w, "height": h, "fps": fps, "bitrate": br, "initRange": initR, "indexRange": indexR, "approxDurationMs": "127000"}
	}
	r := func(s, e float64) map[string]interface{} { return map[string]interface{}{"start": s, "end": e} }
	return []interface{}{
		mk(337, `video/webm; codecs="vp9.2"`, "https://example.test/v337?x=1&y=2", 3840, 2160, 60, 20000000, r(0, 319), r(320, 723)),
		mk(299, `video/mp4; codecs="avc1.64002A"`, "https://example.test/v299", 1920, 1080, 60, 8000000, r(0, 740), r(741, 1048)),
		mk(140, `audio/mp4; codecs="mp4a.40.2"`, "https://example.test/a140", 0, 0, 0, 128000, r(0, 722), r(723, 910)),
		mk(251, `audio/webm; codecs="opus"`, "https://example.test/a251", 0, 0, 0, 160000, r(0, 265), r(266, 483)),
	}
}

func TestYoutubeAndroidClient(t *testing.T) {
	c, ok := ytClients["ANDROID"]
	if !ok {
		t.Fatal("ANDROID client missing")
	}
	if c["clientName"] != "ANDROID" || c["clientVersion"] != "20.10.38" {
		t.Fatalf("ANDROID client wrong: %v", c)
	}
	if ytClientNum["ANDROID"] != "3" || ytClientKey["ANDROID"] != ytKeyAnd {
		t.Fatalf("ANDROID num/key wrong: %q %q", ytClientNum["ANDROID"], ytClientKey["ANDROID"])
	}
}

func TestYoutubeCategories21(t *testing.T) {
	if len(ytCats) != 21 {
		t.Fatalf("ytCats = %d, want 21", len(ytCats))
	}
	names := map[string]bool{}
	for _, c := range ytCats {
		names[c.name] = true
		if c.id == "browse:FEstorefront" || c.id == "browse:FEpodcasts_destination|qgcCCAE%3D" {
			t.Fatalf("deleted category still present: %q", c.id)
		}
	}
	for _, want := range []string{"短剧", "纪录片", "新闻直播", "4K", "直播台", "首页", "Shorts"} {
		if !names[want] {
			t.Fatalf("missing category %q", want)
		}
	}
	if ytModeOf("live").kind != "live" {
		t.Fatalf("live mode not live: %v", ytModeOf("live"))
	}
	if len(ytLiveList) == 0 {
		t.Fatal("live list empty")
	}
}

func TestYoutubeBuildMPD(t *testing.T) {
	mpd, ok := ytBuildMPD(ytTestAdaptive(), "127")
	if !ok {
		t.Fatal("MPD build failed")
	}
	if !strings.Contains(mpd, "<MPD") || !strings.Contains(mpd, "3840") || !strings.Contains(mpd, "2160") {
		t.Fatalf("MPD missing 2160 representation: %s", mpd)
	}
	if !strings.Contains(mpd, "mp4a.40.2") || !strings.Contains(mpd, "opus") {
		t.Fatalf("MPD missing audio: %s", mpd)
	}
	if !strings.Contains(mpd, "x=1&amp;y=2") {
		t.Fatalf("MPD URL not XML-escaped: %s", mpd)
	}
	if !strings.Contains(mpd, `indexRange="320-723"`) || !strings.Contains(mpd, `range="0-319"`) {
		t.Fatalf("MPD missing SegmentBase ranges: %s", mpd)
	}
	if !strings.Contains(mpd, "PT127S") {
		t.Fatalf("MPD missing duration: %s", mpd)
	}
}

func TestYoutubeBuildMPD1080Fallback(t *testing.T) {
	ad := ytTestAdaptive()
	// Drop the 2160 entry: MPD must still build, but must not claim 2160.
	mpd, ok := ytBuildMPD(ad[1:], "127")
	if !ok {
		t.Fatal("1080 MPD build failed")
	}
	if strings.Contains(mpd, "2160") {
		t.Fatalf("1080 MPD must not claim 2160: %s", mpd)
	}
	if !strings.Contains(mpd, "1080") {
		t.Fatalf("1080 MPD missing 1080: %s", mpd)
	}
}

func TestYoutubeBuildMPDNeedsAudio(t *testing.T) {
	videoOnly := ytTestAdaptive()[:2]
	if _, ok := ytBuildMPD(videoOnly, "127"); ok {
		t.Fatal("MPD without audio should fail")
	}
}

func TestYoutubeLiveMPD(t *testing.T) {
	if os.Getenv("YT_LIVE_SMOKE") != "1" {
		t.Skip("YT_LIVE_SMOKE != 1")
	}
	res, err := ytResolve("youtube", "njX2bu-_Vw4")
	if err != nil {
		t.Fatal(err)
	}
	mpd, _ := res["playlist"].(string)
	url, _ := res["url"].(string)
	if !strings.Contains(mpd, "2160") || !strings.Contains(mpd, "vp9.2") && !strings.Contains(mpd, "av01") {
		t.Fatalf("live MPD missing 2160 HDR: url=%q mpd-head=%.500s", url, mpd)
	}
	if res["format"] != "mpd" || res["protocol"] != "dash" || !strings.HasSuffix(url, ".mpd") {
		t.Fatalf("live result not mpd/dash: format=%v protocol=%v url=%q", res["format"], res["protocol"], url)
	}
}

func TestYoutubeSlotRegistered(t *testing.T) {
	impl, ok := slotSites["youtube"]
	if !ok || impl == nil {
		t.Fatal("youtube slot not registered")
	}
	if impl.Key != "youtube" || impl.Categories == nil || impl.Resolve == nil {
		t.Fatalf("youtube impl incomplete: %+v", impl)
	}
	found := false
	for _, s := range slotOrder {
		if s == "youtube" {
			found = true
		}
	}
	if !found {
		t.Fatal("youtube not in slotOrder")
	}
}

func TestYoutubeApplyFilters(t *testing.T) {
	mode := ytApplyFilters(ytModeOf("preset:短剧"), map[string]string{"标签": "总裁", "年份": "2025", "地区": "TW"})
	if mode.a != "短剧 总裁 after:2025-01-01 before:2026-01-01" {
		t.Fatalf("search query = %q", mode.a)
	}
	if mode.gl != "TW" {
		t.Fatalf("gl = %q", mode.gl)
	}
	mode = ytApplyFilters(ytModeOf("preset:动漫"), map[string]string{"二级分类": "遮天"})
	if mode.a != "遮天" {
		t.Fatalf("series query = %q", mode.a)
	}
	if impl := implForSlot("youtube"); impl == nil || impl.CatalogFiltered == nil {
		t.Fatalf("youtube CatalogFiltered not registered")
	}
}
