package core

import (
	"os"
	"path/filepath"
	"testing"
)

// Every built-in Legado JSON asset in the tree must parse in the Go
// core without error: a bad rule file must surface as a search error
// (or an empty list) in the app, never as a crash at load time. This
// covers all 101 files, including the 49 unverified ones added in the
// 2026-11-25 batch.
func TestLegadoBuiltinSourcesParse(t *testing.T) {
	dir := filepath.Join("..", "..", "assets", "legado_sources")
	files, err := filepath.Glob(filepath.Join(dir, "legado_*.json"))
	if err != nil || len(files) == 0 {
		t.Skipf("no builtin legado assets found under %s", dir)
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Errorf("%s: read failed: %v", filepath.Base(f), err)
			continue
		}
		src, err := legadoParseSource(raw)
		if err != nil {
			t.Errorf("%s: parse failed: %v", filepath.Base(f), err)
			continue
		}
		if src.Name == "" {
			t.Errorf("%s: empty bookSourceName", filepath.Base(f))
		}
		if src.URL == "" {
			t.Errorf("%s: empty bookSourceUrl", filepath.Base(f))
		}
	}
	t.Logf("parsed %d builtin legado sources", len(files))
}
