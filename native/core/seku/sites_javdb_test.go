package seku

import (
	"os"
	"testing"
)

func TestParseJavdbListFixture(t *testing.T) {
	body, err := os.ReadFile("testdata/javdb_list.html")
	if err != nil {
		t.Fatal(err)
	}
	items := parseJavdbList("javdb", string(body))
	if len(items) < 2 {
		t.Fatalf("expected at least 2 items, got %d", len(items))
	}
	first := items[0].(map[string]interface{})
	if first["vod_id"] != "RkPb5z" {
		t.Fatalf("unexpected first id: %v", first["vod_id"])
	}
	if first["cover"] == "" || first["title"] == "" {
		t.Fatalf("missing cover/title: %v", first)
	}
}

func TestParseMagnetsFixture(t *testing.T) {
	body, err := os.ReadFile("testdata/javdb_detail.html")
	if err != nil {
		t.Fatal(err)
	}
	entries := parseMagnets(string(body))
	if len(entries) != 1 {
		t.Fatalf("expected 1 magnet, got %d", len(entries))
	}
	e := entries[0]
	if e.SizeMB != 2615 || e.Files != 2 || e.Name != "BBSS-106" {
		t.Fatalf("unexpected magnet: %+v", e)
	}
	if e.URL == "" || e.SizeLabel() != "2.55GB" {
		t.Fatalf("unexpected magnet url/label: %+v", e)
	}
	maps := magnetMaps(entries)
	row := maps[0].(map[string]interface{})
	if row["sizeLabel"] != "2.55GB" || row["url"] != e.URL {
		t.Fatalf("unexpected magnet map: %v", row)
	}
}

func TestJavdbRegistered(t *testing.T) {
	if !HasSlot("javdb") {
		t.Fatal("javdb slot not registered")
	}
	cats := Categories("javdb")
	if len(cats) != 6 {
		t.Fatalf("expected 6 categories, got %d", len(cats))
	}
}
