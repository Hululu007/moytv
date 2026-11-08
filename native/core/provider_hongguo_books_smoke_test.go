package core

import (
	"context"
	"net/http"
	"os"
	"testing"
	"time"
)

func TestHongguoBooksLiveSmoke(t *testing.T) {
	if os.Getenv("HG_BOOKS_LIVE_SMOKE") != "1" {
		t.Skip("live smoke requires HG_BOOKS_LIVE_SMOKE=1")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	d := &Downloader{cfg: Config{dataDir: t.TempDir(), Retries: 2}, client: &http.Client{Transport: http.DefaultTransport}, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}}
	audio, audioFilters, err := d.fetchHongguoBookmallCatalog(ctx, 5, "", 4)
	if err != nil || len(audio) == 0 {
		t.Fatalf("audio bookmall: %d items, err=%v", len(audio), err)
	}
	t.Logf("audio bookmall: %d items, filters=%v, first=%q", len(audio), audioFilters, audio[0].Title)
	if audio[0].Source != sourceHongguo {
		t.Fatalf("audio book source = %q, want hongguo", audio[0].Source)
	}
	novel, _, err := d.fetchHongguoBookmallCatalog(ctx, 2, "", 3)
	if err != nil || len(novel) == 0 {
		t.Fatalf("novel bookmall: %d items, err=%v", len(novel), err)
	}
	t.Logf("novel bookmall: %d items, first=%q", len(novel), novel[0].Title)
	bcat, bcatFilters, hasMore, err := d.fetchHongguoBookCategoryCatalog(ctx, "1", "", "", "", 1)
	if err != nil || len(bcat) == 0 {
		t.Fatalf("bcat1: %d items, err=%v", len(bcat), err)
	}
	t.Logf("bcat1: %d items, hasMore=%v, filters=%d, first=%q", len(bcat), hasMore, len(bcatFilters), bcat[0].Title)
	novelBookID := ""
	if len(novel) > 0 {
		novelBookID = ""
		if parts := len(novel[0].SourceID); parts > 0 {
			novelBookID = novel[0].SourceID[len("novel:"):]
		}
	}
	if novelBookID != "" {
		novelDrama, novelChapters, err := d.fetchHongguoNovelDetail(ctx, novelBookID)
		if err != nil || len(novelChapters) == 0 {
			t.Fatalf("novel detail %s: chapters=%d err=%v", novelBookID, len(novelChapters), err)
		}
		t.Logf("novel detail %q: %d chapters, first=%q url=%q routes=%v", novelDrama.Title, len(novelChapters), novelChapters[0].Title, novelChapters[0].VideoURL, novelChapters[0].Routes)
		if len(novelChapters[0].Routes) == 0 {
			t.Fatalf("novel detail first chapter has no audio route")
		}
		audioChapter := novelChapters[0]
		audioChapter.VideoURL = novelChapters[0].Routes[0]
		audioMedia, err := d.resolveHongguoAudioMedia(ctx, Task{DramaID: novelDrama.ID, Chapter: audioChapter})
		if err != nil {
			t.Fatalf("novel tts resolve: %v", err)
		}
		t.Logf("novel tts resolve: url=%q headers=%v", audioMedia.URL, audioMedia.Referer)
		novelMedia, err := d.resolveHongguoNovelMedia(ctx, Task{DramaID: novelDrama.ID, Chapter: novelChapters[0]})
		if err != nil {
			t.Fatalf("novel chapter resolve: %v", err)
		}
		if len(novelMedia.URL) < 20 {
			t.Fatalf("novel chapter media too short")
		}
		t.Logf("novel chapter resolve: url len=%d", len(novelMedia.URL))
	}
	drama, chapters, err := d.fetchHongguoAudioDetailHongguo(ctx, "7189544077984009277")
	if err != nil {
		t.Fatalf("audio detail hongguo: %v", err)
	}
	if drama.ID != "hongguo:audio:7189544077984009277" || len(chapters) != 2566 {
		t.Fatalf("audio detail hongguo: id=%q chapters=%d", drama.ID, len(chapters))
	}
	t.Logf("audio detail hongguo: %q %d chapters", drama.Title, len(chapters))
}
