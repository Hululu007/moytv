package core

import (
	"context"
	"encoding/hex"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHongguoAudioLiveSmoke(t *testing.T) {
	if os.Getenv("HG_AUDIO_LIVE_SMOKE") != "1" {
		t.Skip("live smoke requires HG_AUDIO_LIVE_SMOKE=1")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	d := &Downloader{cfg: Config{dataDir: t.TempDir(), Retries: 2}, client: &http.Client{Transport: http.DefaultTransport}, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}}
	items, hasMore, err := d.fetchHongguoAudioCatalogPage(ctx, "audio", 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("audio catalog: %d items, err=%v", len(items), err)
	}
	t.Logf("audio catalog p1: %d items, hasMore=%v, first=%q", len(items), hasMore, items[0].Title)
	bookID := "7189544077984009277"
	drama, chapters, err := d.fetchHongguoAudioDetail(ctx, bookID)
	if err != nil {
		t.Fatalf("audio detail %s: %v", bookID, err)
	}
	if drama.Title != "军神出狱" || len(chapters) != 2566 {
		t.Fatalf("audio detail: title=%q chapters=%d, want 军神出狱/2566", drama.Title, len(chapters))
	}
	t.Logf("audio detail %s %q: %d chapters, first=%q, url=%q", bookID, drama.Title, len(chapters), chapters[0].Title, chapters[0].VideoURL)
	media, err := d.resolveHongguoAudioMedia(ctx, Task{DramaID: providerDramaID(sourceHongguoAudio, bookID), Chapter: chapters[0]})
	if err != nil {
		t.Fatalf("audio resolve ep1: %v", err)
	}
	if len(media.CENCKey) != 16 || !media.Audio || !strings.HasPrefix(media.URL, "https://") {
		t.Fatalf("audio resolve: key=%d audio=%v url=%q", len(media.CENCKey), media.Audio, media.URL)
	}
	t.Logf("audio resolve ep1: key=%s url_host=%s duration=%v", hex.EncodeToString(media.CENCKey), strings.Split(strings.TrimPrefix(media.URL, "https://"), "/")[0], media.Duration)
	if hex.EncodeToString(media.CENCKey) != "d9496d2394564c1d99aa8356b9160d5b" {
		t.Fatalf("audio resolve key mismatch: got %s", hex.EncodeToString(media.CENCKey))
	}
}
