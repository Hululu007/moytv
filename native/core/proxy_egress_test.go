package core

import (
	"net/http"
	"net/url"
	"testing"
)

func newEgressTestEngine() *nativeEngine {
	return &nativeEngine{downloader: &Downloader{
		client:      &http.Client{},
		limiter:     &requestLimiter{changed: make(chan struct{})},
		proxyRouter: &proxyRouter{},
	}}
}

func egressTestRequest(t *testing.T, rawURL string) *http.Request {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	return request
}

func mustProxyURL(t *testing.T, router *proxyRouter, rawURL string) *url.URL {
	t.Helper()
	proxyURL, err := router.proxy(egressTestRequest(t, rawURL))
	if err != nil {
		t.Fatalf("proxy(%s): %v", rawURL, err)
	}
	return proxyURL
}

func TestSetEgressProxyOverridesDirectMode(t *testing.T) {
	engine := newEgressTestEngine()
	engine.applyResourceSettings(nativeResourceSettings{ProxyMode: "direct", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2})
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/video.m3u8"); got != nil {
		t.Fatalf("direct mode without egress = %v, want nil", got)
	}
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/video.m3u8"); got == nil || got.String() != "http://127.0.0.1:7890" {
		t.Fatalf("egress override = %v, want http://127.0.0.1:7890", got)
	}
}

func TestSetEgressProxyOverridesManualMode(t *testing.T) {
	engine := newEgressTestEngine()
	engine.applyResourceSettings(nativeResourceSettings{ProxyMode: "manual", ProxyURL: "http://10.0.0.9:1080", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2})
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/x"); got == nil || got.String() != "http://127.0.0.1:7890" {
		t.Fatalf("egress override = %v, want http://127.0.0.1:7890", got)
	}
}

func TestEgressProxyBypassesLoopback(t *testing.T) {
	engine := newEgressTestEngine()
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	for _, rawURL := range []string{"http://127.0.0.1:9090/proxies", "http://localhost:7890/x", "http://[::1]:8080/x"} {
		if got := mustProxyURL(t, engine.downloader.proxyRouter, rawURL); got != nil {
			t.Fatalf("proxy(%s) = %v, want nil (loopback bypass)", rawURL, got)
		}
	}
}

func TestSetEgressProxyRejectsInvalidAddress(t *testing.T) {
	engine := newEgressTestEngine()
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	for _, bad := range []string{"ftp://127.0.0.1:21", "http://127.0.0.1:99999", "http://127.0.0.1:7890/path?x=1#frag", "not a url"} {
		if err := engine.setEgressProxy(bad); err == nil {
			t.Fatalf("setEgressProxy(%q) accepted, want rejection", bad)
		}
	}
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/x"); got == nil || got.String() != "http://127.0.0.1:7890" {
		t.Fatalf("after rejections egress = %v, want unchanged http://127.0.0.1:7890", got)
	}
}

func TestClearEgressProxyRestoresStoredMode(t *testing.T) {
	engine := newEgressTestEngine()
	engine.applyResourceSettings(nativeResourceSettings{ProxyMode: "manual", ProxyURL: "http://10.0.0.9:1080", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2})
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	if err := engine.setEgressProxy(""); err != nil {
		t.Fatalf("clear egress: %v", err)
	}
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/x"); got == nil || got.String() != "http://10.0.0.9:1080" {
		t.Fatalf("after clear = %v, want stored manual http://10.0.0.9:1080", got)
	}
}

func TestApplyResourceSettingsKeepsEgressOverride(t *testing.T) {
	engine := newEgressTestEngine()
	if err := engine.setEgressProxy("http://127.0.0.1:7890"); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	engine.applyResourceSettings(nativeResourceSettings{ProxyMode: "direct", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2})
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/x"); got == nil || got.String() != "http://127.0.0.1:7890" {
		t.Fatalf("after applyResourceSettings egress = %v, want http://127.0.0.1:7890", got)
	}
}

func TestSetEgressProxyTrimsWhitespaceAndAcceptsSocks5(t *testing.T) {
	engine := newEgressTestEngine()
	if err := engine.setEgressProxy("  socks5://10.0.0.9:1080  "); err != nil {
		t.Fatalf("setEgressProxy: %v", err)
	}
	if got := mustProxyURL(t, engine.downloader.proxyRouter, "https://example.com/x"); got == nil || got.String() != "socks5://10.0.0.9:1080" {
		t.Fatalf("egress = %v, want socks5://10.0.0.9:1080", got)
	}
}
