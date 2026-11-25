package core

// Live-only book-source verification for the yckceo refresh.
// Run: MOYI_LIVE_VERIFY=1 MOYI_VERIFY_DIR=<dir of candidate JSONs> \
//   MOYI_VERIFY_OUT=<results jsonl path> \
//   go test ./native/core/ -run TestLiveBookSourceVerify -v -count=1
// Skipped unless MOYI_LIVE_VERIFY=1, so CI/regression never hits the network.
// Per source: search (up to 3 keywords) -> toc of first hit -> content of
// first chapter; ok only when real chapter text (>=200 runes) comes back.
// Results are appended as one JSON object per line; already-recorded files
// are skipped, so a run can be resumed after interruption. Per-source
// failures are recorded, never fatal to the test itself.

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

var liveVerifyKeywords = []string{"斗破苍穹", "斗罗大陆", "凡人修仙传"}

func TestLiveBookSourceVerify(t *testing.T) {
	if os.Getenv("MOYI_LIVE_VERIFY") != "1" {
		t.Skip("live verification only (MOYI_LIVE_VERIFY=1)")
	}
	dir := os.Getenv("MOYI_VERIFY_DIR")
	if dir == "" {
		t.Fatal("MOYI_VERIFY_DIR not set")
	}
	outPath := os.Getenv("MOYI_VERIFY_OUT")
	if outPath == "" {
		outPath = filepath.Join(dir, "verify_results.jsonl")
	}
	done := map[string]bool{}
	if f, err := os.Open(outPath); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		for sc.Scan() {
			var r map[string]interface{}
			if json.Unmarshal(sc.Bytes(), &r) == nil {
				if s, ok := r["file"].(string); ok {
					done[s] = true
				}
			}
		}
		_ = f.Close()
	}
	out, err := os.OpenFile(outPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	enc := json.NewEncoder(out)

	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		base := filepath.Base(f)
		if done[base] {
			t.Logf("skip already verified: %s", base)
			continue
		}
		rec := map[string]interface{}{"file": base, "at": time.Now().Format(time.RFC3339)}
		start := time.Now()
		raw, err := os.ReadFile(f)
		if err != nil {
			rec["status"] = "fail"
			rec["stage"] = "read"
			rec["detail"] = err.Error()
			_ = enc.Encode(rec)
			continue
		}
		// yckceo downloads are usually a single-element array; unwrap it.
		var obj json.RawMessage
		var arr []json.RawMessage
		if json.Unmarshal(raw, &arr) == nil && len(arr) > 0 {
			obj = arr[0]
		} else {
			obj = raw
		}
		src, err := legadoParseSource(obj)
		if err != nil {
			rec["status"] = "fail"
			rec["stage"] = "parse"
			rec["detail"] = err.Error()
			_ = enc.Encode(rec)
			continue
		}
		rec["name"] = src.Name
		rec["url"] = src.URL
		rec["type"] = src.Type
		if src.Type != 0 {
			rec["status"] = "skip"
			rec["stage"] = "type"
			rec["detail"] = "not a novel source (type != 0)"
			_ = enc.Encode(rec)
			continue
		}
		if src.SearchURL == "" || src.BookList == "" {
			rec["status"] = "fail"
			rec["stage"] = "rules"
			rec["detail"] = "missing searchUrl or bookList rule"
			_ = enc.Encode(rec)
			continue
		}
		// Search: try keywords in order until one returns a usable hit.
		var bookURL, bookTitle string
		var searchErr string
		for _, kw := range liveVerifyKeywords {
			res, err := legadoSearch(src, kw, 1)
			if err != nil {
				searchErr = err.Error()
				continue
			}
			books, _ := res.([]map[string]string)
			for _, b := range books {
				if b["url"] != "" {
					bookURL, bookTitle = b["url"], b["title"]
					break
				}
			}
			if bookURL != "" {
				break
			}
			searchErr = "no usable hit"
		}
		if bookURL == "" {
			rec["status"] = "fail"
			rec["stage"] = "search"
			rec["detail"] = searchErr
			rec["ms"] = time.Since(start).Milliseconds()
			_ = enc.Encode(rec)
			continue
		}
		rec["book"] = bookTitle
		res, err := legadoToc(src, bookURL)
		if err != nil {
			rec["status"] = "fail"
			rec["stage"] = "toc"
			rec["detail"] = err.Error()
			rec["ms"] = time.Since(start).Milliseconds()
			_ = enc.Encode(rec)
			continue
		}
		chapters, _ := res.([]map[string]string)
		var chapterURL, chapterTitle string
		for _, c := range chapters {
			if c["url"] != "" {
				chapterURL, chapterTitle = c["url"], c["title"]
				break
			}
		}
		if chapterURL == "" {
			rec["status"] = "fail"
			rec["stage"] = "toc"
			rec["detail"] = "no chapter with url"
			rec["ms"] = time.Since(start).Milliseconds()
			_ = enc.Encode(rec)
			continue
		}
		rec["chapter"] = chapterTitle
		cres, err := legadoContent(src, chapterURL)
		if err != nil {
			rec["status"] = "fail"
			rec["stage"] = "content"
			rec["detail"] = err.Error()
			rec["ms"] = time.Since(start).Milliseconds()
			_ = enc.Encode(rec)
			continue
		}
		cmap, _ := cres.(map[string]string)
		text := strings.TrimSpace(cmap["content"])
		if utf8.RuneCountInString(text) < 200 {
			rec["status"] = "fail"
			rec["stage"] = "content"
			rec["detail"] = "chapter text too short"
			rec["contentRunes"] = utf8.RuneCountInString(text)
			rec["ms"] = time.Since(start).Milliseconds()
			_ = enc.Encode(rec)
			continue
		}
		rec["status"] = "ok"
		rec["contentRunes"] = utf8.RuneCountInString(text)
		rec["ms"] = time.Since(start).Milliseconds()
		_ = enc.Encode(rec)
		t.Logf("OK %s (%s) book=%q chapter=%q runes=%d", base, src.Name, bookTitle, chapterTitle, utf8.RuneCountInString(text))
	}
}
