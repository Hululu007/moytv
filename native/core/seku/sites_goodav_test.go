package seku

import (
	"os"
	"strings"
	"testing"
)

const gaFixtureList = `<div class='movie'><a href="https://goodav17.com/html/21061/"><img src='https://img.example/small.jpg' large_image='https://img.example/large.jpg'></a><a href="https://goodav17.com/html/21061/">MIDA-312 テスト</a></div><div class='movie'><a href="https://goodav17.com/local_html/883/"><img src='https://img.example/l.jpg'></a><a href="https://goodav17.com/local_html/883/">自拍テスト</a></div><div class='movie'><a href="https://goodav17.com/vr_html/55/"><img src='https://img.example/v.jpg'></a><a href="https://goodav17.com/vr_html/55/">VRテスト</a></div>`

func TestGoodavParseList(t *testing.T) {
	cards := gaParseList(gaFixtureList)
	if len(cards) != 3 {
		t.Fatalf("cards = %d, want 3", len(cards))
	}
	if cards[0]["rawID"] != "21061" || cards[1]["rawID"] != "lc883" || cards[2]["rawID"] != "vr55" {
		t.Fatalf("ids = %v %v %v", cards[0]["rawID"], cards[1]["rawID"], cards[2]["rawID"])
	}
	if cards[0]["cover"] != "https://img.example/large.jpg" {
		t.Fatalf("cover = %v", cards[0]["cover"])
	}
	if cards[0]["title"] != "MIDA-312 テスト" {
		t.Fatalf("title = %v", cards[0]["title"])
	}
}

func TestGoodavLineID(t *testing.T) {
	// u = base64("https://video-8.ggjav.com/video_1/179857-MIDA-312.mp4")
	embed := "https://ggjav.com/main/embed?u=aHR0cHM6Ly92aWRlby04LmdnamF2LmNvbS92aWRlb18xLzE3OTg1Ny1NSURBLTMxMi5tcDQ="
	line := gaLineID(embed)
	if !strings.HasPrefix(line, "gv|") || !strings.HasSuffix(line, "|https://video-8.ggjav.com/video_1/179857-MIDA-312.mp4") {
		t.Fatalf("line = %q", line)
	}
	if gaLineID("https://www.youjizz.com/videos/embed/123") != "yj|https://www.youjizz.com/videos/embed/123" {
		t.Fatal("yj line wrong")
	}
}

func TestGoodavRegistered(t *testing.T) {
	if implForSlot("goodav") == nil {
		t.Fatal("goodav not registered")
	}
	for _, dead := range []string{"hzai", "xme"} {
		if implForSlot(dead) != nil {
			t.Fatalf("%s must stay unregistered", dead)
		}
	}
}

func TestGoodavLiveSmoke(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	impl := implForSlot("goodav")
	cats := impl.Categories("goodav")
	if len(cats) < 5 {
		t.Fatalf("categories = %d", len(cats))
	}
	items, _, _, err := impl.Catalog("goodav", "home", 1)
	if err != nil || len(items) == 0 {
		t.Fatalf("catalog home: %v %d", err, len(items))
	}
	first := items[0].(map[string]interface{})
	raw := rawIDOf(first)
	d, err := impl.Detail("goodav", raw)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	chs, _ := d["chapters"].([]interface{})
	if len(chs) == 0 {
		t.Fatal("no chapters")
	}
	ep, _ := chs[0].(map[string]interface{})
	res, err := impl.Resolve("goodav", ep["episodeId"].(string))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	t.Logf("resolved: %v", res["url"])
	found, err := impl.Search("goodav", "SSIS")
	if err != nil || len(found) == 0 {
		t.Fatalf("search: %v %d", err, len(found))
	}
}
