package seku

import (
	"os"
	"strings"
	"testing"
)

// Real block captured from a live MissAV detail page (2026-11-21). The site
// moved its media CDN to Bunny (b-cdn.net) and now ships the address inside a
// packed eval block, so the old reversed-fragment parse finds nothing.
func loadPackerFixture(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("testdata/missav_packer_block.txt")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return string(raw)
}

func TestMissavUnpackRealBlock(t *testing.T) {
	block := loadPackerFixture(t)
	if !missavPackerRe.MatchString(block) {
		t.Fatalf("packer regex no longer matches the live block shape")
	}
	decoded := missavUnpackPage(block)
	if decoded == "" {
		t.Fatalf("decoded empty")
	}
	if !strings.Contains(decoded, "playlist.m3u8") {
		t.Fatalf("playlist missing from decoded output: %.200s", decoded)
	}
	// The dictionary values must actually be substituted, not left as tokens.
	if strings.Contains(decoded, "'c://a-9-8.") {
		t.Fatalf("payload not expanded: %.200s", decoded)
	}
}

func TestMissavExtractM3u8FromPackedPage(t *testing.T) {
	page := "<html><script>" + loadPackerFixture(t) + "</script></html>"
	got := missavExtractM3u8(page)
	if !strings.HasPrefix(got, "https://") {
		t.Fatalf("expected absolute playlist, got %q", got)
	}
	if !strings.HasSuffix(got, "/playlist.m3u8") {
		t.Fatalf("expected master playlist, got %q", got)
	}
	// The CDN host is per-page randomised, so only the shape is asserted.
	if !strings.Contains(got, ".b-cdn.net/") {
		t.Fatalf("unexpected host family: %q", got)
	}
}

// A page with no packed block must still fall through to the legacy tiers
// instead of returning early with an empty string.
func TestMissavExtractLegacyStillWorks(t *testing.T) {
	page := `<video src="https://surrit.com/abc-123/playlist.m3u8"></video>`
	got := missavExtractM3u8(page)
	if !strings.Contains(got, "playlist.m3u8") {
		t.Fatalf("legacy tier broken: %q", got)
	}
}

// The list page was re-checked against a live mirror the same day: cards are
// absolute /cn/<code> links inside <a>, covers come from fourhoi (200). This
// guards the list parser from being narrowed again while touching playback.
func TestMissavListParsesLiveCardShape(t *testing.T) {
	page := `<div class="thumbnail group">
	<a href="https://missav.fans/cn/nghj-073" alt="nghj-073" >
	<img data-src="https://fourhoi.mrstcdn.store/nghj-073/cover-t.jpg" />
	</a>
	<span class="absolute bottom-1 right-1">2:05:11</span>
	Nghj-073 sample title
	</div>`
	works := mirrorParseList(page)
	if len(works) != 1 {
		t.Fatalf("expected 1 card, got %d", len(works))
	}
	if works[0].RawID != "nghj-073" {
		t.Fatalf("rawID = %q", works[0].RawID)
	}
	if works[0].Cover == "" {
		t.Fatalf("cover not picked")
	}
}
