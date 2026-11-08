package seku

import (
	"os"
	"testing"
)

func TestYhSenlinRegistered(t *testing.T) {
	impl := implForSlot("yh_senlin")
	if impl == nil {
		t.Fatal("slot yh_senlin must be registered")
	}
	if impl.Key != "yh_senlin" {
		t.Fatalf("impl key = %q", impl.Key)
	}
	wantKeys := []string{"guangsu", "liangzi", "baofeng", "douban", "ikun", "maotai"}
	if len(yhSenlinSources) != len(wantKeys) {
		t.Fatalf("senlin sub-sources = %d, want %d", len(yhSenlinSources), len(wantKeys))
	}
	for i, want := range wantKeys {
		if yhSenlinSources[i].key != want {
			t.Fatalf("sub-source %d key = %q, want %q", i, yhSenlinSources[i].key, want)
		}
	}
	slots := allSlots()
	ikunAt, senlinAt := -1, -1
	for i, s := range slots {
		if s == "ikun" {
			ikunAt = i
		}
		if s == "yh_senlin" {
			senlinAt = i
		}
	}
	if senlinAt < 0 || ikunAt < 0 || senlinAt < ikunAt {
		t.Fatalf("slotOrder: ikun at %d, yh_senlin at %d", ikunAt, senlinAt)
	}
}

// 活体冒烟（ZZ_LIVE=1 才跑）：聚合分类/目录/详情/解析/合并搜索全链。
func TestYhSenlinLiveSmoke(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	impl := implForSlot("yh_senlin")
	cats := impl.Categories("yh_senlin")
	if len(cats) == 0 {
		t.Fatal("no categories")
	}
	first, _ := cats[0].(map[string]interface{})
	catID, _ := first["id"].(string)
	items, _, _, err := impl.Catalog("yh_senlin", catID, 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("catalog %s: %v %d", catID, err, len(items))
	}
	item, _ := items[0].(map[string]interface{})
	raw := rawIDOf(item)
	d, err := impl.Detail("yh_senlin", raw)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	chs, _ := d["chapters"].([]interface{})
	if len(chs) == 0 {
		t.Fatal("no chapters")
	}
	ep, _ := chs[0].(map[string]interface{})
	res, err := impl.Resolve("yh_senlin", ep["episodeId"].(string))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	t.Logf("resolved: %v", res["url"])
	found, err := impl.Search("yh_senlin", "战狼")
	if err != nil || len(found) == 0 {
		t.Fatalf("search: %v %d", err, len(found))
	}
}
