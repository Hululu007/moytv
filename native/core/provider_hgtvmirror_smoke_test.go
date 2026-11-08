package core

import (
	"context"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestParseHGTVMirrorCategories(t *testing.T) {
	body := `<a href="/category/real-drama" class="pc-content-type-jptTDK pc-acti"><span>真人剧</span></a>` +
		`<a href="/category/comic-drama" class="pc-content-type-jptTDK"><span>漫剧</span></a>` +
		`<a href="/category/real-drama" class="pc-content-type-jptTDK"><span>真人剧</span></a>`
	categories := parseHGTVMirrorCategories(body)
	if len(categories) != 2 {
		t.Fatalf("categories %d, want 2", len(categories))
	}
	if categories[0].ID != "real-drama" || categories[0].Name != "真人剧" {
		t.Fatalf("first category %+v", categories[0])
	}
	if categories[1].ID != "comic-drama" || categories[1].Name != "漫剧" {
		t.Fatalf("second category %+v", categories[1])
	}
}

func TestParseHGTVMirrorCards(t *testing.T) {
	body := `<a class="pc-card-DQXf3W" href="/detail?series_id=7701935931787316286"><div class="pc-img-container-lewSpn"><picture><source srcSet="https://example.test/cover.webp" type="image/webp"/><img class="image-PWlIcn" src="https://example.test/cover.image" alt="十八岁太奶奶驾到，重整家族荣耀第五部"/></picture></div><div class="pc-bottom-cover-xkICHs"><p class="pc-episode-TGdnks">全102集</p></div><p class="pc-title-l_s3n8">十八岁太奶奶驾到，重整家族荣耀第五部</p></a>` +
		`<a class="pc-card-DQXf3W" href="/detail?series_id=7701935931787316286"><img src="https://example.test/dup.image" alt="重复"/></a>`
	items := parseHGTVMirrorCards(body)
	if len(items) != 1 {
		t.Fatalf("cards %d, want 1", len(items))
	}
	item := items[0]
	if item.SourceID != "7701935931787316286" {
		t.Fatalf("sourceID %q", item.SourceID)
	}
	if item.Source != sourceHGTVMirror || item.ChannelName != "红果镜像" {
		t.Fatalf("source %q channel %q", item.Source, item.ChannelName)
	}
	if item.Title != "十八岁太奶奶驾到，重整家族荣耀第五部" {
		t.Fatalf("title %q", item.Title)
	}
	if item.Remark != "全102集" {
		t.Fatalf("remark %q", item.Remark)
	}
	cover := ""
	switch v := item.Cover.(type) {
	case string:
		cover = v
	}
	if cover != "https://example.test/cover.image" {
		t.Fatalf("cover %q", cover)
	}
}

func TestHGTVMirrorCategoryValidation(t *testing.T) {
	if !validNativeCategory(sourceHGTVMirror, "real-drama") {
		t.Fatal("real-drama should be valid")
	}
	if !validNativeCategory(sourceHGTVMirror, "") {
		t.Fatal("empty category should be valid")
	}
	if validNativeCategory(sourceHGTVMirror, "a|b") {
		t.Fatal("pipe category should be invalid")
	}
}

func TestHGTVMirrorLiveSmoke(t *testing.T) {
	if os.Getenv("HGTVMIRROR_LIVE_SMOKE") != "1" {
		t.Skip("live smoke requires HGTVMIRROR_LIVE_SMOKE=1")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	d := &Downloader{cfg: Config{dataDir: t.TempDir(), Retries: 2, PageSize: 30, MaxPagesPerSort: 1},
		client: &http.Client{Transport: http.DefaultTransport}, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}}
	categories := d.fetchHGTVMirrorCategories(ctx)
	if len(categories) == 0 {
		t.Fatal("mirror categories empty")
	}
	found := false
	for _, category := range categories {
		if category.ID == "real-drama" {
			found = true
		}
	}
	if !found {
		t.Fatalf("mirror categories %+v lack real-drama", categories)
	}
	t.Logf("mirror categories: %d, first=%q", len(categories), categories[0].Name)
	var seriesID string
	for _, category := range categories {
		items, hasMore, _, err := d.fetchHGTVMirrorCatalogPage(ctx, category.ID, 1)
		if err != nil {
			t.Fatalf("catalog %s page 1: %v", category.ID, err)
		}
		if len(items) < 10 {
			t.Fatalf("catalog %s page 1: %d items, want at least 10", category.ID, len(items))
		}
		if items[0].Title == "" || items[0].Source != sourceHGTVMirror {
			t.Fatalf("catalog %s first item %+v", category.ID, items[0])
		}
		t.Logf("catalog %s p1: %d items, hasMore=%v, first=%q", category.ID, len(items), hasMore, items[0].Title)
		if seriesID == "" {
			seriesID = items[0].SourceID
		}
	}
	page2, _, _, err := d.fetchHGTVMirrorCatalogPage(ctx, "real-drama", 2)
	if err != nil {
		t.Fatalf("catalog real-drama page 2: %v", err)
	}
	page1, _, _, err := d.fetchHGTVMirrorCatalogPage(ctx, "real-drama", 1)
	if err != nil {
		t.Fatalf("catalog real-drama page 1 re-fetch: %v", err)
	}
	seen := map[string]bool{}
	for _, item := range page1 {
		seen[item.SourceID] = true
	}
	overlap := 0
	for _, item := range page2 {
		if seen[item.SourceID] {
			overlap++
		}
	}
	if overlap != 0 {
		t.Fatalf("catalog real-drama page 2 overlaps page 1: %d", overlap)
	}
	t.Logf("catalog real-drama p2: %d items, overlap=%d", len(page2), overlap)
	hot, hotMore, _, err := d.fetchHGTVMirrorCatalogPage(ctx, "", 1)
	if err != nil || len(hot) == 0 {
		t.Fatalf("catalog hot: %d items, err=%v", len(hot), err)
	}
	if hotMore {
		t.Fatal("catalog hot should not report more pages")
	}
	t.Logf("catalog hot: %d items, first=%q", len(hot), hot[0].Title)
	if seriesID == "" {
		seriesID = hot[0].SourceID
	}
	drama, chapters, err := d.fetchHGTVMirrorDetail(ctx, seriesID)
	if err != nil {
		t.Fatalf("detail %s: %v", seriesID, err)
	}
	if len(chapters) == 0 {
		t.Fatal("detail returned no chapters")
	}
	if drama.Source != sourceHGTVMirror || drama.ChannelName != "红果镜像" {
		t.Fatalf("detail drama source %q channel %q", drama.Source, drama.ChannelName)
	}
	if chapters[0].Source != sourceHGTVMirror || !strings.HasPrefix(chapters[0].VideoURL, "hgtvmirror://") {
		t.Fatalf("first chapter %+v", chapters[0])
	}
	t.Logf("detail %s %q: %d chapters", seriesID, drama.Title, len(chapters))
	results, err := d.searchHGTVMirrorDramas(ctx, "王妈")
	if err != nil || len(results) == 0 {
		t.Fatalf("search 王妈: %d results, err=%v", len(results), err)
	}
	if results[0].Source != sourceHGTVMirror {
		t.Fatalf("search first result source %q", results[0].Source)
	}
	t.Logf("search 王妈: %d results, first=%q", len(results), results[0].Title)
	task := Task{DramaID: providerDramaID(sourceHGTVMirror, seriesID), Chapter: chapters[0]}
	media, err := d.resolveHGTVMirrorMedia(ctx, task)
	if err != nil {
		t.Fatalf("resolve %s ep1: %v", seriesID, err)
	}
	if !strings.HasPrefix(media.URL, "https://") {
		t.Fatalf("resolve URL %q", media.URL)
	}
	if len(media.Variants) < 2 {
		t.Fatalf("resolve: %d lines, want fallback + static", len(media.Variants))
	}
	static := false
	for _, variant := range media.Variants {
		if strings.HasSuffix(variant.URL, "/360p.mp4") {
			static = true
		}
	}
	if !static {
		t.Fatal("resolve: variants lack static 360p line")
	}
	t.Logf("resolve %s ep1: %d lines, first=%q", seriesID, len(media.Variants), media.URL)
}
