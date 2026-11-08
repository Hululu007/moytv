package seku

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestJrMkURL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://cdn.example.com/seg.ts", "https://www.javrate.com/g1/seg.ts?token=tok&expires=1700000000&token_path=tp"},
		{"https://cdn.example.com/g1/seg.ts?old=1", "https://www.javrate.com/g1/seg.ts?token=tok&expires=1700000000&token_path=tp"},
		{"https://cdn.example.com//seg.ts", "https://www.javrate.com/g1/seg.ts?token=tok&expires=1700000000&token_path=tp"},
	}
	for _, c := range cases {
		got := jrMkURL("https://www.javrate.com", "g1", c.in, "tok", 1700000000, "tp")
		if got != c.want {
			t.Fatalf("jrMkURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	got := jrMkURL("https://www.javrate.com", "g1", "https://cdn.example.com/seg.ts", "tok", 1700000000, "")
	if strings.Contains(got, "token_path") {
		t.Fatalf("empty token_path must be omitted: %q", got)
	}
}

func TestJrParseExpires(t *testing.T) {
	if jrParseExpires(float64(1700000100)) != 1700000100 {
		t.Fatal("float64 expires")
	}
	if jrParseExpires("1700000200") != 1700000200 {
		t.Fatal("string expires")
	}
	if jrParseExpires(nil) <= 0 {
		t.Fatal("unparseable expires must fall back to a future time")
	}
}

func TestAv321B64AndSlug(t *testing.T) {
	plain := `{"ss":[["x","https://cdn.example.com/cn/abc123/seg.m3u8"]]}`
	enc := base64.RawURLEncoding.EncodeToString([]byte(plain))
	dec := z2Av321B64Decode("  " + enc + "  ")
	if string(dec) != plain {
		t.Fatalf("b64 decode: %q", dec)
	}
	slug := z2Av321SlugFromDecoded(plain)
	if slug != "abc123" {
		t.Fatalf("slug from ss: %q", slug)
	}
	raw := "https://cdn.example.com/cn/xyz789/index.m3u8"
	slug = z2Av321SlugFromDecoded(raw)
	if slug != "xyz789" {
		t.Fatalf("slug from raw string: %q", slug)
	}
	if slug := z2Av321SlugFromDecoded(`{"ss":[]}`); slug != "" {
		t.Fatalf("empty ss must yield no slug: %q", slug)
	}
}

func TestAv321OrderCandidates(t *testing.T) {
	entries := []z2Av321Candidate{
		{url: "https://cdn.example.com/a.m3u8", urlSign: "signed"},
		{url: "https://cdn.example.com/q.m3u8", urlType: "QualityUrls"},
		{url: "https://cdn.example.com/u.m3u8"},
		{url: "https://cdn.example.com/q.m3u8", urlType: "QualityUrls"},
	}
	got := z2Av321OrderCandidates(entries)
	want := []string{"https://cdn.example.com/q.m3u8", "https://cdn.example.com/u.m3u8", "https://cdn.example.com/a.m3u8"}
	if len(got) != len(want) {
		t.Fatalf("order: %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestMmStreamsFromPage(t *testing.T) {
	main, backup := mmStreamsFromPage(`{"hls2":"http://cdn.example.com/a.m3u8","hls3":"http://cdn.example.com/b.m3u8","hls4":"http://cdn.example.com/c.m3u8"}`)
	if main != "http://cdn.example.com/c.m3u8" || backup != "http://cdn.example.com/b.m3u8" {
		t.Fatalf("hls4 must override hls2: main=%q backup=%q", main, backup)
	}
	main, backup = mmStreamsFromPage(`{"hls2":"http://cdn.example.com/a.m3u8","hls4":"short"}`)
	if main != "http://cdn.example.com/a.m3u8" || backup != "" {
		t.Fatalf("short hls4 must not override: main=%q backup=%q", main, backup)
	}
	packed := `eval(function(p,a,c,k,e,d){return p}('0,1',10,2,'"hls2":"http://cdn.example.com/a.m3u8"|"hls4":"http://cdn.example.com/b.m3u8"'.split('|'))`
	main, backup = mmStreamsFromPage(packed)
	if main != "http://cdn.example.com/b.m3u8" {
		t.Fatalf("packed page: main=%q backup=%q", main, backup)
	}
}

func TestMmExitsFromDetail(t *testing.T) {
	page := `<script type="application/ld+json">{"embedUrl":"https://cdn.example.com/v/abc123"}</script><a href="https://cdn.example.com/v/abc123">x</a><a href="https://cdn.example.com/v/def456">y</a>`
	exits := mmExitsFromDetail(page)
	if len(exits) != 2 || exits[0] != "https://cdn.example.com/v/abc123" || exits[1] != "https://cdn.example.com/v/def456" {
		t.Fatalf("exits: %v", exits)
	}
}

func TestHookCacheRoundTrip(t *testing.T) {
	hook := &mmtvStreamHook{embed: "https://cdn.example.com/v/abc123", referer: "https://7mmtv.sx/"}
	StoreStreamHook("https://cdn.example.com/pl.m3u8", hook)
	if got := HookForPlaylist("https://cdn.example.com/pl.m3u8"); got != hook {
		t.Fatal("hook must round-trip through the cache")
	}
	if got := HookForPlaylist("https://cdn.example.com/other.m3u8"); got != nil {
		t.Fatal("unknown playlist must have no hook")
	}
}

func TestJrFallbackHookQuery(t *testing.T) {
	h := &jrFallbackHook{detail: "https://www.javrate.com/movie/detail/x.html", query: "token=<redacted>&expires=1700000000&token_path=tp"}
	got, err := h.SignSegment("https://cdn.example.com/g1/seg-000.ts")
	if err != nil || got != "https://cdn.example.com/g1/seg-000.ts?token=<redacted>&expires=1700000000&token_path=tp" {
		t.Fatalf("fallback sign = %q, %v", got, err)
	}
	got, _ = h.SignSegment("https://cdn.example.com/g1/seg-000.ts?foo=1")
	if got != "https://cdn.example.com/g1/seg-000.ts?foo=1&token=<redacted>&expires=1700000000&token_path=tp" {
		t.Fatalf("fallback sign with query = %q", got)
	}
	got, _ = h.SignSegment("https://cdn.example.com/g1/seg-000.ts?token=<redacted>")
	if got != "https://cdn.example.com/g1/seg-000.ts?token=<redacted>" {
		t.Fatalf("signed segment must pass through: %q", got)
	}
	if got, _ := (&jrFallbackHook{}).SignSegment("https://cdn.example.com/g1/seg-000.ts"); got != "https://cdn.example.com/g1/seg-000.ts" {
		t.Fatalf("empty query must pass through: %q", got)
	}
}
