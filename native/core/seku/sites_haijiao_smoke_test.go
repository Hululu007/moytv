package seku

import (
	"os"
	"strings"
	"testing"
	"time"
)

func diagSlot(t *testing.T, slot, cat string) {
	t.Helper()
	items, total, hasMore, err := Catalog(slot, cat, 1)
	t.Logf("slot=%s cat=%s err=%v total=%d hasMore=%v n=%d", slot, cat, err, total, hasMore, len(items))
	if err != nil || len(items) == 0 {
		return
	}
	first := items[0]
	fullID := ""
	if v, ok := first["id"].(string); ok {
		fullID = v
	}
	id := fullID
	if i := strings.Index(fullID, ":"); i >= 0 {
		id = fullID[i+1:]
	}
	t.Logf("first fullID=%q bareID=%q name=%q pic=%q", fullID, id, first["name"], first["pic"])
	if id == "" {
		return
	}
	d, derr := Detail(slot, id)
	if derr != nil {
		t.Logf("detail err=%v", derr)
		return
	}
	t.Logf("detail title=%q chapters=%v playSources=%v", d["name"], d["chapters"], d["playSources"])
	raw := id
	if ch, ok := d["chapters"].([]interface{}); ok && len(ch) > 0 {
		if cm, ok := ch[0].(map[string]interface{}); ok {
			t.Logf("chapter0=%v", cm)
			if v, ok := cm["episodeId"].(string); ok && v != "" {
				raw = v
			}
		}
	}
	t.Logf("resolve raw=%q", raw)
	res, rerr := Resolve(slot, raw)
	if rerr != nil {
		t.Logf("resolve err=%v", rerr)
		return
	}
	u, _ := res["url"].(string)
	key, _ := res["hlsKey"].(string)
	t.Logf("resolve url len=%d prefix=%q hlsKeyLen=%d", len(u), u[:min(120, len(u))], len(key))
	if strings.HasPrefix(u, "file://") {
		t.Fatalf("resolve still returns file url")
	}
	if slot == "fanguo" && (!strings.HasPrefix(u, "https://") || len(key) != 32) {
		t.Fatalf("fanguo resolve must return https full playlist + 16-byte hlsKey, got url=%q keyLen=%d", u, len(key))
	}
	if strings.HasPrefix(u, "http") {
		b, code, _, err := httpGetTimeout(u, map[string]string{"User-Agent": "Mozilla/5.0"}, 20*time.Second)
		_ = b
		t.Logf("play url fetch code=%d err=%v bodyLen=%d", code, err, len(b))
	}
}

func TestHaijiaoDiag(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	diagSlot(t, "yh_haijiao", "video:1")
	diagSlot(t, "fanguo", "new")
}
