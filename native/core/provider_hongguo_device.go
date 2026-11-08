package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

const (
	hongguoDeviceRegisterURL   = "https://log.snssdk.com/service/2/device_register/"
	hongguoDeviceRotations     = 3
	hongguoDeviceRegisterPause = 10 * time.Minute
)

func (downloader *Downloader) ensureHongguoDevice(ctx context.Context, rejected string) error {
	client := downloader.hongguoClient()
	client.deviceMu.Lock()
	defer client.deviceMu.Unlock()
	client.mu.Lock()
	current, registered := client.state.DeviceID, client.state.Registered
	client.mu.Unlock()
	if rejected == "" && registered || rejected != "" && rejected != current {
		return nil
	}
	if time.Now().Before(client.registerPausedUntil) {
		return errors.New("红果设备注册暂不可用")
	}
	deviceID, installID, err := downloader.registerHongguoDevice(ctx)
	if err != nil {
		if ctx.Err() == nil {
			client.registerPausedUntil = time.Now().Add(hongguoDeviceRegisterPause)
		}
		return err
	}
	client.mu.Lock()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = deviceID, installID, true
	client.deviceLimited = false
	client.mu.Unlock()
	return nil
}

func truncateHongguoDeviceID(id string) string {
	if len(id) > 10 {
		return id[:6] + "…" + id[len(id)-4:]
	}
	if len(id) > 4 {
		return "…" + id[len(id)-4:]
	}
	if id == "" {
		return ""
	}
	return "****"
}

func (downloader *Downloader) hongguoDeviceStatus() map[string]any {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return map[string]any{
		"registered": client.state.Registered,
		"limited":    client.deviceLimited,
		"hasDevice":  client.state.DeviceID != "",
		"deviceId":   truncateHongguoDeviceID(client.state.DeviceID),
		"installId":  truncateHongguoDeviceID(client.state.InstallID),
	}
}

func (downloader *Downloader) reregisterHongguoDevice(ctx context.Context) error {
	current := downloader.hongguoDeviceID()
	if current == "" {
		return downloader.ensureHongguoDevice(ctx, "")
	}
	return downloader.ensureHongguoDevice(ctx, current)
}

func (downloader *Downloader) hongguoDeviceLimited() bool {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.deviceLimited
}

func (downloader *Downloader) markHongguoDeviceLimited() {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	client.deviceLimited = true
}

func (downloader *Downloader) clearHongguoDeviceLimited() {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	client.deviceLimited = false
}

func (downloader *Downloader) refreshHongguoDevice(ctx context.Context) (bool, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	current, registered, limited := client.state.DeviceID, client.state.Registered, client.deviceLimited
	client.mu.Unlock()
	if !registered {
		if err := downloader.ensureHongguoDevice(ctx, ""); err != nil {
			return false, err
		}
		return true, nil
	}
	if !limited {
		return false, nil
	}
	if err := downloader.ensureHongguoDevice(ctx, current); err != nil {
		return false, err
	}
	return true, nil
}

func (downloader *Downloader) hongguoDeviceID() string {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.state.DeviceID
}

func (downloader *Downloader) registerHongguoDevice(ctx context.Context) (string, string, error) {
	header := map[string]any{
		"display_name": "红果免费短剧", "aid": 8662, "app_version": "7.3.5.32", "version_code": 73532,
		"manifest_version_code": 73532, "update_version_code": 73532, "channel": "update_64", "package": "com.phoenix.read",
		"app_language": "zh", "os": "Android", "os_version": "16", "os_api": 36, "device_model": "25053RT47C",
		"device_brand": "Redmi", "device_manufacturer": "Xiaomi", "cpu_abi": "arm64-v8a", "density_dpi": 520,
		"display_density": "xxhdpi", "resolution": "2772x1280", "language": "zh", "timezone": 8, "access": "wifi",
		"openudid": randomHex(8), "clientudid": uuidLike(), "cdid": uuidLike(),
		"region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800, "sim_region": "cn", "device_platform": "android",
		"not_request_sender": 0, "is_system_app": 0, "sdk_flavor": "china", "rom": "OS2.0", "rom_version": "BP2A.250605.031.A3",
	}
	body, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": time.Now().UnixMilli()})
	if err != nil {
		return "", "", err
	}
	query := hongguoAppQuery("", "")
	query.Del("device_id")
	query.Del("iid")
	query.Set("req_id", uuidLike())
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoDeviceRegisterURL, bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
		query.Set("_rticket", strconv.FormatInt(time.Now().UnixMilli(), 10))
		prepared.URL.RawQuery = query.Encode()
	})
	if err != nil {
		return "", "", err
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	response.Body.Close()
	if err != nil {
		return "", "", err
	}
	if response.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("红果设备注册 HTTP %d", response.StatusCode)
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return "", "", errors.New("红果设备注册返回格式异常")
	}
	deviceID, installID := mapString(result, "device_id_str", "device_id"), mapString(result, "install_id_str", "install_id")
	if !hongguoNumericID.MatchString(deviceID) || !hongguoNumericID.MatchString(installID) || deviceID == "0" || installID == "0" {
		return "", "", errors.New("红果设备注册未返回设备号")
	}
	return deviceID, installID, nil
}
