package core

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

func TestHongguoAppMediaRotatesOnEmptyBody(t *testing.T) {
	d, requests := hongguoRotationFixture(t, map[string]bool{"7": true}, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("rotated request did not return media", media)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "1001" {
		t.Fatal("device was not rotated", state)
	}
	if d.hongguoPlayerSuspended() {
		t.Fatal("successful rotation must not suspend the player")
	}
	if got := *requests; len(got) != 5 || got[0] != "model@7" || got[1] != "model@7" || got[2] != "model@7" || got[3] != "register" || got[4] != "model@1001" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoAppMediaRotatesOnEmptyModel(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, map[string]bool{"7": true}, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
		t.Fatal(err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "1001" {
		t.Fatal("empty model did not rotate the device", state)
	}
	if got := *requests; len(got) != 5 || got[0] != "model@7" || got[1] != "model@7" || got[2] != "model@7" || got[4] != "model@1001" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoAppMediaSuspendsOnlyAfterRotationsExhausted(t *testing.T) {
	d, requests := hongguoRotationFixture(t, map[string]bool{"7": true, "1001": true, "1002": true, "1003": true, "1004": true, "1005": true, "1006": true}, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err == nil || !strings.Contains(err.Error(), "限流") {
		t.Fatal("exhausted rotation must report rate limiting", err)
	}
	if !d.hongguoPlayerSuspended() {
		t.Fatal("suspension must start only after rotations are exhausted")
	}
	models, registers := 0, 0
	for _, r := range *requests {
		if strings.HasPrefix(r, "model@") {
			models++
		}
		if r == "register" {
			registers++
		}
	}
	if models != 2*(3+hongguoDeviceRotations) || registers != 2*hongguoDeviceRotations {
		t.Fatal("unexpected rotation counts", *requests)
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
