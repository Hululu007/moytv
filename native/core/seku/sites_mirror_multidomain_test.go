package seku

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func resetMirrorStateForTest(t *testing.T, seeds []string, learned string) {
	t.Helper()
	oldSeeds := mirrorSeedHosts
	oldHost := mirrorHost()
	mirrorSeedHosts = seeds
	mirrorState.mu.Lock()
	mirrorState.host = learned
	mirrorState.cache = map[string]whosPageEntry{}
	mirrorState.mu.Unlock()
	t.Cleanup(func() {
		mirrorSeedHosts = oldSeeds
		mirrorState.mu.Lock()
		mirrorState.host = oldHost
		mirrorState.cache = map[string]whosPageEntry{}
		mirrorState.mu.Unlock()
	})
}

const mirrorGoodBody = `<html><head><title>MissAV</title></head><body><div class="grid"><div class="relative">video card</div></div></body></html>`

func TestMirrorFetchFallsBackOn500(t *testing.T) {
	var badHits, goodHits int32
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&badHits, 1)
		w.WriteHeader(500)
		_, _ = w.Write([]byte("err"))
	}))
	defer bad.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&goodHits, 1)
		_, _ = w.Write([]byte(mirrorGoodBody))
	}))
	defer good.Close()
	resetMirrorStateForTest(t, []string{bad.URL, good.URL}, bad.URL)

	text, err := mirrorFetch("/cn/new?page=1")
	if err != nil {
		t.Fatalf("fetch err: %v", err)
	}
	if !strings.Contains(text, "video card") {
		t.Fatalf("unexpected body: %q", text)
	}
	if atomic.LoadInt32(&badHits) == 0 || atomic.LoadInt32(&goodHits) == 0 {
		t.Fatalf("expected both hosts hit: bad=%d good=%d", badHits, goodHits)
	}
}

func TestMirrorFetchFallsBackOnChallenge(t *testing.T) {
	var goodHits int32
	chal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<html><head><title>Just a moment...</title></head><body>challenge</body></html>`))
	}))
	defer chal.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&goodHits, 1)
		_, _ = w.Write([]byte(mirrorGoodBody))
	}))
	defer good.Close()
	resetMirrorStateForTest(t, []string{chal.URL, good.URL}, chal.URL)

	text, err := mirrorFetch("/cn/release?page=1")
	if err != nil {
		t.Fatalf("fetch err: %v", err)
	}
	if !strings.Contains(text, "video card") {
		t.Fatalf("unexpected body: %q", text)
	}
	if atomic.LoadInt32(&goodHits) == 0 {
		t.Fatal("good host never hit")
	}
}

func TestMirrorFetchLearnedHostFirst(t *testing.T) {
	var deadHits int32
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&deadHits, 1)
		w.WriteHeader(500)
	}))
	defer dead.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(mirrorGoodBody))
	}))
	defer good.Close()
	resetMirrorStateForTest(t, []string{dead.URL}, good.URL)

	text, err := mirrorFetch("/cn/search/test")
	if err != nil {
		t.Fatalf("fetch err: %v", err)
	}
	if !strings.Contains(text, "video card") {
		t.Fatalf("unexpected body: %q", text)
	}
	if atomic.LoadInt32(&deadHits) != 0 {
		t.Fatalf("dead seed hit %d times, learned host should win first", deadHits)
	}
}

func TestMirrorFetchLearnsRedirectHost(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(mirrorGoodBody))
	}))
	defer good.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, good.URL+r.URL.Path, http.StatusFound)
	}))
	defer redirect.Close()
	resetMirrorStateForTest(t, []string{redirect.URL}, redirect.URL)

	if _, err := mirrorFetch("/cn/new?page=1"); err != nil {
		t.Fatalf("fetch err: %v", err)
	}
	if got := mirrorHost(); got != good.URL {
		t.Fatalf("learned host = %q, want %q", got, good.URL)
	}
}

func TestMirrorFetchAllHostsFail(t *testing.T) {
	dead1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	dead1.Close()
	dead2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	dead2.Close()
	resetMirrorStateForTest(t, []string{dead1.URL, dead2.URL}, dead1.URL)

	start := time.Now()
	_, err := mirrorFetch("/cn/new?page=1")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if time.Since(start) > 60*time.Second {
		t.Fatalf("all-fail took too long: %v", time.Since(start))
	}
}

func TestMirrorOrderedHostsDedupes(t *testing.T) {
	resetMirrorStateForTest(t, []string{"https://a.example", "https://b.example", "https://a.example"}, "https://b.example")
	got := mirrorOrderedHosts()
	want := []string{"https://b.example", "https://a.example"}
	if len(got) != len(want) {
		t.Fatalf("ordered = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ordered = %v, want %v", got, want)
		}
	}
}
