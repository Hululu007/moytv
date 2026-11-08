package core

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

var (
	siteHeadRe = regexp.MustCompile(`SourceSite\(\s*'([^']+)'`)
	slotIDRe   = regexp.MustCompile(`slotId:\s*'([^']+)'`)
)

func dartModelsPath(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test file")
	}
	path := filepath.Join(filepath.Dir(file), "..", "..", "lib", "models.dart")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("models.dart not found at %s: %v", path, err)
	}
	return path
}

func dartSiteSlotPairs(t *testing.T) [][2]string {
	t.Helper()
	raw, err := os.ReadFile(dartModelsPath(t))
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	heads := siteHeadRe.FindAllStringSubmatchIndex(text, -1)
	slots := slotIDRe.FindAllStringSubmatchIndex(text, -1)
	pairs := [][2]string{}
	for _, m := range slots {
		slot := text[m[2]:m[3]]
		public := ""
		for _, h := range heads {
			if h[0] < m[0] {
				public = text[h[2]:h[3]]
			} else {
				break
			}
		}
		if public == "" {
			t.Fatalf("slotId %s has no preceding SourceSite", slot)
		}
		pairs = append(pairs, [2]string{public, slot})
	}
	return pairs
}

func TestSekuSlotMappingMatchesDartRegistry(t *testing.T) {
	pairs := dartSiteSlotPairs(t)
	yhCount := 0
	for _, p := range pairs {
		public, slot := p[0], p[1]
		if !strings.HasPrefix(slot, "yh_") {
			continue
		}
		yhCount++
		if got, ok := sekuSlotForSource(public); !ok || got != slot {
			t.Fatalf("sekuSlotForSource(%q) = %q, %v, want %q", public, got, ok, slot)
		}
		if got, ok := sekuSlotForSource(slot); !ok || got != slot {
			t.Fatalf("sekuSlotForSource(%q) = %q, %v, want %q", slot, got, ok, slot)
		}
		if !isSekuSource(public) || !isSekuSource(slot) {
			t.Fatalf("isSekuSource false for pair %q/%q", public, slot)
		}
	}
	if yhCount < 36 {
		t.Fatalf("parsed %d yh_ pairs from models.dart, want at least 36", yhCount)
	}
	if got, ok := sekuSlotForSource("huangdou_yh"); !ok || got != "yh_huangdou" {
		t.Fatalf("sekuSlotForSource(huangdou_yh) = %q, %v, want yh_huangdou", got, ok)
	}
}
