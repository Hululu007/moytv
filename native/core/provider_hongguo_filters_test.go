package core

import "testing"

func TestHongguoShortDramaFilterGroups(t *testing.T) {
	groups := hongguoShortDramaFilterGroups()
	if len(groups) != 4 {
		t.Fatalf("groups = %d, want 4", len(groups))
	}
	keys := []string{"cat", "topic", "background", "setting"}
	for i, key := range keys {
		if groups[i].Key != key {
			t.Fatalf("group %d key = %q, want %q", i, groups[i].Key, key)
		}
		if len(groups[i].Options) < 2 {
			t.Fatalf("group %s has no options", key)
		}
	}
}

func TestHongguoFilterShortDramas(t *testing.T) {
	items := []Drama{
		{Title: "a", Tags: []string{"家庭", "现代"}},
		{Title: "b", Tags: []string{"古装", "宫斗"}},
	}
	out := hongguoFilterShortDramas(items, map[string]string{"cat": "家庭"})
	if len(out) != 1 || out[0].Title != "a" {
		t.Fatalf("cat filter = %v", out)
	}
	out = hongguoFilterShortDramas(items, map[string]string{"cat": "家庭", "background": "古代"})
	if len(out) != 0 {
		t.Fatalf("combined filter = %v", out)
	}
	out = hongguoFilterShortDramas(items, nil)
	if len(out) != 2 {
		t.Fatalf("no filter = %v", out)
	}
}
