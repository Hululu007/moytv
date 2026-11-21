package seku

import (
	"strings"
	"testing"
	"time"
)

// The App clearance store must be readable from the ticketing path: a Go-core
// site that hit the shield once (ticket filled in by the App) has to send that
// ticket on the very next request without any per-site wiring.
func TestShieldBridgeTicketReachesHeaders(t *testing.T) {
	var reported string
	SetShieldBridge(
		func(host string) (string, string, bool) {
			if host == "shielded.example" {
				return "cf_clearance=abc; other=1", "UA-from-browser", true
			}
			return "", "", false
		},
		func(rawurl string) { reported = rawurl },
	)
	defer SetShieldBridge(nil, nil)

	out := zkShieldTicketHeaders("shielded.example", map[string]string{
		"User-Agent": "UA-from-core",
		"Accept":     "*/*",
	})
	if got := out["Cookie"]; got != "cf_clearance=abc; other=1" {
		t.Fatalf("cookie not injected: %q", got)
	}
	// The ticket is bound to the UA that solved the challenge; sending the
	// core UA instead invalidates it server-side.
	if got := out["User-Agent"]; got != "UA-from-browser" {
		t.Fatalf("UA not aligned with ticket: %q", got)
	}
	if out["Accept"] != "*/*" {
		t.Fatalf("unrelated header dropped")
	}

	// A host with no ticket keeps the caller's headers untouched.
	plain := zkShieldTicketHeaders("clean.example", map[string]string{"User-Agent": "UA-from-core"})
	if _, ok := plain["Cookie"]; ok {
		t.Fatalf("cookie injected for a host with no ticket")
	}
	if plain["User-Agent"] != "UA-from-core" {
		t.Fatalf("caller UA overwritten without a ticket")
	}
	_ = reported
}

// report must reach the App at most once per host per gap window: the retry
// ladder hammers the same host, and the clearance page should not be spammed.
func TestShieldReportRateLimitedPerHost(t *testing.T) {
	hits := 0
	SetShieldBridge(nil, func(string) { hits++ })
	defer func() {
		SetShieldBridge(nil, nil)
		zkShieldMu.Lock()
		zkShieldReported = map[string]time.Time{}
		zkShieldMu.Unlock()
	}()

	for i := 0; i < 5; i++ {
		zkShieldReportChallenge("https://spam.example/a")
	}
	if hits != 1 {
		t.Fatalf("expected 1 report for a host, got %d", hits)
	}
	zkShieldReportChallenge("https://other.example/a")
	if hits != 2 {
		t.Fatalf("a different host must report separately, got %d", hits)
	}
}

// Detaching the bridge must restore the old no-op behaviour so tests and any
// headless build do not depend on an App being present.
func TestShieldBridgeDetach(t *testing.T) {
	SetShieldBridge(func(string) (string, string, bool) { return "c=1", "ua", true }, nil)
	SetShieldBridge(nil, nil)
	out := zkShieldTicketHeaders("x.example", map[string]string{})
	if strings.Contains(out["Cookie"], "c=1") {
		t.Fatalf("detached bridge still injecting")
	}
}
