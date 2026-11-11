package core

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// Live 冒烟：HG_FETCH_SIGN_LIVE=1 时才跑。验 GET 首选 leg、同剧两集取流、
// 扫码取码（只取码、不登录）。发码接口绝不在此调用。
func TestHongguoFetchSignLiveSmoke(t *testing.T) {
	if os.Getenv("HG_FETCH_SIGN_LIVE") != "1" {
		t.Skip("live smoke requires HG_FETCH_SIGN_LIVE=1")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	series := "7701935931787316286"
	entry, err := engine.downloader.hongguoAppDetail(ctx, series)
	if err != nil || len(entry.Chapters) < 2 {
		t.Fatalf("detail: chapters=%d err=%v", len(entry.Chapters), err)
	}
	videos := []string{
		strings.TrimPrefix(entry.Chapters[0].VideoURL, "hongguo-cenc://"),
		strings.TrimPrefix(entry.Chapters[1].VideoURL, "hongguo-cenc://"),
	}
	// GET 首选 leg 单独验一次。
	if media, err := engine.downloader.resolveHongguoVideoTabModel(ctx, videos[0]); err != nil {
		t.Logf("GET leg: err=%v (empty is a known server-side window outcome)", err)
	} else {
		t.Logf("GET leg: urlPrefix=%q variants=%d cencKeyLen=%d", urlPrefix(media.URL), len(media.Variants), len(media.CENCKey))
	}
	// 同剧两集全链取流。
	for i, video := range videos {
		task := Task{DramaID: "hongguo:" + series, Chapter: Chapter{VideoURL: "hongguo-cenc://" + video}}
		media, err := engine.downloader.resolveHongguoMedia(ctx, task)
		if err != nil {
			t.Fatalf("episode %d resolve failed: %v", i+1, err)
		}
		if !strings.HasPrefix(media.URL, "https://") {
			t.Fatalf("episode %d: bad url prefix %q", i+1, urlPrefix(media.URL))
		}
		t.Logf("episode %d: urlPrefix=%q variants=%d cencKeyLen=%d quality=%d", i+1, urlPrefix(media.URL), len(media.Variants), len(media.CENCKey), media.Quality)
		if len(media.CENCKey) != 0 && len(media.CENCKey) != 16 {
			t.Fatalf("episode %d: CENC key must be 16 bytes, got %d", i+1, len(media.CENCKey))
		}
	}
	// 扫码取码 live 验一次（只取码、不登录、不轮询）。
	image, expires, err := engine.downloader.hongguoLoginQR(ctx)
	if err != nil {
		t.Fatalf("qr fetch failed: %v", err)
	}
	if len(image) == 0 || expires <= 0 {
		t.Fatalf("qr fetch returned empty image or expiry: len=%d expires=%d", len(image), expires)
	}
	t.Logf("qr: imageBase64Len=%d expiresSeconds=%d", len(image), expires)
}

func urlPrefix(raw string) string {
	if len(raw) > 48 {
		return raw[:48]
	}
	return raw
}
