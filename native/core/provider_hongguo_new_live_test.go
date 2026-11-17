package core

// 红果(新)全链活测复验（2026-11-17，手机报首页与搜索全空后重验）。
//
// 只在 HGNEW_LIVE=1 时跑：HGNEW_LIVE=1 go test ./core/ -run TestHongguoNewLiveReverify -v -count=1 -timeout 20m
// 顺序发请求，绝不并行；出口走环境变量代理（HTTP_PROXY/HTTPS_PROXY）。
// 空结果只记现象、不判失败——超时/限流是证据，不是站死结论；每路结果以 t.Log 为准。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

func hongguoNewReverifyEngine(t *testing.T) *nativeEngine {
	t.Helper()
	if os.Getenv("HGNEW_LIVE") != "1" {
		t.Skip("live reverify requires HGNEW_LIVE=1")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	return engine
}

func hongguoNewReverifyPause() { time.Sleep(time.Second) }

func TestHongguoNewLiveReverify(t *testing.T) {
	engine := hongguoNewReverifyEngine(t)
	d := engine.downloader
	ctx := context.Background()

	// 1. 首页：此前 bug 点（video_list 当 map 取恒 0 条），现应返回条目。
	home, err := d.fetchHongguoNewHome(ctx)
	if err != nil {
		t.Logf("ROUTE home: ERROR %v", err)
	} else {
		t.Logf("ROUTE home: items=%d", len(home))
		for i, item := range home {
			if i >= 3 {
				break
			}
			t.Logf("  home[%d] id=%s title=%q cover=%v remark=%q", i, item.SourceID, item.DisplayTitle(), item.Cover != "", item.Remark)
		}
	}
	hongguoNewReverifyPause()

	// 1b. 首页经目录入口：主题筛选选项数（此前 0 选项 bug 已修）。
	_, _, groups, err := d.fetchHongguoNewCatalogPage(ctx, "", 1, nil)
	topicID := ""
	if err != nil {
		t.Logf("ROUTE home-catalog: ERROR %v", err)
	} else {
		for _, group := range groups {
			t.Logf("ROUTE home-catalog: filter %q options=%d", group.Key, len(group.Options))
			for i, opt := range group.Options {
				if i >= 3 {
					break
				}
				t.Logf("  option[%d] %s=%s", i, opt.Name, opt.ID)
			}
			for _, opt := range group.Options {
				if opt.ID != "" {
					topicID = opt.ID
					break
				}
			}
		}
	}
	hongguoNewReverifyPause()

	// 2. 分类目录：4 个一级分类首页 + real-drama 第 2 页 + 主题筛选。
	categories := []string{"c:real-drama", "c:comic-drama", "c:ai-drama", "c:comic"}
	for _, category := range categories {
		items, hasMore, _, err := d.fetchHongguoNewCatalogPage(ctx, category, 1, nil)
		if err != nil {
			t.Logf("ROUTE catalog %s p1: ERROR %v", category, err)
		} else {
			first := ""
			if len(items) > 0 {
				first = items[0].DisplayTitle()
			}
			t.Logf("ROUTE catalog %s p1: items=%d hasMore=%v first=%q", category, len(items), hasMore, first)
		}
		hongguoNewReverifyPause()
	}
	items, hasMore, _, err := d.fetchHongguoNewCatalogPage(ctx, "c:real-drama", 2, nil)
	if err != nil {
		t.Logf("ROUTE catalog c:real-drama p2: ERROR %v", err)
	} else {
		first := ""
		if len(items) > 0 {
			first = items[0].DisplayTitle()
		}
		t.Logf("ROUTE catalog c:real-drama p2: items=%d hasMore=%v first=%q", len(items), hasMore, first)
	}
	hongguoNewReverifyPause()
	if topicID != "" {
		items, _, _, err := d.fetchHongguoNewCatalogPage(ctx, "c:real-drama", 1, map[string]string{"topic": topicID})
		if err != nil {
			t.Logf("ROUTE catalog topic=%s: ERROR %v", topicID, err)
		} else {
			t.Logf("ROUTE catalog topic=%s: items=%d", topicID, len(items))
		}
		hongguoNewReverifyPause()
	} else {
		t.Logf("ROUTE catalog topic: SKIPPED (no topic options)")
	}

	// 3. 榜单：4 个榜 + hot-drama 第 2 页；顺手挑一部 80-120 集的剧供详情/取流。
	detailSeriesID := ""
	rankFirst := ""
	for _, category := range []string{"r:hot-drama", "r:hot-real-drama", "r:hot-comic-drama", "r:hot-ai-drama"} {
		items, pages, err := d.fetchHongguoNewRank(ctx, strings.TrimPrefix(category, "r:"), 1)
		if err != nil {
			t.Logf("ROUTE rank %s p1: ERROR %v", category, err)
		} else {
			first := ""
			if len(items) > 0 {
				first = items[0].DisplayTitle()
			}
			t.Logf("ROUTE rank %s p1: items=%d pages=%d first=%q", category, len(items), pages, first)
			for _, item := range items {
				if rankFirst == "" {
					rankFirst = item.SourceID
				}
				if detailSeriesID == "" {
					if n, convErr := strconv.Atoi(fmt.Sprint(item.TotalEpisode)); convErr == nil && n >= 80 && n <= 120 {
						detailSeriesID = item.SourceID
						t.Logf("  detail pick: id=%s title=%q episodes=%d", item.SourceID, item.DisplayTitle(), n)
					}
				}
			}
		}
		hongguoNewReverifyPause()
	}
	items, pages, err := d.fetchHongguoNewRank(ctx, "hot-drama", 2)
	if err != nil {
		t.Logf("ROUTE rank r:hot-drama p2: ERROR %v", err)
	} else {
		t.Logf("ROUTE rank r:hot-drama p2: items=%d pages=%d", len(items), pages)
	}
	hongguoNewReverifyPause()

	// 4. 搜索：两个真实词 + 原始响应结构探针（接口/参数/解析是否与当前站方一致）。
	for _, kw := range []string{"重生", "总裁"} {
		entry, err := d.fetchHongguoNewSearchAPI(ctx, kw, 1)
		if err != nil {
			t.Logf("ROUTE search %q: ERROR %v", kw, err)
		} else {
			t.Logf("ROUTE search %q: items=%d total=%d limited=%v", kw, len(entry.Dramas), entry.Total, entry.Limited)
			for i, item := range entry.Dramas {
				if i >= 3 {
					break
				}
				t.Logf("  search[%d] id=%s title=%q cover=%v", i, item.SourceID, item.DisplayTitle(), item.Cover != "")
			}
		}
		hongguoNewReverifyPause()
	}
	rawBody, err := d.fetchProviderText(ctx, hongguoBaseURL+"/api/search/result?query=%E9%87%8D%E7%94%9F&page=1", hongguoBaseURL+"/")
	if err != nil {
		t.Logf("ROUTE search-raw: ERROR %v", err)
	} else {
		t.Logf("ROUTE search-raw: bodyBytes=%d", len(rawBody))
		var decoded map[string]any
		dec := json.NewDecoder(strings.NewReader(rawBody))
		dec.UseNumber()
		if decErr := dec.Decode(&decoded); decErr != nil {
			head := rawBody
			if len(head) > 200 {
				head = head[:200]
			}
			t.Logf("  raw decode FAIL: %v head=%q", decErr, head)
		} else {
			keys := make([]string, 0, len(decoded))
			for k := range decoded {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			rows := anyList(decoded["searchList"])
			t.Logf("  raw topKeys=%v searchList=%d totalCount=%s", keys, len(rows), mapString(decoded, "totalCount"))
			if len(rows) > 0 {
				row, _ := rows[0].(map[string]any)
				rowKeys := make([]string, 0, len(row))
				for k := range row {
					rowKeys = append(rowKeys, k)
				}
				sort.Strings(rowKeys)
				t.Logf("  raw row0 keys=%v", rowKeys)
				if vd, ok := row["video_data"].(map[string]any); ok {
					vdKeys := make([]string, 0, len(vd))
					for k := range vd {
						vdKeys = append(vdKeys, k)
					}
					sort.Strings(vdKeys)
					t.Logf("  raw row0.video_data keys=%v id=%q title=%q", vdKeys, mapString(vd, "series_id", "series_id_str"), mapString(vd, "series_title", "series_name", "title"))
				} else {
					t.Logf("  raw row0 direct id=%q title=%q keyword=%q", mapString(row, "series_id", "series_id_str"), mapString(row, "series_title", "series_name", "title", "name"), mapString(row, "keyword"))
				}
			}
		}
	}
	hongguoNewReverifyPause()

	// 5. 详情：取挑中的剧（无则用榜单首条，再无则用已知 id）。
	if detailSeriesID == "" {
		detailSeriesID = rankFirst
	}
	if detailSeriesID == "" {
		detailSeriesID = "7704532495357725721"
	}
	drama, chapters, err := d.fetchHongguoNewDetail(ctx, detailSeriesID)
	var firstVid string
	if err != nil {
		t.Logf("ROUTE detail %s: ERROR %v", detailSeriesID, err)
	} else {
		t.Logf("ROUTE detail %s: title=%q cover=%v intro=%dchars remark=%q chapters=%d totalEpisode=%q", detailSeriesID, drama.DisplayTitle(), drama.Cover != "", len(drama.Intro), drama.Remark, len(chapters), drama.TotalEpisode)
		if len(chapters) > 0 {
			firstVid = strings.TrimPrefix(chapters[0].VideoURL, hongguoNewCENCURLPrefix)
			t.Logf("  chapter[0]=%q urlPrefix=%v vid=%s chapter[last]=%q", chapters[0].Title, strings.HasPrefix(chapters[0].VideoURL, hongguoNewCENCURLPrefix), firstVid, chapters[len(chapters)-1].Title)
		}
	}
	hongguoNewReverifyPause()

	// 6. 取流：新槽分发全链 + Range 206 验证 + App 模型五档显式尝试。
	if firstVid != "" && len(chapters) > 0 {
		task := Task{DramaID: drama.ID, Chapter: chapters[0]}
		media, err := d.resolveHongguoNewMedia(ctx, task)
		if err != nil {
			t.Logf("ROUTE media %s/%s: ERROR %v", detailSeriesID, firstVid, err)
		} else {
			qualities := []int{}
			for _, v := range media.Variants {
				qualities = append(qualities, v.Quality)
			}
			t.Logf("ROUTE media %s/%s: url=%s variants=%d qualities=%v duration=%s", detailSeriesID, firstVid, hongguoNewReverifyURLHost(media.URL), len(media.Variants), qualities, media.Duration)
			status, ftyp, ctype := hongguoNewReverifyRange(ctx, d, media.URL, media.Referer)
			t.Logf("  range-check: status=%s ftyp=%v contentType=%q", status, ftyp, ctype)
		}
		hongguoNewReverifyPause()
		appMedia, appErr := d.resolveHongguoAppMedia(ctx, firstVid)
		if appErr != nil {
			t.Logf("ROUTE app-model %s: ERROR %v", firstVid, appErr)
		} else {
			qualities := []int{appMedia.Quality}
			for _, v := range appMedia.Variants {
				qualities = append(qualities, v.Quality)
			}
			t.Logf("ROUTE app-model %s: OK variants=%d qualities=%v url=%s", firstVid, len(appMedia.Variants), qualities, hongguoNewReverifyURLHost(appMedia.URL))
		}
		hongguoNewReverifyPause()
	} else {
		t.Logf("ROUTE media: SKIPPED (no chapters)")
	}

	// 7. 头条精选列表（t:jx 分类）。
	ttItems, _, _, err := d.fetchHongguoNewCatalogPage(ctx, "t:jx", 1, nil)
	if err != nil {
		t.Logf("ROUTE toutiao-list: ERROR %v", err)
	} else {
		first := ""
		if len(ttItems) > 0 {
			first = ttItems[0].DisplayTitle()
		}
		t.Logf("ROUTE toutiao-list: items=%d first=%q", len(ttItems), first)
	}
	hongguoNewReverifyPause()

	// 8. 自检诊断分类：6 项逐行。
	diagItems, err := d.hongguoNewDiagItems(ctx)
	if err != nil {
		t.Logf("ROUTE diag: ERROR %v", err)
	} else {
		t.Logf("ROUTE diag: items=%d", len(diagItems))
		for _, item := range diagItems {
			t.Logf("  diag: %s", item.DisplayTitle())
		}
	}
}

func hongguoNewReverifyURLHost(rawURL string) string {
	if rawURL == "" {
		return "(empty)"
	}
	if idx := strings.Index(rawURL, "://"); idx >= 0 {
		rest := rawURL[idx+3:]
		if slash := strings.Index(rest, "/"); slash >= 0 {
			return rawURL[:idx+3] + rest[:slash] + "/..."
		}
		return rawURL
	}
	return rawURL
}

func hongguoNewReverifyRange(ctx context.Context, d *Downloader, rawURL, referer string) (string, bool, string) {
	if !isProviderHTTPMediaURL(rawURL) {
		return "no-http-url", false, ""
	}
	callCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(callCtx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "req-fail", false, ""
	}
	req.Header.Set("Range", "bytes=0-63")
	req.Header.Set("User-Agent", hongguoAppUserAgent)
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	client := d.client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "FAIL:" + publicError(err).Error(), false, ""
	}
	defer resp.Body.Close()
	head, _ := io.ReadAll(io.LimitReader(resp.Body, 8))
	return strconv.Itoa(resp.StatusCode), len(head) >= 8 && string(head[4:8]) == "ftyp", resp.Header.Get("Content-Type")
}
