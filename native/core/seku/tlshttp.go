package seku

// TLS-fingerprint-impersonating HTTP transport (v2 fix, 2026-10-23).
//
// Why: Cloudflare-fronted sites (missav.ws, supjav.com) challenge the
// Go standard library's TLS ClientHello (crypto/tls has a distinctive
// JA3/JA4) even from clean IPs, while serving real browsers normally.
// The original duanju core solved the same problem with
// bogdanfinn/tls-client + uTLS (see reverse notes); this core now does
// the same for the sites that need it. Module versions are pinned in
// go.mod (tls-client v1.9.0 / fhttp v0.5.34 / utls v1.6.5, fetched via
// GOPROXY=https://goproxy.cn,direct because proxy.golang.org timed
// out from this egress).
//
// Scope: ONLY the fetch paths of CF-fronted sites call into this file
// (missavFetch, supjavFetch*). Everything else keeps the standard
// library client — impersonation is opt-in per site, per the v2 task
// contract. A cookie jar is kept so any CF-issued cookies
// (e.g. __cf_bm) persist across the multi-domain fallback retries.

import (
	"io"
	"net/http"
	"strings"
	"sync"

	fhttp "github.com/bogdanfinn/fhttp"
	tls_client "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

var (
	tlsOnce      sync.Once
	tlsFollow    tls_client.HttpClient
	tlsNoFollow  tls_client.HttpClient
	tlsClientErr error
)

func tlsHTTPClients() (tls_client.HttpClient, tls_client.HttpClient, error) {
	tlsOnce.Do(func() {
		jar := tls_client.NewCookieJar()
		mk := func(follow bool) (tls_client.HttpClient, error) {
			opts := []tls_client.HttpClientOption{
				tls_client.WithTimeoutSeconds(30),
				tls_client.WithClientProfile(profiles.Chrome_124),
				tls_client.WithCookieJar(jar),
			}
			if !follow {
				opts = append(opts, tls_client.WithNotFollowRedirects())
			}
			return tls_client.NewHttpClient(tls_client.NewNoopLogger(), opts...)
		}
		tlsFollow, tlsClientErr = mk(true)
		if tlsClientErr != nil {
			return
		}
		tlsNoFollow, tlsClientErr = mk(false)
	})
	return tlsFollow, tlsNoFollow, tlsClientErr
}

func tlsNewRequest(rawurl string, headers map[string]string) (*fhttp.Request, error) {
	req, err := fhttp.NewRequest("GET", rawurl, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	// Browser-like header ordering (fhttp honours HeaderOrderKey).
	req.Header[fhttp.HeaderOrderKey] = []string{
		"host", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
		"upgrade-insecure-requests", "user-agent", "accept",
		"sec-fetch-site", "sec-fetch-mode", "sec-fetch-user",
		"sec-fetch-dest", "referer", "accept-encoding", "accept-language",
		"cookie",
	}
	return req, nil
}

// tlsGet mirrors httpGet's signature so CF-site fetchers can swap in.
func tlsGet(rawurl string, headers map[string]string) ([]byte, int, http.Header, error) {
	follow, _, err := tlsHTTPClients()
	if err != nil {
		return nil, 0, nil, err
	}
	req, err := tlsNewRequest(rawurl, headers)
	if err != nil {
		return nil, 0, nil, err
	}
	resp, err := follow.Do(req)
	if err != nil {
		return nil, 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, resp.StatusCode, http.Header(resp.Header), err
	}
	return b, resp.StatusCode, http.Header(resp.Header), nil
}

// tlsFetchLocation mirrors supjavFetchLocation's contract: no redirect
// following; on 3xx returns (status, Location), otherwise
// (status, body text).
func tlsFetchLocation(rawurl string, headers map[string]string) (int, string) {
	_, nofollow, err := tlsHTTPClients()
	if err != nil {
		return 0, ""
	}
	req, err := tlsNewRequest(rawurl, headers)
	if err != nil {
		return 0, ""
	}
	resp, err := nofollow.Do(req)
	if err != nil || resp == nil {
		return 0, ""
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return resp.StatusCode, resp.Header.Get("Location")
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	return resp.StatusCode, string(b)
}

// tlsEnabledFor reports whether a site's fetch paths use the
// impersonated transport. Central switch for the v2 shield work:
// missav and supjav are CF-fronted; every other site stays on the
// standard client (validated as working in the batch smoke).
func tlsEnabledFor(key string) bool {
	switch strings.ToLower(key) {
	case "missav", "supjav":
		return true
	}
	return false
}
