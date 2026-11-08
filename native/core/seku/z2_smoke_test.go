package seku

import "testing"

func TestZ2Smoke(t *testing.T) {
	for _, slot := range []string{"z2_17rip", "z2_321av", "z2_av6k", "z2_7mm", "z2_xanimu", "z2_cn", "z2_thdh"} {
		impl := implForSlot(slot)
		if impl == nil {
			t.Errorf("%s: not registered", slot)
			continue
		}
		cats := impl.Categories(slot)
		t.Logf("%s cats=%d", slot, len(cats))
		items, total, hasMore, err := impl.Catalog(slot, impl.DefaultCat, 1)
		if err != nil {
			t.Logf("%s catalog ERR: %v", slot, err)
			continue
		}
		t.Logf("%s catalog items=%d total=%d hasMore=%v", slot, len(items), total, hasMore)
		if len(items) == 0 {
			continue
		}
		first, _ := items[0].(map[string]interface{})
		rawID, _ := first["vod_id"].(string)
		if rawID == "" {
			rawID, _ = first["id"].(string)
		}
		t.Logf("%s first rawID=%q title=%q cover=%q", slot, rawID, first["title"], first["cover"])
		if impl.Detail != nil {
			d, err := impl.Detail(slot, rawID)
			if err != nil {
				t.Logf("%s detail ERR: %v", slot, err)
			} else {
				t.Logf("%s detail title=%q", slot, d["title"])
			}
		}
		if impl.Resolve != nil {
			r, err := impl.Resolve(slot, rawID)
			if err != nil {
				t.Logf("%s resolve ERR: %v", slot, err)
			} else {
				t.Logf("%s resolve url=%q format=%v", slot, r["url"], r["format"])
			}
		}
		if impl.Search != nil {
			s, err := impl.Search(slot, "MIDA")
			if err != nil {
				t.Logf("%s search ERR: %v", slot, err)
			} else {
				t.Logf("%s search items=%d", slot, len(s))
			}
		}
	}
}
