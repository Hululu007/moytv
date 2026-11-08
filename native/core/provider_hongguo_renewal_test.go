package core

import (
	"context"
	"strings"
	"testing"
)

func TestHongguoRefreshSkipsHealthyDevice(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	rotated, err := d.refreshHongguoDevice(context.Background())
	if err != nil || rotated {
		t.Fatal("healthy device must not rotate", rotated, err)
	}
	if len(*requests) != 0 {
		t.Fatal("healthy refresh must not call the backend", *requests)
	}
}

func TestHongguoRefreshRotatesLimitedDevice(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	d.markHongguoDeviceLimited()
	rotated, err := d.refreshHongguoDevice(context.Background())
	if err != nil || !rotated {
		t.Fatal("limited device must rotate", rotated, err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "1001" {
		t.Fatal("device was not rotated", state)
	}
	if d.hongguoDeviceLimited() {
		t.Fatal("rotated device must not stay limited")
	}
	if got := *requests; len(got) != 1 || got[0] != "register" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoRefreshRegistersUnregisteredDevice(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", false
	rotated, err := d.refreshHongguoDevice(context.Background())
	if err != nil || !rotated {
		t.Fatal("unregistered device must register", rotated, err)
	}
	if got := *requests; len(got) != 1 || got[0] != "register" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoResolveSkipsKnownLimitedDevice(t *testing.T) {
	d, requests := hongguoRotationFixture(t, map[string]bool{"7": true}, nil, false)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	d.markHongguoDeviceLimited()
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("renewed request did not return media", media)
	}
	if got := *requests; len(got) != 2 || got[0] != "register" || got[1] != "model@1001" {
		t.Fatal("known limited device must not be retried first", got)
	}
}

func TestHongguoResolveSuccessClearsLimitedAfterPausedRenewal(t *testing.T) {
	d, requests := hongguoRotationFixture(t, nil, nil, true)
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	d.markHongguoDeviceLimited()
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
		t.Fatal(err)
	}
	if d.hongguoDeviceLimited() {
		t.Fatal("recovered device must not stay limited")
	}
	if got := *requests; len(got) != 2 || got[0] != "register" || got[1] != "model@7" {
		t.Fatal("unexpected request sequence", got)
	}
}
