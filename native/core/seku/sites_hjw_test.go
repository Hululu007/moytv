package seku

import (
	"os"
	"strings"
	"testing"
)

func TestHjwLive(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	items, _, _, err := Catalog("hjw", "home", 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("hjw catalog err=%v n=%d", err, len(items))
	}
	for _, it := range items {
		if pic, _ := it["pic"].(string); pic == "" {
			t.Fatalf("hjw catalog card without cover: %v", it["id"])
		}
	}
	d, err := Detail("hjw", "196741")
	if err != nil {
		t.Fatalf("hjw detail 196741 err=%v", err)
	}
	ch, _ := d["chapters"].([]interface{})
	if len(ch) == 0 {
		t.Fatalf("hjw detail 196741 no chapters")
	}
	ep, _ := ch[0].(map[string]interface{})["episodeId"].(string)
	if !strings.HasPrefix(ep, "pics://") {
		t.Fatalf("hjw image post must be a pics chapter, got %.80s", ep)
	}
	if n := strings.Count(ep, "&&") + 1; n < 5 {
		t.Fatalf("hjw image post pics count too small: %d", n)
	}
	res, err := Resolve("hjw", ep)
	if err != nil {
		t.Fatalf("hjw pics resolve err=%v", err)
	}
	if u, _ := res["url"].(string); !strings.HasPrefix(u, "pics://") {
		t.Fatalf("hjw pics resolve url must keep pics://, got %.80s", u)
	}
	res2, err := Resolve("hjw", "195456")
	if err != nil {
		t.Fatalf("hjw video resolve err=%v", err)
	}
	if u, _ := res2["url"].(string); !strings.Contains(u, ".m3u8") {
		t.Fatalf("hjw video resolve must return m3u8, got %.120s", u)
	}
}
