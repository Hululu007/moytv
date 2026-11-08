package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

type hongguoWebPostCall struct {
	cookie     string
	definition string
}

type hongguoWebStub struct {
	homeCookies []string
	homeCalls   int
	postCalls   []hongguoWebPostCall
	postBodies  []string
	postStatus  []int
	headStatus  int
	headLength  int64
	headCalls   int
	appStatus   int
	appBody     string
	paths       []string
}

func (stub *hongguoWebStub) handler(request *http.Request) (*http.Response, error) {
	stub.paths = append(stub.paths, request.URL.Path)
	if request.Method == http.MethodHead && strings.HasPrefix(request.URL.Path, "/video/public/") {
		stub.headCalls++
		resp := sourceFixtureResponse(request, stub.headStatus, "")
		resp.ContentLength = stub.headLength
		return resp, nil
	}
	if request.URL.Path == "/" {
		cookie := ""
		if stub.homeCalls < len(stub.homeCookies) {
			cookie = stub.homeCookies[stub.homeCalls]
		} else if len(stub.homeCookies) > 0 {
			cookie = stub.homeCookies[len(stub.homeCookies)-1]
		}
		stub.homeCalls++
		resp := sourceFixtureResponse(request, http.StatusOK, "<html></html>")
		if cookie != "" {
			resp.Header.Set("Set-Cookie", "ttwid="+cookie+"; Path=/")
		}
		return resp, nil
	}
	if request.URL.Path == "/api/video/protected/fallback-play-info" {
		body, _ := io.ReadAll(request.Body)
		var payload map[string]string
		_ = json.Unmarshal(body, &payload)
		stub.postCalls = append(stub.postCalls, hongguoWebPostCall{cookie: request.Header.Get("Cookie"), definition: payload["definition"]})
		idx := len(stub.postCalls) - 1
		status := http.StatusOK
		if idx < len(stub.postStatus) && stub.postStatus[idx] != 0 {
			status = stub.postStatus[idx]
		}
		payloadBody := ""
		if idx < len(stub.postBodies) {
			payloadBody = stub.postBodies[idx]
		}
		return sourceFixtureResponse(request, status, payloadBody), nil
	}
	if strings.Contains(request.URL.Path, "video_model") {
		return sourceFixtureResponse(request, stub.appStatus, stub.appBody), nil
	}
	if strings.Contains(request.URL.Path, "device_register") {
		return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
	}
	if strings.HasPrefix(request.URL.Path, "/player/") {
		return sourceFixtureResponse(request, http.StatusOK, "<html></html>"), nil
	}
	return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
}

func TestHongguoWebSessionCachedWithinTTL(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1"}}
	d := sourceFixtureDownloader(t, stub.handler)
	first, err := d.hongguoWebSession(context.Background(), false)
	if err != nil || first != "ttwid=s1" {
		t.Fatal("first session must come from homepage", first, err)
	}
	second, err := d.hongguoWebSession(context.Background(), false)
	if err != nil || second != "ttwid=s1" {
		t.Fatal("second session must reuse cache", second, err)
	}
	if stub.homeCalls != 1 {
		t.Fatal("cached session must not refetch homepage", stub.homeCalls)
	}
}

func TestHongguoWebFallbackSuccessAndCache(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1"}, postBodies: []string{`{"main_url":"https://cdn.example.test/v.mp4"}`}}
	d := sourceFixtureDownloader(t, stub.handler)
	media, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	if err != nil || media.URL != "https://cdn.example.test/v.mp4" {
		t.Fatal("fallback must return media url", media, err)
	}
	if media.Referer != hongguoBaseURL+"/" {
		t.Fatal("fallback media must carry site referer", media)
	}
	again, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	if err != nil || again.URL != media.URL {
		t.Fatal("cached media must be reused", again, err)
	}
	if len(stub.postCalls) != 1 || stub.homeCalls != 1 {
		t.Fatal("cached resolve must not issue new requests", stub.postCalls, stub.homeCalls)
	}
}

func TestHongguoWebFallbackRefreshesSessionOnUnavailable(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1", "s2"}, postBodies: []string{`{"error":"public_fallback_unavailable"}`, `{"main_url":"https://cdn.example.test/v.mp4"}`}}
	d := sourceFixtureDownloader(t, stub.handler)
	media, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	if err != nil || media.URL != "https://cdn.example.test/v.mp4" {
		t.Fatal("refreshed session must recover media", media, err)
	}
	if stub.homeCalls != 2 {
		t.Fatal("unavailable must trigger a fresh session", stub.homeCalls)
	}
	if len(stub.postCalls) != 2 || stub.postCalls[0].cookie != "ttwid=s1" || stub.postCalls[1].cookie != "ttwid=s2" {
		t.Fatal("posts must use successive sessions", stub.postCalls)
	}
}

func TestHongguoWebFallbackPublicProbe(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1", "s2", "s3", "s4"}, postBodies: []string{`{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`}, headStatus: http.StatusOK, headLength: 100000}
	d := sourceFixtureDownloader(t, stub.handler)
	media, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	if err != nil {
		t.Fatal(err)
	}
	want := hongguoBaseURL + "/video/public/222/720p.mp4"
	if media.URL != want {
		t.Fatal("public probe must prefer 720p", media)
	}
	if stub.headCalls != 1 {
		t.Fatal("public probe must stop at first hit", stub.headCalls)
	}
	if len(stub.postCalls) != 4 {
		t.Fatal("fallback posts must be capped", len(stub.postCalls))
	}
}

func TestHongguoWebFallbackAllFail(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1", "s2", "s3", "s4"}, postBodies: []string{`{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`}, headStatus: http.StatusNotFound}
	d := sourceFixtureDownloader(t, stub.handler)
	_, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	if err == nil || !errors.Is(err, errHongguoWebFallbackUnavailable) {
		t.Fatal("exhausted fallback must report unavailability", err)
	}
}

func TestHongguoResolveUsesWebFallbackAfterAppFailure(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1"}, postBodies: []string{`{"main_url":"https://cdn.example.test/v.mp4"}`}, appStatus: http.StatusInternalServerError}
	d := sourceFixtureDownloader(t, stub.handler)
	task := Task{DramaID: providerDramaID(sourceHongguo, "111"), Chapter: Chapter{VideoURL: "hongguo-cenc://222"}}
	media, err := d.resolveHongguoMedia(context.Background(), task)
	if err != nil || media.URL != "https://cdn.example.test/v.mp4" {
		t.Fatal("chain must fall back to web tier after app failure", media, err)
	}
	for _, path := range stub.paths {
		if strings.HasPrefix(path, "/player/") || strings.Contains(path, "hongguo/play") {
			t.Fatal("successful fallback must not reach later tiers", stub.paths)
		}
	}
}

func TestHongguoResolveJointErrorMentionsThrottling(t *testing.T) {
	stub := &hongguoWebStub{homeCookies: []string{"s1", "s2", "s3", "s4"}, postBodies: []string{`{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`, `{"error":"public_fallback_unavailable"}`}, headStatus: http.StatusNotFound, appStatus: http.StatusInternalServerError}
	d := sourceFixtureDownloader(t, stub.handler)
	task := Task{DramaID: providerDramaID(sourceHongguo, "111"), Chapter: Chapter{VideoURL: "hongguo-cenc://222"}}
	_, err := d.resolveHongguoMedia(context.Background(), task)
	if err == nil {
		t.Fatal("all tiers failed must return an error")
	}
	text := err.Error()
	if !strings.Contains(text, "App 取流失败") || !strings.Contains(text, "网页兜底取流失败") || !strings.Contains(text, "网页取流失败") || strings.Contains(text, "备用取流失败") || !strings.Contains(text, "限流") {
		t.Fatal("joint error must name tiers and throttling honestly", text)
	}
}
