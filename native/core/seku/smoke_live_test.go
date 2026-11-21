//go:build smoke

// 全站点线上冒烟：逐个 slot 真发请求取第一页目录，判定站点/盾的状态。
// 只在显式 -tags smoke 时编译运行，不影响常规单测。
//
//	go test -tags smoke -run TestSmokeAllSlots -timeout 40m ./native/core/seku -v
package seku

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

type smokeResult struct {
	Slot     string `json:"slot"`
	Name     string `json:"name"`
	Home     string `json:"home"`
	OK       bool   `json:"ok"`
	Stage    string `json:"stage"`
	Items    int    `json:"items"`
	Pages    int    `json:"pages"`
	Classes  int    `json:"classes"`
	Err      string `json:"err"`
	Elapsed  string `json:"elapsed"`
	SampleN0 string `json:"sample"`
}

func TestSmokeAllSlots(t *testing.T) {
	slots := Slots()
	fmt.Printf("SMOKE slots=%d\n", len(slots))

	results := make([]smokeResult, 0, len(slots))
	var mu sync.Mutex
	sem := make(chan struct{}, 5) // 低并发，避免本机出口被限流
	var wg sync.WaitGroup

	for _, slot := range slots {
		wg.Add(1)
		go func(slot string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			r := smokeOne(slot)
			mu.Lock()
			results = append(results, r)
			mu.Unlock()
			flag := "ERR"
			if r.OK {
				flag = "OK "
			}
			fmt.Printf("SMOKE %s %-18s items=%-3d pages=%-2d cls=%-2d %-8s %s\n",
				flag, r.Slot, r.Items, r.Pages, r.Classes, r.Elapsed, truncate(r.Err, 110))
		}(slot)
	}
	wg.Wait()

	sort.Slice(results, func(i, j int) bool { return results[i].Slot < results[j].Slot })
	if out := os.Getenv("SMOKE_OUT"); out != "" {
		b, _ := json.MarshalIndent(results, "", " ")
		if err := os.WriteFile(out, b, 0o644); err != nil {
			t.Logf("write %s: %v", out, err)
		}
	}
	ok := 0
	for _, r := range results {
		if r.OK {
			ok++
		}
	}
	fmt.Printf("SMOKE_DONE ok=%d/%d\n", ok, len(results))
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > n {
		return s[:n]
	}
	return s
}

func smokeOne(slot string) (r smokeResult) {
	r.Slot = slot
	r.Name = SiteName(slot)
	r.Home = HomeURL(slot)
	start := time.Now()
	defer func() {
		r.Elapsed = time.Since(start).Round(time.Millisecond * 10).String()
		if rec := recover(); rec != nil {
			r.OK = false
			r.Stage = "panic"
			r.Err = fmt.Sprintf("%v", rec)
		}
	}()

	cats := Categories(slot)
	r.Classes = len(cats)
	if len(cats) == 0 {
		r.Stage = "categories"
		r.Err = "no categories"
		return
	}
	cat := cats[0].ID
	for _, c := range cats {
		if c.ID != "" && c.ID != "0" {
			cat = c.ID
			break
		}
	}
	items, pages, _, err := Catalog(slot, cat, 1)
	if err != nil {
		r.Stage = "catalog"
		r.Err = err.Error()
		return
	}
	r.Items = len(items)
	r.Pages = pages
	if len(items) > 0 {
		r.SampleN0 = truncate(fmt.Sprintf("%v", items[0]["vod_name"]), 40)
	}
	if len(items) == 0 {
		r.Stage = "empty"
		r.Err = "catalog returned 0 items (cat=" + cat + ")"
		return
	}
	r.OK = true
	r.Stage = "done"
	return
}
