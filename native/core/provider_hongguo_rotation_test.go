package core

// V5 policy: an empty body or an empty model no longer rotates the device.
// Upstream v5_playback swaps devices only on HTTP 401/403; empty responses
// fail fast (with the suspend window for the next call) and the caller falls
// through to the web fallback. The rotation-behavior tests below were
// rewritten to pin the new policy; hongguoRotationFixture stays because the
// renewal tests reuse it.

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

const hongguoRotationModelOK = `{"code":0,"data":{"video_model":{"video_list":[{"main_url":"https://media.example.test/high.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}}}`

func hongguoRotationFixture(t *testing.T, emptyDevices map[string]bool, emptyModelDevices map[string]bool, registerFails bool) (*Downloader, *[]string) {
	var requests []string
	registered := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			registered++
			requests = append(requests, "register")
			if registerFails {
				return sourceFixtureResponse(request, http.StatusOK, `{"device_id":0,"install_id":0}`), nil
			}
			id := strconv.Itoa(1000 + registered)
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"`+id+`","install_id_str":"`+id+`9"}`), nil
		}
		device := request.URL.Query().Get("device_id")
		requests = append(requests, "model@"+device)
		if emptyDevices[device] {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}
		if emptyModelDevices[device] {
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
	})
	d.cfg.Retries = 1
	return d, &requests
}

func TestHongguoAppMediaEmptyBodyFailsWithoutRotation(t *testing.T) {
	d, requests := hongguoRotationFixture(t, map[string]bool{"7": true}, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err == nil || !strings.Contains(err.Error(), "限流") {
		t.Fatal("empty body must report rate limiting", err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("empty body must not rotate the device", state)
	}
	if !d.hongguoPlayerSuspended() {
		t.Fatal("empty body must open the suspend window")
	}
	if got := *requests; len(got) != 1 || got[0] != "model@7" {
		t.Fatal("empty body must cost exactly one request", got)
	}
}

func TestHongguoAppMediaEmptyModelFailsWithoutRotation(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, map[string]bool{"7": true}, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err == nil {
		t.Fatal("empty model must fail")
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("empty model must not rotate the device", state)
	}
	if got := *requests; len(got) != 1 || got[0] != "model@7" {
		t.Fatal("empty model must cost exactly one request", got)
	}
}

func TestHongguoAppMediaRegisterFailureDoesNotStream(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, nil, true)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", false
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err == nil {
		t.Fatal("failed registration must not stream silently")
	}
	for _, r := range *requests {
		if strings.HasPrefix(r, "model@") {
			t.Fatal("streamed with an unregistered device", *requests)
		}
	}
}
