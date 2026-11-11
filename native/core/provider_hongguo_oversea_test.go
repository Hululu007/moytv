package core

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func hongguoOverseaFixture(t *testing.T, mainlandStatus int, mainlandBody string) (*Downloader, *[]string) {
	var requests []string
	registered := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			registered++
			requests = append(requests, "register")
			id := strconv.Itoa(1000 + registered)
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"`+id+`","install_id_str":"`+id+`9"}`), nil
		}
		host := request.URL.Host
		requests = append(requests, "model@"+host)
		if host == "api5-normal-sinfonlinea.fqnovel.com" {
			return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
		}
		return sourceFixtureResponse(request, mainlandStatus, mainlandBody), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	return d, &requests
}

func TestHongguoAppMediaFallsBackToOverseaLine(t *testing.T) {
	d, requests := hongguoOverseaFixture(t, http.StatusOK, "")
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("oversea line did not return media", media)
	}
	if d.hongguoPlayerSuspended() {
		t.Fatal("oversea fallback success must not suspend the player")
	}
	mainland, oversea := 0, 0
	for _, r := range *requests {
		if r == "model@api5-normal-sinfonlineb.fqnovel.com" {
			mainland++
		}
		if r == "model@api5-normal-sinfonlinea.fqnovel.com" {
			oversea++
		}
	}
	if mainland != 3+hongguoDeviceRotations || oversea != 1 {
		t.Fatal("unexpected line fallback counts", *requests)
	}
}

func TestHongguoAppMediaMainlandSuccessSkipsOverseaLine(t *testing.T) {
	d, requests := hongguoOverseaFixture(t, http.StatusOK, hongguoRotationModelOK)
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
		t.Fatal(err)
	}
	for _, r := range *requests {
		if strings.Contains(r, "sinfonlinea") {
			t.Fatal("mainland success must not touch the oversea line", *requests)
		}
	}
}

func TestHongguoAppMediaNonEmptyErrorSkipsOverseaLine(t *testing.T) {
	d, requests := hongguoOverseaFixture(t, http.StatusInternalServerError, "boom")
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Fatal("expected mainland HTTP 500 error", err)
	}
	for _, r := range *requests {
		if strings.Contains(r, "sinfonlinea") {
			t.Fatal("non-empty mainland error must not fall back to the oversea line", *requests)
		}
	}
}
