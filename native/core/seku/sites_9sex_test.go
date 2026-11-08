package seku

import (
	"os"
	"strings"
	"testing"
)

// 夹具为 2026-10-24 从 porndav.com/tw/video/all 活页截取的卡片区
// 原文（前两张卡），验列表解析与活页结构吻合。
func TestNSParseListFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/9sex_list_excerpt.html")
	if err != nil {
		t.Fatal(err)
	}
	items := nsParseList(string(b))
	if len(items) == 0 {
		t.Fatal("fixture parsed to 0 cards")
	}
	for _, it := range items {
		name := g5StrVal(it["name"])
		id := g5StrVal(it["id"])
		if len([]rune(name)) < 2 || !strings.HasPrefix(id, "avbigplat:") {
			t.Fatalf("bad card: id=%q name=%q", id, name)
		}
		if strings.Contains(name, "AV大平台 -") {
			t.Fatalf("title suffix not trimmed: %q", name)
		}
	}
}

func TestNSDigStream(t *testing.T) {
	page := `<html><script>var cfg={"file":"https:\/\/cdn.example.com\/v\/abc123.m3u8?token=x"};</script></html>`
	if got := nsDigStream(page); got != "https://cdn.example.com/v/abc123.m3u8?token=x" {
		t.Fatalf("key-json dig = %q", got)
	}
	page2 := `<video><source src="https://cdn.example.com/movie.mp4"></video>`
	if got := nsDigStream(page2); got != "https://cdn.example.com/movie.mp4" {
		t.Fatalf("source-tag dig = %q", got)
	}
	page3 := `<div>no stream here</div>`
	if got := nsDigStream(page3); got != "" {
		t.Fatalf("empty dig = %q", got)
	}
}

func TestNSRegistered(t *testing.T) {
	if implForSlot("avbigplat") == nil {
		t.Fatal("avbigplat not registered")
	}
	if len(nsCats) != 15 {
		t.Fatalf("cats = %d, want 15", len(nsCats))
	}
}
