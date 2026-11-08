package core

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRemuxDirectory(t *testing.T) {
	root := t.TempDir()
	manager := &nativeDownloads{
		root: root,
		jobs: map[string]*nativeDownloadRecord{
			"hls1": {nativeDownloadJob: nativeDownloadJob{ID: "hls1", State: "completed"}},
			"mp41": {nativeDownloadJob: nativeDownloadJob{ID: "mp41", State: "completed"}},
			"run1": {nativeDownloadJob: nativeDownloadJob{ID: "run1", State: "downloading"}},
		},
	}
	hlsDir := filepath.Join(root, "hls1")
	if err := os.MkdirAll(hlsDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hlsDir, "index.m3u8"), []byte("#EXTM3U\n"), 0600); err != nil {
		t.Fatal(err)
	}
	directory, err := manager.remuxDirectory("hls1")
	if err != nil || directory != hlsDir {
		t.Fatalf("hls: %q %v", directory, err)
	}
	if _, err := manager.remuxDirectory("mp41"); err == nil {
		t.Fatal("mp4 job without index.m3u8 must fail")
	}
	if _, err := manager.remuxDirectory("run1"); err == nil {
		t.Fatal("unfinished job must fail")
	}
	if _, err := manager.remuxDirectory("nope"); err == nil {
		t.Fatal("unknown job must fail")
	}
}
