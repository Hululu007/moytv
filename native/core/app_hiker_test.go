package core

import (
	"strings"
	"testing"
)

func TestHikerParseArray(t *testing.T) {
	htmlText := `<html><body><ul class="list"><li><a title="A" href="/a">A</a></li><li><a title="B" href="/b">B</a></li></ul></body></html>`
	out := hikerParseArray(htmlText, "body&&.list&&li")
	if len(out) != 2 {
		t.Fatalf("want 2, got %d: %v", len(out), out)
	}
	if !strings.Contains(out[0], "A") {
		t.Fatalf("first item missing A: %s", out[0])
	}
	title := hikerParseSingle(out[0], "a&&title")
	if title != "A" {
		t.Fatalf("want title A, got %q", title)
	}
}

func TestHikerAttrSelectors(t *testing.T) {
	htmlText := `<html><body><div class="list"><a href="/play/1" data-id="7">One</a><a href="/read/2.mp4" data-id="8">Two</a><a href="/play/3">Three</a></div></body></html>`
	if got := hikerParseArray(htmlText, "div.list&&a[href]"); len(got) != 3 {
		t.Fatalf("want 3 for [href], got %d", len(got))
	}
	if got := hikerParseArray(htmlText, `div.list&&a[href="/play/1"]`); len(got) != 1 {
		t.Fatalf("want 1 for exact attr, got %d", len(got))
	}
	if got := hikerParseArray(htmlText, `div.list&&a[href*="play"]`); len(got) != 2 {
		t.Fatalf("want 2 for *= attr, got %d", len(got))
	}
	if got := hikerParseArray(htmlText, `div.list&&a[href^="/read"]`); len(got) != 1 {
		t.Fatalf("want 1 for ^= attr, got %d", len(got))
	}
	if got := hikerParseArray(htmlText, `div.list&&a[href$=".mp4"]`); len(got) != 1 {
		t.Fatalf("want 1 for $= attr, got %d", len(got))
	}
	if got := hikerParseArray(htmlText, `div.list&&a[data-id="8"]`); len(got) != 1 || !strings.Contains(got[0], "Two") {
		t.Fatalf("want Two for data-id attr, got %v", got)
	}
	if got := hikerParseArray(htmlText, `div.list&&[data-id="7"]`); len(got) != 1 || !strings.Contains(got[0], "One") {
		t.Fatalf("want One for tag-less attr, got %v", got)
	}
	if got := hikerParseSingle(htmlText, `div.list&&a[href*="play"]&&Text`); got != "One" {
		t.Fatalf("want One for attr single text, got %q", got)
	}
}

func TestHikerPositionalSelectors(t *testing.T) {
	htmlText := `<html><body><ul><li>A</li><li>B</li><li>C</li></ul></body></html>`
	if got := hikerParseArray(htmlText, "ul&&li:eq(1)"); len(got) != 1 || !strings.Contains(got[0], "B") {
		t.Fatalf("want B for :eq(1), got %v", got)
	}
	if got := hikerParseArray(htmlText, "ul&&li:first"); len(got) != 1 || !strings.Contains(got[0], "A") {
		t.Fatalf("want A for :first, got %v", got)
	}
	if got := hikerParseArray(htmlText, "ul&&li:last"); len(got) != 1 || !strings.Contains(got[0], "C") {
		t.Fatalf("want C for :last, got %v", got)
	}
	if got := hikerParseArray(htmlText, "ul&&li:eq(9)"); len(got) != 0 {
		t.Fatalf("want 0 for out of range :eq, got %d", len(got))
	}
	if got := hikerParseSingle(htmlText, "ul&&li:eq(2)&&Text"); got != "C" {
		t.Fatalf("want C for :eq single text, got %q", got)
	}
	attrHtml := `<html><body><div class="list"><a href="/play/1">One</a><a href="/read/2">Two</a><a href="/play/3">Three</a></div></body></html>`
	if got := hikerParseSingle(attrHtml, `div.list&&a[href*="play"]:eq(1)&&Text`); got != "Three" {
		t.Fatalf("want Three for attr plus :eq, got %q", got)
	}
}
