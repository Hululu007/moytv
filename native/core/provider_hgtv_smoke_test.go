package core

import (
	"context"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHGTVCategoryNormalization(t *testing.T) {
	cases := map[string]string{
		"": "home", "全部": "home", "all": "home",
		"real": "real", "short_play": "real", "真人剧": "real",
		"comic": "comic", "comic_series": "comic", "漫剧": "comic",
		"ai": "ai", "ai_series": "ai", "AI剧": "ai",
		"latest": "latest", "online_time": "latest", "最新上架": "latest",
	}
	for input, want := range cases {
		cat, ok := hgtvCategoryFor(input)
		if !ok || cat.id != want {
			t.Fatalf("category %q -> %v %q, want %q", input, ok, cat.id, want)
		}
	}
	if _, ok := hgtvCategoryFor("no-such-category"); ok {
		t.Fatal("unknown category should not normalize")
	}
}

func TestHGTVStillsFromDetail(t *testing.T) {
	detail := map[string]any{
		"video_list": []any{
			map[string]any{"episode_cover": "https://example.test/still1.image"},
			map[string]any{"episode_cover": "https://example.test/still1.image"},
			map[string]any{"episode_cover": "https://example.test/still2.image"},
			map[string]any{"cover": "https://example.test/still3.image"},
		},
	}
	backdrop, stills := hgtvStillsFromDetail(detail, "https://example.test/cover.image", 12)
	if backdrop != "https://example.test/still1.image" {
		t.Fatalf("backdrop %q", backdrop)
	}
	if len(stills) != 3 {
		t.Fatalf("stills %d, want 3", len(stills))
	}
}

func TestLandpageFilterGroups(t *testing.T) {
	data := map[string]any{
		"selector_rows": []any{
			map[string]any{
				"type": "genre", "row_name": "全部体裁",
				"items": []any{
					map[string]any{"selector_item_id": "cate_1", "show_name": "悬疑"},
				},
			},
			map[string]any{
				"type": "category_dim_theme", "row_name": "全部主题",
				"items": []any{
					map[string]any{"selector_item_id": "cate_19", "show_name": "系统"},
					map[string]any{"selector_item_id": "", "show_name": "空编号"},
					map[string]any{"selector_item_id": "cate_20", "show_name": ""},
				},
			},
			map[string]any{
				"type": "sort", "row_name": "全部推荐",
				"items": []any{
					map[string]any{"selector_item_id": "hot_score", "show_name": "最热"},
				},
			},
			map[string]any{
				"type": "empty_group", "row_name": "全部空",
				"items": []any{},
			},
			map[string]any{
				"type": "", "row_name": "全部无名",
				"items": []any{
					map[string]any{"selector_item_id": "x", "show_name": "无名"},
				},
			},
		},
	}
	groups := landpageFilterGroups(data)
	if len(groups) != 2 {
		t.Fatalf("groups %d, want 2", len(groups))
	}
	theme := groups[0]
	if theme.Key != "category_dim_theme" || theme.Name != "主题" {
		t.Fatalf("theme group %+v", theme)
	}
	if len(theme.Options) != 1 || theme.Options[0].ID != "cate_19" || theme.Options[0].Name != "系统" {
		t.Fatalf("theme options %+v", theme.Options)
	}
	sortGroup := groups[1]
	if sortGroup.Key != "sort" || sortGroup.Name != "排序" {
		t.Fatalf("sort group %+v", sortGroup)
	}
	if len(sortGroup.Options) != 1 || sortGroup.Options[0].ID != "hot_score" {
		t.Fatalf("sort options %+v", sortGroup.Options)
	}
}

func TestHGTVLiveSmoke(t *testing.T) {
	if os.Getenv("HGTV_LIVE_SMOKE") != "1" {
		t.Skip("live smoke requires HGTV_LIVE_SMOKE=1")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	d := &Downloader{cfg: Config{dataDir: t.TempDir(), Retries: 2, PageSize: 30, MaxPagesPerSort: 1},
		client: &http.Client{Transport: http.DefaultTransport}, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}}
	coverOf := func(dr Drama) string {
		for _, v := range []any{dr.Cover, dr.CoverURL} {
			if s, ok := v.(string); ok && strings.HasPrefix(s, "https://") {
				return s
			}
		}
		return ""
	}
	for _, cat := range []string{"home", "real", "comic", "ai", "latest"} {
		items, hasMore, groups, err := d.fetchHGTVCatalogPage(ctx, cat, 1, nil)
		if err != nil {
			t.Fatalf("catalog %s page 1: %v", cat, err)
		}
		if cat == "comic" && len(groups) == 0 {
			t.Fatal("catalog comic page 1: no filter groups")
		}
		if len(items) < 20 {
			t.Fatalf("catalog %s page 1: %d items, want at least 20", cat, len(items))
		}
		if coverOf(items[0]) == "" {
			t.Fatalf("catalog %s first item has no cover URL", cat)
		}
		t.Logf("catalog %s p1: %d items, hasMore=%v, first=%q", cat, len(items), hasMore, items[0].Title)
		page2, _, _, err := d.fetchHGTVCatalogPage(ctx, cat, 2, nil)
		if err != nil {
			t.Fatalf("catalog %s page 2: %v", cat, err)
		}
		seen := map[string]bool{}
		for _, it := range items {
			seen[it.SourceID] = true
		}
		overlap := 0
		for _, it := range page2 {
			if seen[it.SourceID] {
				overlap++
			}
		}
		if overlap != 0 {
			t.Fatalf("catalog %s page 2 overlaps page 1: %d", cat, overlap)
		}
		t.Logf("catalog %s p2: %d items, overlap=%d", cat, len(page2), overlap)
	}
	all, _, _, err := d.fetchHGTVCatalogPage(ctx, "全部", 1, nil)
	if err != nil || len(all) < 20 {
		t.Fatalf("catalog 全部: %d items, err=%v", len(all), err)
	}
	home, _, _, err := d.fetchHGTVCatalogPage(ctx, "home", 1, nil)
	if err != nil || len(home) < 20 {
		t.Fatalf("catalog home: %d items, err=%v", len(home), err)
	}
	seriesID := home[0].SourceID
	drama, chapters, err := d.fetchHGTVDetail(ctx, seriesID)
	if err != nil {
		t.Fatalf("detail %s: %v", seriesID, err)
	}
	if len(chapters) == 0 {
		t.Fatal("detail returned no chapters")
	}
	if drama.Backdrop == "" || len(drama.Stills) == 0 {
		t.Fatalf("detail stills missing: backdrop=%q stills=%d", drama.Backdrop, len(drama.Stills))
	}
	t.Logf("detail %s %q: %d chapters, backdrop set, stills=%d", seriesID, drama.Title, len(chapters), len(drama.Stills))
	results, err := d.searchHGTVDramas(ctx, "王妈")
	if err != nil || len(results) == 0 {
		t.Fatalf("search 王妈: %d results, err=%v", len(results), err)
	}
	t.Logf("search 王妈: %d results, first=%q", len(results), results[0].Title)
	task := Task{DramaID: providerDramaID(sourceHGTV, seriesID), Chapter: chapters[0]}
	media, err := d.resolveHGTVMedia(ctx, task)
	if err != nil {
		t.Fatalf("resolve %s ep1: %v", seriesID, err)
	}
	if len(media.CENCKey) != 16 || !strings.HasPrefix(media.URL, "https://") {
		t.Fatalf("resolve: CENCKey=%d bytes, URL=%q", len(media.CENCKey), media.URL)
	}
	if len(media.Variants) == 0 {
		t.Fatal("resolve: no variants, want multi-line")
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
	t.Logf("resolve %s ep1: CENCKey=16 bytes, URL host set, quality=%d", seriesID, media.Quality)
}
