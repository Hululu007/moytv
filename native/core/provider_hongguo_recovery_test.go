package core

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 本文件验证 2026-11-17 红果取流修复：App 腿总预算与轮换退避、
// 注册失败渐进退避、网页兜底限流倒计时等待、取流链免登入不设门。

func TestHongguoRegisterPauseBacksOffProgressively(t *testing.T) {
	want := []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 10 * time.Minute, 10 * time.Minute}
	for i, w := range want {
		if got := hongguoDeviceRegisterPauseDuration(i + 1); got != w {
			t.Fatalf("failures=%d: pause=%v, want %v", i+1, got, w)
		}
	}
	if got := hongguoDeviceRegisterPauseDuration(0); got != 30*time.Second {
		t.Fatal("non-positive failures must yield the base pause", got)
	}
}

func TestHongguoAppMediaRotationBackoffDurations(t *testing.T) {
	want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 4 * time.Second}
	for i, w := range want {
		if got := hongguoAppMediaRotationBackoff(i + 1); got != w {
			t.Fatalf("attempt=%d: backoff=%v, want %v", i+1, got, w)
		}
	}
}

func TestHongguoRegisterPauseResetsOnSuccess(t *testing.T) {
	registerFails := true
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			if registerFails {
				return sourceFixtureResponse(request, http.StatusOK, `{"device_id":0,"install_id":0}`), nil
			}
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"1001","install_id_str":"10019"}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true

	// 首败：暂停约 30 秒（不是旧的 10 分钟 flat 暂停）。
	if err := d.ensureHongguoDevice(context.Background(), "7"); err == nil {
		t.Fatal("failed registration must report an error")
	}
	if pause := time.Until(client.registerPausedUntil); pause <= 20*time.Second || pause > 31*time.Second {
		t.Fatal("first failure must pause about 30s", pause)
	}
	if client.registerPauseFailures != 1 {
		t.Fatal("failure counter must be 1", client.registerPauseFailures)
	}
	// 暂停过期后注册成功：计数清零。
	client.registerPausedUntil = time.Now().Add(-time.Second)
	registerFails = false
	if err := d.ensureHongguoDevice(context.Background(), "7"); err != nil {
		t.Fatal(err)
	}
	if client.registerPauseFailures != 0 {
		t.Fatal("successful registration must reset the failure counter", client.registerPauseFailures)
	}
	// 再败一次：暂停回到 30 秒基数，不是从 60 秒起跳。
	registerFails = true
	if err := d.ensureHongguoDevice(context.Background(), "1001"); err == nil {
		t.Fatal("failed registration must report an error")
	}
	if pause := time.Until(client.registerPausedUntil); pause <= 20*time.Second || pause > 31*time.Second {
		t.Fatal("failure after a success must pause about 30s again", pause)
	}
}

func TestHongguoAppMediaBudgetBoundsChain(t *testing.T) {
	old := hongguoAppMediaBudget
	hongguoAppMediaBudget = 200 * time.Millisecond
	defer func() { hongguoAppMediaBudget = old }()
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		<-request.Context().Done()
		return nil, request.Context().Err()
	})
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	start := time.Now()
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	elapsed := time.Since(start)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("hung app chain must end with the budget deadline", err)
	}
	if elapsed > 5*time.Second {
		t.Fatal("budget must bound the chain", elapsed)
	}
}

func TestHongguoWebFallbackWaitsOutRateLimitCountdown(t *testing.T) {
	var postCookies []string
	homes := 0
	posts := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/" {
			homes++
			resp := sourceFixtureResponse(request, http.StatusOK, "<html></html>")
			resp.Header.Set("Set-Cookie", "ttwid=s"+strconv.Itoa(homes)+"; Path=/")
			return resp, nil
		}
		if request.URL.Path == "/api/video/protected/fallback-play-info" {
			posts++
			postCookies = append(postCookies, request.Header.Get("Cookie"))
			if posts == 1 {
				resp := sourceFixtureResponse(request, http.StatusForbidden, "limited")
				resp.Header.Set("Retry-After", "1")
				return resp, nil
			}
			return sourceFixtureResponse(request, http.StatusOK, `{"main_url":"https://cdn.example.test/v.mp4"}`), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
	})
	start := time.Now()
	media, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	elapsed := time.Since(start)
	if err != nil || media.URL != "https://cdn.example.test/v.mp4" {
		t.Fatal("fallback must recover after waiting out the countdown", media, err)
	}
	if elapsed < 900*time.Millisecond {
		t.Fatal("fallback must actually wait the countdown", elapsed)
	}
	if homes != 2 || len(postCookies) != 2 || postCookies[0] != "ttwid=s1" || postCookies[1] != "ttwid=s2" {
		t.Fatal("retry after the wait must use a fresh guest session", homes, postCookies)
	}
}

func TestHongguoWebFallbackBudgetStopsWaiting(t *testing.T) {
	old := hongguoWebFallbackWaitBudget
	hongguoWebFallbackWaitBudget = 100 * time.Millisecond
	defer func() { hongguoWebFallbackWaitBudget = old }()
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/" {
			resp := sourceFixtureResponse(request, http.StatusOK, "<html></html>")
			resp.Header.Set("Set-Cookie", "ttwid=s1; Path=/")
			return resp, nil
		}
		if request.URL.Path == "/api/video/protected/fallback-play-info" {
			resp := sourceFixtureResponse(request, http.StatusForbidden, "limited")
			resp.Header.Set("Retry-After", "30")
			return resp, nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
	})
	start := time.Now()
	_, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
	elapsed := time.Since(start)
	if err == nil || !errors.Is(err, errHongguoWebFallbackUnavailable) {
		t.Fatal("budget exhaustion must report unavailability", err)
	}
	if elapsed > 5*time.Second {
		t.Fatal("budget must stop the wait", elapsed)
	}
}

// TestHongguoMediaIgnoresLoginSession：取流链不以登入为门槛——
// 即便账号会话已登录（Cookie 已种进罐），App 腿与网页兜底发出的请求
// 也不带登录 Cookie、不用账号设备号；登录状态不改变取流行为。
func TestHongguoMediaIgnoresLoginSession(t *testing.T) {
	login := hongguoAccountSession{Cookie: "sessionid=abc123", DeviceID: "999", InstallID: "999", Source: hongguoAccountCookieWebSource}

	t.Run("app legs", func(t *testing.T) {
		var cookies []string
		var devices []string
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			cookies = append(cookies, request.Header.Get("Cookie"))
			devices = append(devices, request.URL.Query().Get("device_id"))
			return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
		})
		client := d.hongguoClient()
		client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
		d.setHongguoAccountSession(login)
		if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
			t.Fatal(err)
		}
		if len(cookies) == 0 {
			t.Fatal("no app request was issued")
		}
		for _, cookie := range cookies {
			if strings.Contains(cookie, "sessionid") {
				t.Fatal("app media request must not carry the login cookie", cookies)
			}
		}
		for _, device := range devices {
			if device != "7" {
				t.Fatal("app media request must use the catalog device, not the account device", devices)
			}
		}
	})

	t.Run("web fallback", func(t *testing.T) {
		var postCookies []string
		d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
			if strings.Contains(request.Header.Get("Cookie"), "sessionid") {
				t.Error("no media request may carry the login cookie", request.URL.Path)
			}
			if request.URL.Path == "/" {
				resp := sourceFixtureResponse(request, http.StatusOK, "<html></html>")
				resp.Header.Set("Set-Cookie", "ttwid=s1; Path=/")
				return resp, nil
			}
			if request.URL.Path == "/api/video/protected/fallback-play-info" {
				postCookies = append(postCookies, request.Header.Get("Cookie"))
				return sourceFixtureResponse(request, http.StatusOK, `{"main_url":"https://cdn.example.test/v.mp4"}`), nil
			}
			return sourceFixtureResponse(request, http.StatusInternalServerError, ""), nil
		})
		client := d.hongguoClient()
		client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
		d.setHongguoAccountSession(login)
		media, err := d.resolveHongguoWebFallback(context.Background(), "111", "222")
		if err != nil || media.URL != "https://cdn.example.test/v.mp4" {
			t.Fatal("fallback must succeed on the guest session", media, err)
		}
		if len(postCookies) != 1 || postCookies[0] != "ttwid=s1" {
			t.Fatal("fallback post must carry only the guest session", postCookies)
		}
	})
}
