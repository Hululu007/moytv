package core

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHongguoByIDLiveSmoke(t *testing.T) {
	if os.Getenv("HG_BYID_LIVE_SMOKE") != "1" {
		t.Skip("live smoke requires HG_BYID_LIVE_SMOKE=1")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	series := "7701935931787316286"
	comments, err := engine.downloader.hongguoComments(ctx, series, "")
	if err != nil || comments.Total <= 0 {
		t.Fatalf("comments by id: total=%d err=%v", comments.Total, err)
	}
	t.Logf("comments by id: total=%d items=%d", comments.Total, len(comments.Items))
	entry, err := engine.downloader.hongguoAppDetail(ctx, series)
	if err != nil || len(entry.Chapters) == 0 {
		t.Fatalf("detail for danmaku video: chapters=%d err=%v", len(entry.Chapters), err)
	}
	video := strings.TrimPrefix(entry.Chapters[0].VideoURL, "hongguo-cenc://")
	if video == "" || video == entry.Chapters[0].VideoURL {
		t.Fatalf("first chapter has no cenc video id: %q", entry.Chapters[0].VideoURL)
	}
	page, err := engine.downloader.hongguoDanmaku(ctx, series, video, 0, 30000)
	if err != nil || len(page.Items) == 0 {
		t.Fatalf("danmaku by id: items=%d err=%v", len(page.Items), err)
	}
	t.Logf("danmaku by id: items=%d total=%d", len(page.Items), page.Total)
}
