package seku

import (
	"fmt"
	"os"
	"testing"
)

func TestYhHuangdouRegistered(t *testing.T) {
	impl := implForSlot("yh_huangdou")
	if impl == nil {
		t.Fatal("slot yh_huangdou must be registered")
	}
	if impl.Key != "huangdou" {
		t.Fatalf("impl key = %q", impl.Key)
	}
	cats := impl.Categories("yh_huangdou")
	if len(cats) != len(yhHDCats) {
		t.Fatalf("categories = %d, want %d", len(cats), len(yhHDCats))
	}
	for i, c := range yhHDCats {
		m, _ := cats[i].(map[string]interface{})
		if m["id"] != c.id || m["name"] != c.name {
			t.Fatalf("category %d = %v, want %s/%s", i, m, c.id, c.name)
		}
	}
}

func TestYhHuangdouFreeEpisodeFilter(t *testing.T) {
	data := map[string]interface{}{
		"episodes": []interface{}{
			map[string]interface{}{"seq": float64(3), "type": "free", "price": float64(0), "name": "第3集"},
			map[string]interface{}{"seq": float64(1), "type": "free", "price": float64(0)},
			map[string]interface{}{"seq": float64(2), "type": "free", "price": float64(5)},
			map[string]interface{}{"seq": float64(4), "type": "money", "price": float64(0)},
		},
	}
	free := yhHDFreeEpisodes(data)
	if len(free) != 2 || free[0].Seq != 1 || free[1].Seq != 3 {
		t.Fatalf("free episodes = %+v, want seq 1 and 3 only", free)
	}
	if free[0].Name != "第1集" || free[1].Name != "第3集" {
		t.Fatalf("episode names = %+v", free)
	}
}

// 活体冒烟（ZZ_LIVE=1 才跑）：目录/详情（只出免费集）/免费集解析全链。
func TestYhHuangdouLiveSmoke(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	impl := implForSlot("yh_huangdou")
	items, _, _, err := impl.Catalog("yh_huangdou", yhHDCats[0].id, 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("catalog: %v %d", err, len(items))
	}
	item, _ := items[0].(map[string]interface{})
	raw := rawIDOf(item)
	d, err := impl.Detail("yh_huangdou", raw)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	chs, _ := d["chapters"].([]interface{})
	if len(chs) == 0 {
		t.Fatal("no free chapters")
	}
	ep, _ := chs[0].(map[string]interface{})
	res, err := impl.Resolve("yh_huangdou", ep["episodeId"].(string))
	if err != nil {
		t.Fatalf("resolve free episode: %v", err)
	}
	t.Logf("resolved: %v", res["url"])
	paidRef := fmt.Sprintf("%s@@%d", raw, 9999)
	if _, err := impl.Resolve("yh_huangdou", paidRef); err == nil {
		t.Fatal("resolve of nonexistent/paid episode must fail")
	}
	found, err := impl.Search("yh_huangdou", "短剧")
	if err != nil || len(found) == 0 {
		t.Fatalf("search: %v %d", err, len(found))
	}
}
