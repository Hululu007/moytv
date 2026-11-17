package core

// 番茄槽全链活测（2026-11-17 落树时跑通）。
//
// 只在 FANQIE_LIVE=1 时跑：
//   FANQIE_LIVE=1 go test ./core/ -run TestFanqieLive -v -count=1 -timeout 20m
// 顺序发请求，绝不并行；出口走 VM 代理（内存换 d.client，树内直连配置不动）。
// 发现链（plan/change/详情/搜索）严格断言——探针两次实测均通；
// 取流只记现象、不判失败——本机出口 video_model 空回包是已知限流，手机终验为准。

import (
	"context"
	"crypto/tls"
	"io"
	"net/http"
	"net/url"
	"os"
	"testing"
	"time"
)

func fanqieLiveEngine(t *testing.T) *nativeEngine {
	t.Helper()
	if os.Getenv("FANQIE_LIVE") != "1" {
		t.Skip("live fanqie test requires FANQIE_LIVE=1")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(engine.downloads.close)
	proxyURL, err := url.Parse("http://hatch-egress-proxy:3128")
	if err != nil {
		t.Fatal(err)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: systemCertPoolWithBundle()}
	transport.Proxy = http.ProxyURL(proxyURL)
	transport.ResponseHeaderTimeout = 20 * time.Second
	engine.downloader.client = &http.Client{Transport: transport, Timeout: 45 * time.Second}
	return engine
}

func fanqieLivePause() { time.Sleep(2 * time.Second) }

func TestFanqieLive(t *testing.T) {
	engine := fanqieLiveEngine(t)
	d := engine.downloader
	ctx := context.Background()

	// 1. 首屏：plan 取种 + change 合并。
	page1, more1, filters1, err := d.fetchFanqieCatalogPage(ctx, "", 1)
	if err != nil {
		t.Fatalf("ROUTE fanqie-p1: ERROR %v", err)
	}
	t.Logf("ROUTE fanqie-p1: items=%d hasMore=%v filters=%d", len(page1), more1, len(filters1))
	if len(page1) == 0 {
		t.Fatal("ROUTE fanqie-p1: 0 items")
	}
	for i, item := range page1 {
		if i >= 3 {
			break
		}
		t.Logf("  p1[%d] id=%s title=%q remark=%q", i, item.ID, item.DisplayTitle(), item.Remark)
	}
	if page1[0].Source != sourceFanqie {
		t.Fatalf("ROUTE fanqie-p1: source=%q, want fanqie", page1[0].Source)
	}
	fanqieLivePause()

	// 2. 翻页：游标续 change，offset 取上页 next_offset。
	page2, more2, _, err := d.fetchFanqieCatalogPage(ctx, "", 2)
	if err != nil {
		t.Fatalf("ROUTE fanqie-p2: ERROR %v", err)
	}
	t.Logf("ROUTE fanqie-p2: items=%d hasMore=%v", len(page2), more2)
	if len(page2) == 0 {
		t.Fatal("ROUTE fanqie-p2: 0 items")
	}
	for i, item := range page2 {
		if i >= 3 {
			break
		}
		t.Logf("  p2[%d] id=%s title=%q", i, item.ID, item.DisplayTitle())
	}
	if page2[0].ID == page1[0].ID {
		t.Fatalf("ROUTE fanqie-p2: 首条与首屏重复 %q", page2[0].ID)
	}
	fanqieLivePause()

	// 3. 详情：SSR 详情 + 分集表改挂番茄槽。
	drama, chapters, err := d.fetchFanqieDetail(ctx, page1[0].SourceID)
	if err != nil {
		t.Fatalf("ROUTE fanqie-detail: ERROR %v", err)
	}
	t.Logf("ROUTE fanqie-detail: title=%q chapters=%d first=%q", drama.DisplayTitle(), len(chapters), chapters[0].VideoURL)
	if len(chapters) == 0 {
		t.Fatal("ROUTE fanqie-detail: 0 chapters")
	}
	if chapters[0].Source != sourceFanqie {
		t.Fatalf("ROUTE fanqie-detail: chapter source=%q, want fanqie", chapters[0].Source)
	}
	fanqieLivePause()

	// 4. 取流：只记现象。本机出口 App 腿空回包是已知限流，不判失败。
	// 若回了地址，顺手做一次 Range 探测（只记现象），确认地址真能出字节。
	media, err := d.resolveFanqieMedia(ctx, Task{DramaID: page1[0].ID, Chapter: chapters[0]})
	if err != nil {
		t.Logf("ROUTE fanqie-media: ERROR %v", err)
	} else {
		t.Logf("ROUTE fanqie-media: url=%s variants=%d duration=%v", media.URL, len(media.Variants), media.Duration)
		rangeReq, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, media.URL, nil)
		if reqErr == nil {
			rangeReq.Header.Set("Range", "bytes=0-1023")
			if media.Referer != "" {
				rangeReq.Header.Set("Referer", media.Referer)
			}
			rangeResp, respErr := d.client.Do(rangeReq)
			if respErr != nil {
				t.Logf("ROUTE fanqie-media-range: ERROR %v", respErr)
			} else {
				body, _ := io.ReadAll(io.LimitReader(rangeResp.Body, 2048))
				rangeResp.Body.Close()
				t.Logf("ROUTE fanqie-media-range: status=%d bytes=%d contentLength=%d", rangeResp.StatusCode, len(body), rangeResp.ContentLength)
			}
		}
	}
	fanqieLivePause()

	// 5. 搜索：复用红果(新)搜索接口，结果改挂番茄槽。
	entry, err := d.fetchFanqieSearch(ctx, "重生", 1)
	if err != nil {
		t.Fatalf("ROUTE fanqie-search: ERROR %v", err)
	}
	t.Logf("ROUTE fanqie-search: items=%d total=%d limited=%v warning=%q", len(entry.Dramas), entry.Total, entry.Limited, entry.Warning)
	if len(entry.Dramas) == 0 {
		t.Fatal("ROUTE fanqie-search: 0 items")
	}
	if entry.Dramas[0].Source != sourceFanqie {
		t.Fatalf("ROUTE fanqie-search: source=%q, want fanqie", entry.Dramas[0].Source)
	}
}
