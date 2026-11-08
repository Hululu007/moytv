package seku

import (
	"os"
	"testing"
)

func TestIkunRegistered(t *testing.T) {
	impl := implForSlot("ikun")
	if impl == nil {
		t.Fatal("slot ikun must be registered")
	}
	if impl.Key != "ikun" {
		t.Fatalf("impl key = %q", impl.Key)
	}
}

// 活体冒烟（ZZ_LIVE=1 才跑）：分类/目录/详情/解析/搜索全链。
// 本机出口到 ikunzyapi.com 呈阵发性超时，失败先看是否出口抖动再判站死。
func TestIkunLiveSmoke(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	impl := implForSlot("ikun")
	cats := impl.Categories("ikun")
	if len(cats) < 40 {
		t.Fatalf("categories = %d", len(cats))
	}
	items, _, _, err := impl.Catalog("ikun", "6", 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("catalog t=6: %v %d", err, len(items))
	}
	first := items[0].(map[string]interface{})
	raw := rawIDOf(first)
	d, err := impl.Detail("ikun", raw)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	chs, _ := d["chapters"].([]interface{})
	if len(chs) == 0 {
		t.Fatal("no chapters")
	}
	ep, _ := chs[0].(map[string]interface{})
	res, err := impl.Resolve("ikun", ep["episodeId"].(string))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	t.Logf("resolved: %v", res["url"])
	found, err := impl.Search("ikun", "战狼")
	if err != nil || len(found) == 0 {
		t.Fatalf("search: %v %d", err, len(found))
	}
}
