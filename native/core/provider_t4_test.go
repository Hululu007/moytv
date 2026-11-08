package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func t4FixtureServer(t *testing.T, seen *[]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		*seen = append(*seen, r.URL.RawQuery)
		if query.Get("sites") != "all" || query.Get("timeout") != "5" {
			t.Errorf("config query lost: %q", r.URL.RawQuery)
		}
		write := func(body string) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		}
		switch {
		case query.Get("t") != "":
			page := query.Get("pg")
			if page == "" {
				page = "1"
			}
			write(`{"page":` + page + `,"pagecount":3,"limit":30,"total":90,"list":[` +
				`{"vod_id":"msearch:movie__` + page + `01","vod_name":"分类剧` + page + `","vod_pic":"https://pic.test/` + page + `.jpg","vod_remarks":"9.0"},` +
				`{"vod_id":"msearch:movie__` + page + `02","vod_name":"分类剧二","vod_pic":"https://pic.test/x.jpg","vod_remarks":"8.0"}]}`)
		case query.Get("wd") != "":
			write(`{"list":[` +
				`{"vod_id":"sitea$11","vod_name":"搜索结果A","vod_pic":"https://pic.test/a.jpg","vod_remarks":"线路A"},` +
				`{"vod_id":"siteb$22","vod_name":"搜索结果B","vod_pic":"https://pic.test/b.jpg","vod_remarks":"线路B"}]}`)
		case query.Get("ac") != "":
			if query.Get("ids") != "sitea$11" && !strings.HasPrefix(query.Get("ids"), "msearch:") {
				write(`{"list":[]}`)
				return
			}
			if strings.HasPrefix(query.Get("ids"), "msearch:") {
				write(`{"list":[{"vod_id":"` + query.Get("ids") + `","vod_name":"豆瓣条目","vod_pic":"https://pic.test/d.jpg",` +
					`"vod_play_from":"本页面数据来自豆瓣$$$观看影片请点击上方快速搜索$$$或升级至最新版软件","vod_play_url":"$$$"}]}`)
				return
			}
			write(`{"list":[{"vod_id":"sitea$11","vod_name":"测试剧","vod_pic":"https://pic.test/c.jpg",` +
				`"type_name":"短剧","vod_year":"2026","vod_remarks":"已完结","vod_actor":"演员甲","vod_director":"导演乙","vod_content":"剧情简介",` +
				`"vod_play_from":"线路A$$$线路B","vod_play_url":"第1集$sitea___11-0-1#第2集$sitea___11-0-2$$$第1集$sitea___11-1-1#第2集$sitea___11-1-2"}]}`)
		case query.Get("play") != "":
			switch query.Get("play") {
			case "sitea___11-0-1":
				header, _ := json.Marshal(map[string]string{"User-Agent": "FixtureUA/1.0", "Referer": "https://origin.test/"})
				raw, _ := json.Marshal(map[string]any{"header": string(header), "parse": 0, "playUrl": "", "url": "https://media.test/a.m3u8"})
				write(string(raw))
			case "sitea___11-1-1":
				raw, _ := json.Marshal(map[string]any{"header": "{}", "parse": 1, "playUrl": "https://jx.test/?url=", "url": "https://media.test/b"})
				write(string(raw))
			case "sitea___11-9-9":
				raw, _ := json.Marshal(map[string]any{"header": "{}", "parse": 1, "playUrl": "", "url": "https://media.test/c"})
				write(string(raw))
			default:
				write(`{}`)
			}
		default:
			write(`{"class":[{"type_id":"movie","type_name":"电影"},{"type_id":"tv","type_name":"电视剧"},{"type_id":"interests","type_name":"我的"}],` +
				`"filters":{},"list":[` +
				`{"vod_id":"","vod_name":"无编号热榜","vod_pic":"https://pic.test/h0.jpg","vod_remarks":"热"},` +
				`{"vod_id":"msearch:movie__100","vod_name":"热榜一","vod_pic":"https://pic.test/h1.jpg","vod_remarks":"9.5"},` +
				`{"vod_id":"sitea$7","vod_name":"热榜二","vod_pic":"https://pic.test/h2.jpg","vod_remarks":"9.0"}]}`)
		}
	}))
}

func setupT4Fixture(t *testing.T) (string, *Downloader) {
	t.Helper()
	var seen []string
	server := t4FixtureServer(t, &seen)
	t.Cleanup(server.Close)
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	record, err := engine.customRegistry.add("T4Fixture", server.URL+"/vod?sites=all&timeout=5", "", "t4")
	if err != nil {
		t.Fatal(err)
	}
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	})
	return record.ID, &Downloader{client: server.Client(), limiter: newRequestLimiter(10, 0)}
}

func TestT4RequestURLPreservesConfigQuery(t *testing.T) {
	address, err := t4RequestURL("https://t4.example.test/vod?sites=all&timeout=5", map[string]string{"t": "movie", "pg": "2"})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"sites=all", "timeout=5", "t=movie", "pg=2"} {
		if !strings.Contains(address, want) {
			t.Fatalf("request url %q misses %q", address, want)
		}
	}
	if _, err := t4RequestURL("not a url", nil); err == nil {
		t.Fatal("invalid api url must fail")
	}
}

func TestT4ValidationAllowsQueryOnlyForT4(t *testing.T) {
	registry := newCustomMaccmsRegistry(t.TempDir())
	if _, err := registry.add("T4站", "https://t4.example.test/vod?sites=all&timeout=5", "", "t4"); err != nil {
		t.Fatalf("t4 url with query must be accepted: %v", err)
	}
	if _, err := registry.add("普通站", "https://api.example.test/vod?ac=list", "", ""); err == nil {
		t.Fatal("non-t4 url with query must be rejected")
	}
	if _, err := registry.add("JSON站", "https://api.example.test/vod?ac=list", "", "json"); err == nil {
		t.Fatal("json url with query must be rejected")
	}
	if _, err := registry.add("T4锚点", "https://t4.example.test/vod?sites=all#frag", "", "t4"); err == nil {
		t.Fatal("t4 url with fragment must still be rejected")
	}
}

func TestT4PlayTokenRoundTrip(t *testing.T) {
	token := t4PlayToken("线路A", "sitea___11-0-1")
	flag, playID, ok := t4ParsePlayToken(token)
	if !ok || flag != "线路A" || playID != "sitea___11-0-1" {
		t.Fatalf("token round trip failed: %q %q %v", flag, playID, ok)
	}
	for _, bad := range []string{"sitea___11-0-1", "t4play:onlyflag", "t4play:\x1fonlyid", ""} {
		if _, _, ok := t4ParsePlayToken(bad); ok {
			t.Fatalf("bad token %q must not parse", bad)
		}
	}
}

func TestT4CategoriesSkipInterests(t *testing.T) {
	source, d := setupT4Fixture(t)
	categories, err := t4Categories(context.Background(), d, source)
	if err != nil {
		t.Fatal(err)
	}
	if len(categories) != 2 || categories[0].ID != "movie" || categories[0].Name != "电影" || categories[1].ID != "tv" {
		t.Fatalf("unexpected categories: %+v", categories)
	}
}

func TestT4CatalogHomeSkipsEmptyIDs(t *testing.T) {
	source, d := setupT4Fixture(t)
	items, hasMore, err := t4CatalogPage(context.Background(), d, source, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	if hasMore {
		t.Fatal("home catalog must not claim more pages")
	}
	if len(items) != 2 || items[0].SourceID != "msearch:movie__100" || items[1].SourceID != "sitea$7" {
		t.Fatalf("unexpected home items: %+v", items)
	}
	if items, _, err := t4CatalogPage(context.Background(), d, source, 2, ""); err != nil || len(items) != 0 {
		t.Fatalf("home page 2 must be empty: %v %+v", err, items)
	}
}

func TestT4CategoryPaging(t *testing.T) {
	source, d := setupT4Fixture(t)
	items, hasMore, err := t4CatalogPage(context.Background(), d, source, 1, "movie")
	if err != nil || !hasMore || len(items) != 2 {
		t.Fatalf("page 1 wrong: err=%v hasMore=%v items=%d", err, hasMore, len(items))
	}
	if items[0].SourceID != "msearch:movie__101" {
		t.Fatalf("unexpected first item: %+v", items[0])
	}
	if _, hasMore, err := t4CatalogPage(context.Background(), d, source, 3, "movie"); err != nil || hasMore {
		t.Fatalf("page 3 must be last: err=%v hasMore=%v", err, hasMore)
	}
}

func TestT4SearchAndDetailRoutes(t *testing.T) {
	source, d := setupT4Fixture(t)
	ctx := context.Background()
	items, err := t4Search(ctx, d, source, "测试")
	if err != nil || len(items) != 2 || items[0].SourceID != "sitea$11" {
		t.Fatalf("search wrong: err=%v %+v", err, items)
	}
	drama, chapters, err := t4Detail(ctx, d, source, "sitea$11")
	if err != nil {
		t.Fatal(err)
	}
	if drama.Title != "测试剧" || drama.Category != "短剧" || len(chapters) != 2 {
		t.Fatalf("detail wrong: %+v chapters=%d", drama, len(chapters))
	}
	if chapters[0].VideoURL != t4PlayToken("线路A", "sitea___11-0-1") {
		t.Fatalf("primary token wrong: %q", chapters[0].VideoURL)
	}
	if len(chapters[0].Routes) != 1 || chapters[0].Routes[0] != t4PlayToken("线路B", "sitea___11-1-1") {
		t.Fatalf("route tokens wrong: %q", chapters[0].Routes)
	}
	if chapters[1].VideoURL != t4PlayToken("线路A", "sitea___11-0-2") || chapters[1].Routes[0] != t4PlayToken("线路B", "sitea___11-1-2") {
		t.Fatalf("second episode tokens wrong: %q %q", chapters[1].VideoURL, chapters[1].Routes)
	}
	douban, doubanChapters, err := t4Detail(ctx, d, source, "msearch:movie__100")
	if err != nil || douban.Title != "豆瓣条目" || len(doubanChapters) != 0 {
		t.Fatalf("douban detail must load metadata without chapters: err=%v %+v chapters=%d", err, douban, len(doubanChapters))
	}
	if _, _, err := t4Detail(ctx, d, source, "sitea$missing"); err == nil {
		t.Fatal("unknown detail id must fail")
	}
}

func TestT4PlayVariants(t *testing.T) {
	source, d := setupT4Fixture(t)
	ctx := context.Background()
	apiURL := t4APIURL(source)
	direct, err := d.t4PlayOnce(ctx, apiURL, "线路A", "sitea___11-0-1")
	if err != nil || direct.URL != "https://media.test/a.m3u8" || direct.Referer != "https://origin.test/" || direct.NeedsParse {
		t.Fatalf("direct play wrong: %+v err=%v", direct, err)
	}
	if direct.credentials == nil || direct.credentials.userAgent != "FixtureUA/1.0" {
		t.Fatalf("play header user agent lost: %+v", direct.credentials)
	}
	prefixed, err := d.t4PlayOnce(ctx, apiURL, "线路B", "sitea___11-1-1")
	if err != nil || prefixed.URL != "https://jx.test/?url=https://media.test/b" || prefixed.NeedsParse {
		t.Fatalf("prefixed play wrong: %+v err=%v", prefixed, err)
	}
	needParse, err := d.t4PlayOnce(ctx, apiURL, "线路C", "sitea___11-9-9")
	if err != nil || !needParse.NeedsParse || needParse.URL != "https://media.test/c" {
		t.Fatalf("parse-flagged play wrong: %+v err=%v", needParse, err)
	}
	if _, err := d.t4PlayOnce(ctx, apiURL, "线路X", "sitea___11-0-9"); err == nil {
		t.Fatal("empty play response must fail")
	}
}

func TestT4ResolveMediaFallsThroughLines(t *testing.T) {
	source, d := setupT4Fixture(t)
	chapter := Chapter{
		Source:   source,
		Title:    "第1集",
		VideoURL: t4PlayToken("线路A", "sitea___11-0-1"),
		Routes:   []string{t4PlayToken("线路B", "sitea___11-1-1")},
	}
	media, err := d.t4ResolveMedia(context.Background(), source, Task{DramaID: source + ":sitea$11", Chapter: chapter})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.test/a.m3u8" || len(media.Variants) != 1 || media.Variants[0].URL != "https://jx.test/?url=https://media.test/b" {
		t.Fatalf("resolve variants wrong: %+v", media)
	}
	broken := Chapter{Source: source, VideoURL: "t4play:线路X\x1fmissing", Routes: []string{t4PlayToken("线路A", "sitea___11-0-1")}}
	fallback, err := d.t4ResolveMedia(context.Background(), source, Task{DramaID: source + ":sitea$11", Chapter: broken})
	if err != nil || fallback.URL != "https://media.test/a.m3u8" {
		t.Fatalf("broken primary must fall through to variant: %+v err=%v", fallback, err)
	}
	if _, err := d.t4ResolveMedia(context.Background(), source, Task{Chapter: Chapter{VideoURL: "https://media.test/a.m3u8"}}); err == nil {
		t.Fatal("non-token chapter must fail t4 resolve")
	}
}
