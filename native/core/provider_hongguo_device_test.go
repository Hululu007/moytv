package core

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func hongguoDeviceFixture(t *testing.T, rejected map[string]bool, registerFails bool) (*Downloader, *[]string) {
	var requests []string
	registered := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.String() == hongguoDeviceRegisterURL+"?"+request.URL.RawQuery {
			registered++
			requests = append(requests, "register")
			// 注册请求不带旧设备号查询参数，但必须带播放器签名头（用注册前本地占位设备号签）。
			if request.URL.Query().Get("device_id") != "" || request.Header.Get("X-Argus") == "" || request.Header.Get("X-Gorgon") == "" || request.Header.Get("X-Medusa") == "" {
				t.Error("device registration must not leak an old device id, but must carry a player signature")
			}
			if registerFails {
				return sourceFixtureResponse(request, http.StatusOK, `{"device_id":0,"install_id":0}`), nil
			}
			id := strconv.Itoa(1000 + registered)
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"`+id+`","install_id_str":"`+id+`9"}`), nil
		}
		device := request.URL.Query().Get("device_id")
		requests = append(requests, "detail@"+device)
		if rejected[device] {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	d.cfg.Retries = 2
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", false
	return d, &requests
}

func TestHongguoSignedRequestKeepsCurrentDevice(t *testing.T) {
	d, requests := hongguoDeviceFixture(t, nil, false)
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" || state.Registered {
		t.Fatal("signed request changed the device", state)
	}
	if got := *requests; len(got) != 1 || got[0] != "detail@7" {
		t.Fatal("unexpected request sequence", got)
	}
}

// TestHongguoPlayerSuspendOnEmptyBody 验证：玩家 App 端点（/player/）空 body 时开启
// 60s 负缓存窗口；清除后关闭；且 window 语义正确（挂起判断为纯状态读取，无副作用）。
func TestHongguoPlayerSuspendOnEmptyBody(t *testing.T) {
	playerPath := "/novel/player/video_detail/v1/"
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "/player/") {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil // 玩家端点空 body
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true

	if d.hongguoPlayerSuspended() {
		t.Fatal("初始不应处于挂起窗口")
	}
	// 玩家端点空 body → 挂起窗口开启（hongguoAppRequest 内部触发 markHongguoPlayerSuspended）
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, playerPath, nil, map[string]any{"series_id": "1"}); err == nil {
		t.Fatal("空 body 玩家请求应返回错误")
	}
	if !d.hongguoPlayerSuspended() {
		t.Fatal("玩家端点空 body 后未开启负缓存窗口")
	}
	// 清除后关闭
	d.clearHongguoPlayerSuspended()
	if d.hongguoPlayerSuspended() {
		t.Fatal("清除后仍处挂起窗口")
	}
}

func TestHongguoDeviceRegistrationReplacesDevice(t *testing.T) {
	d, requests := hongguoDeviceFixture(t, nil, false)
	if err := d.ensureHongguoDevice(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if err := d.ensureHongguoDevice(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if state := d.hongguoCatalogSnapshot(); !state.Registered || state.DeviceID != "1001" || state.InstallID != "10019" {
		t.Fatal("registered device was not kept", state)
	}
	if err := d.ensureHongguoDevice(context.Background(), "1001"); err != nil {
		t.Fatal(err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "1002" {
		t.Fatal("rejected device was not replaced", state)
	}
	if got := *requests; len(got) != 2 || got[0] != "register" || got[1] != "register" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoTabRejectionKeepsDevice(t *testing.T) {
	d, requests := hongguoDeviceFixture(t, map[string]bool{"7": true}, false)
	d.cfg.Retries = 1
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodGet, hongguoBookmallTabPath, nil, nil); err == nil {
		t.Fatal("empty tab response became a success")
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" || state.Registered {
		t.Fatal("unsigned tab request changed the device", state)
	}
	if got := *requests; len(got) != 1 || got[0] != "detail@7" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoDeviceStatusTruncatesIDs(t *testing.T) {
	d, _ := hongguoDeviceFixture(t, nil, false)
	client := d.hongguoClient()
	client.mu.Lock()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "1234567890123456789", "9876543210987654321", true
	client.deviceLimited = true
	client.mu.Unlock()
	status := d.hongguoDeviceStatus()
	if status["deviceId"] != "123456…6789" || status["installId"] != "987654…4321" {
		t.Fatal("device status leaked full ids or truncated wrong", status)
	}
	if status["registered"] != true || status["limited"] != true {
		t.Fatal("device status flags wrong", status)
	}
}

func TestHongguoDeviceReregisterReplacesCurrent(t *testing.T) {
	d, requests := hongguoDeviceFixture(t, nil, false)
	if err := d.reregisterHongguoDevice(context.Background()); err != nil {
		t.Fatal(err)
	}
	if state := d.hongguoCatalogSnapshot(); !state.Registered || state.DeviceID != "1001" {
		t.Fatal("reregister did not register", state)
	}
	if err := d.ensureHongguoDevice(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if got := *requests; len(got) != 1 || got[0] != "register" {
		t.Fatal("registered device re-registered on plain ensure", got)
	}
}

func TestHongguoRegisterFailurePausesAndKeepsOldDevice(t *testing.T) {
	d, requests := hongguoDeviceFixture(t, nil, true)
	for range 2 {
		if err := d.ensureHongguoDevice(context.Background(), ""); err == nil {
			t.Fatal("failed registration reported success")
		}
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" || state.Registered {
		t.Fatal("failed registration changed the device", state)
	}
	if got := *requests; len(got) != 1 || got[0] != "register" {
		t.Fatal("registration was not paused after failure", got)
	}
}
