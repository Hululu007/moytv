package seku

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// v33 回归：一张废票绝不能把整个 host 打死。
//
// 现场是 whos / 123av 报 451——票是「主机 + cf_clearance + 签发 UA」三元组，
// Cloudflare 还会绑出口 IP，用户换节点之后票就废了。旧实现无条件先带票，
// CF 见到不匹配的 cf_clearance 直接 451，连挑战页都不给，App 也就没法解盾。
//
// 现在必须是：裸连 -> 被挡才带票 -> 还不行就当场把票作废。
func TestHttpDoBareFirstThenTicketThenForget(t *testing.T) {
	var mu sync.Mutex
	var calls []string
	var forgotten string

	SetShieldBridge(func(host string) (string, string, bool) {
		return "cf_clearance=stale", "UA-from-browser", true
	}, nil)
	SetShieldForget(func(host string) {
		mu.Lock()
		forgotten = host
		mu.Unlock()
	})
	defer func() {
		SetShieldBridge(nil, nil)
		SetShieldForget(nil)
	}()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ck := r.Header.Get("Cookie")
		mu.Lock()
		calls = append(calls, ck)
		mu.Unlock()
		if ck == "" {
			_, _ = w.Write([]byte(`<html><head><title>Just a moment...</title></head>` +
				`<body><script>window.cf_chl_opt={}</script></body></html>`))
			return
		}
		w.WriteHeader(http.StatusUnavailableForLegalReasons)
		_, _ = w.Write([]byte("blocked"))
	}))
	defer srv.Close()

	body, code, _, _ := httpDo(http.MethodGet, srv.URL+"/new/", nil, nil)

	if len(calls) != 2 {
		t.Fatalf("want bare+retry = 2 requests, got %d (%v)", len(calls), calls)
	}
	if calls[0] != "" {
		t.Fatalf("first request must be bare (no ticket), got cookie %q", calls[0])
	}
	if calls[1] == "" {
		t.Fatalf("second request should retry with the ticket")
	}
	// 两次都过不去：把裸连拿到的挑战页原样交回去（站点/App 靠它识别盾），
	// 而不是伪装成 451 让上层以为站点废了。
	if code != http.StatusOK || !zkShieldIsChallenge(string(body)) {
		t.Fatalf("challenge page should be surfaced, got code=%d body=%q", code, string(body))
	}
	mu.Lock()
	got := forgotten
	mu.Unlock()
	if got != "127.0.0.1" {
		t.Fatalf("rejected ticket must be forgotten for its host, got %q", got)
	}
}

// 裸连本来就通，票连碰都不许碰——这是「没有盾的站被加了盾」的直接原因。
func TestHttpDoHealthyHostNeverSendsTicket(t *testing.T) {
	var mu sync.Mutex
	var calls []string

	SetShieldBridge(func(host string) (string, string, bool) {
		return "cf_clearance=stale", "UA-from-browser", true
	}, nil)
	defer SetShieldBridge(nil, nil)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls = append(calls, r.Header.Get("Cookie"))
		mu.Unlock()
		_, _ = w.Write([]byte(`<html><body><a href="/view/?id=a1">ok</a></body></html>`))
	}))
	defer srv.Close()

	body, code, _, err := httpDo(http.MethodGet, srv.URL+"/new/", nil, nil)
	if err != nil || code != http.StatusOK {
		t.Fatalf("healthy host failed: code=%d err=%v", code, err)
	}
	if len(calls) != 1 || calls[0] != "" {
		t.Fatalf("healthy host must see exactly one bare request, got %v", calls)
	}
	if len(body) == 0 {
		t.Fatal("body must come through")
	}
}

// 中转拿回来的盾页/限流页不许顶替真实响应：它会被解析成空列表，
// 表现成「站点坏了」。502 必须原样交给站点自己的镜像逻辑。
func TestHttpDoDoesNotReplaceErrorWithShieldPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	_, code, _, _ := httpDo(http.MethodGet, srv.URL+"/new/", nil, nil)
	if code != http.StatusBadGateway {
		t.Fatalf("502 must be surfaced as-is, got %d", code)
	}
}

func TestIsShieldPage(t *testing.T) {
	cases := map[string]bool{
		"":                                               true,
		`<title>This website has been temporarily rate limited | tv506.ystv.top | Cloudflare</title>`: true,
		`<html><body><a href="/v/1">正常列表</a></body></html>`:                                        false,
	}
	for body, want := range cases {
		if got := isShieldPage(body); got != want {
			t.Fatalf("isShieldPage(%q) = %v, want %v", body, got, want)
		}
	}
}
