package seku

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTgChannelsCarryAll101(t *testing.T) {
	if len(tgChannels) != 101 {
		t.Fatalf("want 101 channels, got %d", len(tgChannels))
	}
	seen := map[string]bool{}
	for _, c := range tgChannels {
		if c.ID == "" || c.Name == "" {
			t.Fatalf("channel with empty id/name: %+v", c)
		}
		if seen[c.ID] {
			t.Fatalf("duplicate channel id %q", c.ID)
		}
		seen[c.ID] = true
	}
	if tgChannels[0].ID != "cctv_av" {
		t.Fatalf("want default channel cctv_av first, got %q", tgChannels[0].ID)
	}
	impl := implForSlot("tg")
	if impl == nil {
		t.Fatal("tg slot not registered")
	}
	if impl.Name != "🔞tg频道" {
		t.Fatalf("want impl name 🔞tg频道, got %q", impl.Name)
	}
	if len(impl.Categories("tg")) != 101 {
		t.Fatalf("want 101 categories, got %d", len(impl.Categories("tg")))
	}
}

func TestTgCardAndResolveOffline(t *testing.T) {
	raw := `{"count": 62198, "messages": [{"id": 12345, "message": "test video\nsecond line", "media": {"_": "messageMediaDocument", "document": {"mime_type": "video/mp4", "size": 10485760, "attributes": [{"_": "documentAttributeFilename", "file_name": "test.mp4"}, {"_": "documentAttributeVideo", "duration": 600, "w": 1280, "h": 720}]}}}]}`
	var resp tgBlockResp
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Messages) != 1 {
		t.Fatalf("want 1 message, got %d", len(resp.Messages))
	}
	card := tgCard("tg", "cctv_av", resp.Messages[0])
	if card == nil {
		t.Fatal("want a card, got nil")
	}
	if card["name"] != "test video" {
		t.Fatalf("want title test video, got %v", card["name"])
	}
	pic, _ := card["pic"].(string)
	if !strings.HasPrefix(pic, "https://tg.i-c-a.su/media/cctv_av/12345/preview/thumb.jpeg") {
		t.Fatalf("bad pic %q", pic)
	}
	res, err := tgResolve("tg", "cctv_av:12345")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	url, _ := res["url"].(string)
	if url != "https://tg.i-c-a.su/media/cctv_av/12345/video.mp4" {
		t.Fatalf("bad play url %q", url)
	}
	hdrs, _ := res["headers"].(map[string]interface{})
	if hdrs["User-Agent"] != tgUA {
		t.Fatalf("play url missing UA header: %v", hdrs)
	}
	user, id, ok := tgSplitRaw("cctv_av:12345")
	if !ok || user != "cctv_av" || id != "12345" {
		t.Fatalf("split raw: %q %q %v", user, id, ok)
	}
}

func TestTgCatalogLiveDiag(t *testing.T) {
	items, total, _, err := tgCatalog("tg", "cctv_av", 1)
	t.Logf("catalog cctv_av err=%v total=%d n=%d", err, total, len(items))
	if err != nil || len(items) == 0 {
		return
	}
	first, _ := items[0].(map[string]interface{})
	if first == nil {
		t.Logf("first item is not a map")
		return
	}
	fullID, _ := first["id"].(string)
	rawID, _ := first["vod_id"].(string)
	t.Logf("first id=%q rawID=%q name=%q pic=%q", fullID, rawID, first["name"], first["pic"])
	if rawID == "" {
		return
	}
	d, derr := tgDetail("tg", rawID)
	t.Logf("detail err=%v name=%v", derr, d["name"])
	_ = d
}
