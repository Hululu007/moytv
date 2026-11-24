package core

// Anonymous playback device registration and process-local caching.
//
// Go port of upstream fqapp upstream/playback_identity.rs (bef83c90),
// itself ported from Amor5207/lvguo-tv v2.0.8 (minireel_single_model.go,
// passport_device.go, passport_sign.go). The wire constants and field
// layout are kept byte-for-byte.
//
// This identity is deliberately separate from the pooled main device: it
// exists only for playback, is never persisted, and its refresh policy is
// owned here instead of being inferred from pooled-device usage. The state
// lives on the hongguoAppClient (one per Downloader); upstream keeps the
// instance in server state, which this tree does not have.

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	hongguoAnonRegisterBase = "https://log5-applog-lq.fqnovel.com"
	hongguoAnonActivateBase = "https://log5-applog-lf.fqnovel.com"
	hongguoAnonRegisterPath = "/service/2/device_register/"
	hongguoAnonActivatePath = "/service/2/app_alert_check/"
	hongguoAnonUserAgent    = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"
	// hongguoAnonIdentityTTL: a registered anonymous device is reused for
	// two hours before it is re-registered.
	hongguoAnonIdentityTTL = 2 * time.Hour
	// hongguoAnonRegisterBackoff: after a failed registration, wait 30s
	// before trying again.
	hongguoAnonRegisterBackoff = 30 * time.Second
	// hongguoAnonEmptyRefreshInterval: an empty response refreshes the
	// identity at most once per ten minutes.
	hongguoAnonEmptyRefreshInterval = 10 * time.Minute
	// hongguoAnonRegisterTimeout: registration must answer within 4s.
	hongguoAnonRegisterTimeout = 4 * time.Second
	// hongguoAnonActivationTimeout: the app_alert_check activation call,
	// whose result is ignored.
	hongguoAnonActivationTimeout = 1 * time.Second
	hongguoAnonResponseLimit     = 4 << 20
)

const hongguoTTFixedStringB64 = "TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA=="

var hongguoTTMagic = [6]byte{0x74, 0x63, 0x05, 0x10, 0x00, 0x00}

// hongguoTTEncrypt: key/iv = SHA512(SHA512(random32) + fixedString)[0:16],
// [16:32]. Output = magic + random32 +
// AES-128-CBC(PKCS7(SHA512(data) + data)).
func hongguoTTEncrypt(data []byte, seed [32]byte) ([]byte, error) {
	fixed, err := base64.StdEncoding.DecodeString(hongguoTTFixedStringB64)
	if err != nil {
		return nil, err
	}
	inner := sha512.Sum512(seed[:])
	derived := sha512.New()
	derived.Write(inner[:])
	derived.Write(fixed)
	hv := derived.Sum(nil)
	key, iv := hv[:16], hv[16:32]

	dataHash := sha512.Sum512(data)
	hashed := append(append([]byte(nil), dataHash[:]...), data...)
	padded := hongguoPKCS7Pad(hashed, 16)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	encrypted := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, padded)

	out := append(append([]byte(nil), hongguoTTMagic[:]...), seed[:]...)
	out = append(out, encrypted...)
	return out, nil
}

// hongguoNormalizeTTGzipHeader: the playback device_register profile uses a
// deterministic ten-byte gzip header while the deflate payload is produced
// by the gzip writer. The header carries no authenticated data, so replacing
// it keeps the compressed stream valid and matches the wire bytes the
// reference implementation signs.
func hongguoNormalizeTTGzipHeader(data []byte) ([]byte, error) {
	if len(data) < 10 || data[0] != 0x1f || data[1] != 0x8b {
		return nil, errors.New("TTEncrypt gzip body is invalid")
	}
	out := append([]byte(nil), data...)
	copy(out[:10], []byte{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0})
	return out, nil
}

// hongguoTTDecryptResponse: the envelope is magic || seed[32] ||
// AES-128-CBC(SHA512(gzip) || gzip). The key is derived from the same
// seed/fixed-string pair as request encryption, and the inner SHA-512
// authenticates the compressed bytes before they are inflated.
func hongguoTTDecryptResponse(data []byte) ([]byte, error) {
	const minResponseLen = 38 + 64 + 16
	const maxResponseGunzip = 4 << 20
	if len(data) < minResponseLen || !bytes.HasPrefix(data, hongguoTTMagic[:]) || (len(data)-38)%16 != 0 {
		return nil, errors.New("TTEncrypt response envelope is invalid")
	}
	var seed [32]byte
	copy(seed[:], data[6:38])
	fixed, err := base64.StdEncoding.DecodeString(hongguoTTFixedStringB64)
	if err != nil {
		return nil, err
	}
	inner := sha512.Sum512(seed[:])
	derived := sha512.New()
	derived.Write(inner[:])
	derived.Write(fixed)
	hv := derived.Sum(nil)
	key, iv := hv[:16], hv[16:32]

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(data)-38)
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, data[38:])
	unpadded, err := hongguoPKCS7UnpadStrict(plain, 16)
	if err != nil {
		return nil, err
	}
	if len(unpadded) < 64 {
		return nil, errors.New("TTEncrypt response payload is invalid")
	}
	expected := sha512.Sum512(unpadded[64:])
	if !bytes.Equal(expected[:], unpadded[:64]) {
		return nil, errors.New("TTEncrypt response checksum mismatch")
	}
	return hongguoGunzipCapped(unpadded[64:], maxResponseGunzip)
}

func hongguoPKCS7Pad(data []byte, block int) []byte {
	pad := block - (len(data) % block)
	out := append(append([]byte(nil), data...), bytes.Repeat([]byte{byte(pad)}, pad)...)
	return out
}

func hongguoPKCS7UnpadStrict(data []byte, block int) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("pkcs7: empty input")
	}
	if len(data)%block != 0 {
		return nil, fmt.Errorf("pkcs7: input length %d not a multiple of block %d", len(data), block)
	}
	pad := int(data[len(data)-1])
	if pad == 0 || pad > block || pad > len(data) {
		return nil, fmt.Errorf("pkcs7: invalid pad length %d", pad)
	}
	for _, b := range data[len(data)-pad:] {
		if int(b) != pad {
			return nil, errors.New("pkcs7: invalid pad bytes")
		}
	}
	return data[:len(data)-pad], nil
}

func hongguoGunzipCapped(data []byte, limit int) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	out, err := io.ReadAll(io.LimitReader(reader, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(out) > limit {
		return nil, errors.New("TTEncrypt response gunzip: over limit")
	}
	return out, nil
}

// hongguoAnonDevice: the registered anonymous playback device.
type hongguoAnonDevice struct {
	DeviceID   string
	InstallID  string
	CDID       string
	OpenUDID   string
	ClientUDID string
	EGDI       string
}

func (device hongguoAnonDevice) playbackIdentity() hongguoAnonV5Identity {
	return hongguoAnonV5Identity{DeviceID: device.DeviceID, InstallID: device.InstallID, CDID: device.CDID, EGDI: device.EGDI}
}

type hongguoAnonIdentityState struct {
	mu                   sync.Mutex
	device               *hongguoAnonDevice
	expiresAt            time.Time
	lastEmptyRefresh     time.Time
	hasEmptyRefresh      bool
	registerBlockedUntil time.Time
}

// hongguoAnonSortedQuery: sort pairs by key, Go QueryEscape both sides,
// join with '&'. Mirrors upstream device::register::sorted_query.
func hongguoAnonSortedQuery(pairs [][2]string) string {
	sorted := append([][2]string(nil), pairs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i][0] < sorted[j][0] })
	parts := make([]string, 0, len(sorted))
	for _, pair := range sorted {
		parts = append(parts, url.QueryEscape(pair[0])+"="+url.QueryEscape(pair[1]))
	}
	return strings.Join(parts, "&")
}

func (downloader *Downloader) hongguoAnonState() *hongguoAnonIdentityState {
	return &downloader.hongguoClient().anonIdentity
}

// hongguoAnonCurrent: lazily registers and reuses one anonymous playback
// device per Downloader (2-hour cache).
func (downloader *Downloader) hongguoAnonCurrent(ctx context.Context) (hongguoAnonDevice, error) {
	state := downloader.hongguoAnonState()
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.device != nil && time.Now().Before(state.expiresAt) {
		return *state.device, nil
	}
	return downloader.hongguoAnonRegisterLocked(ctx, state)
}

// hongguoAnonRefreshAfterEmpty: refreshes only when the empty response
// belongs to the cached identity and the previous refresh is at least ten
// minutes old. The first empty response after registration is allowed to
// refresh immediately. Returns nil, nil when pacing blocks the refresh.
func (downloader *Downloader) hongguoAnonRefreshAfterEmpty(ctx context.Context, failedDeviceID string) (*hongguoAnonDevice, error) {
	state := downloader.hongguoAnonState()
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.device == nil {
		return nil, nil
	}
	if state.device.DeviceID != failedDeviceID {
		return nil, nil
	}
	now := time.Now()
	if state.hasEmptyRefresh && now.Sub(state.lastEmptyRefresh) < hongguoAnonEmptyRefreshInterval {
		return nil, nil
	}
	state.lastEmptyRefresh = now
	state.hasEmptyRefresh = true
	state.device = nil
	state.expiresAt = time.Time{}
	device, err := downloader.hongguoAnonRegisterLocked(ctx, state)
	if err != nil {
		return nil, err
	}
	return &device, nil
}

func (downloader *Downloader) hongguoAnonRegisterLocked(ctx context.Context, state *hongguoAnonIdentityState) (hongguoAnonDevice, error) {
	now := time.Now()
	if !state.registerBlockedUntil.IsZero() && now.Before(state.registerBlockedUntil) {
		return hongguoAnonDevice{}, errors.New("playback device registration is cooling down")
	}
	registerCtx, cancel := context.WithTimeout(ctx, hongguoAnonRegisterTimeout)
	defer cancel()
	device, err := downloader.hongguoAnonRegister(registerCtx)
	if err != nil {
		state.registerBlockedUntil = time.Now().Add(hongguoAnonRegisterBackoff)
		return hongguoAnonDevice{}, err
	}
	state.device = &device
	state.expiresAt = time.Now().Add(hongguoAnonIdentityTTL)
	state.registerBlockedUntil = time.Time{}
	return device, nil
}

func hongguoAnonValidID(value string) bool {
	if value == "" || value == "0" || len(value) > 32 {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return false
		}
	}
	return true
}

func hongguoAnonPickID(root map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := root[key]
		if !ok {
			continue
		}
		switch typed := value.(type) {
		case string:
			if typed != "" {
				return typed
			}
		case json.Number:
			if typed.String() != "" {
				return typed.String()
			}
		case float64:
			if typed != 0 {
				return fmt.Sprintf("%d", int64(typed))
			}
		}
	}
	return ""
}

// hongguoAnonRegister: one anonymous mini-reel device registration against
// log5-applog-lq, TTEncrypt envelope, Gorgon-signed query.
func (downloader *Downloader) hongguoAnonRegister(ctx context.Context) (hongguoAnonDevice, error) {
	nowMS := time.Now().UnixMilli()
	stamp := nowMS
	cdid := uuidLike()
	clientUDID := uuidLike()
	openUDID := randomHex(8)
	var seed [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return hongguoAnonDevice{}, err
	}

	header := map[string]any{
		"aid": 8662, "access": "wifi", "app_version": "7.3.9.32", "app_version_minor": "7.3.9.32",
		"channel": "xiaomi_8662_64", "device_brand": "Xiaomi", "device_manufacturer": "Xiaomi",
		"device_model": "23127PN0CC", "device_category": "phone", "device_platform": "android",
		"os": "Android", "os_api": 34, "os_version": "14", "density_dpi": 460,
		"display_density": "xxxhdpi", "resolution": "2670x1200", "language": "zh",
		"timezone": 8, "tz_name": "Asia/Shanghai", "tz_offset": 28800, "region": "CN",
		"package": "com.phoenix.read", "version_code": 73932, "manifest_version_code": 73932,
		"update_version_code": 73932, "apk_first_install_time": nowMS, "cdid": cdid,
		"clientudid": clientUDID, "openudid": openUDID, "cpu_abi": "arm64-v8a",
		"display_name": "红果免费短剧", "sdk_version": "3.7.2", "sdk_target_version": 29,
		"sdk_flavor": "china", "guest_mode": 0, "is_system_app": 0, "not_request_sender": 0,
		"oaid_may_support": true, "ipv6_list": []any{}, "sim_serial_number": []any{},
		"custom":    map[string]any{"is_android_fold": 0, "filter_warn": 0, "web_ua": "", "is_android_pad": 0, "client_ipv4": ""},
		"device_id": "0", "install_id": "0", "req_id": clientUDID,
		"oaid": map[string]any{"req_id": cdid, "hw_id_version_code": "0", "take_ms": "6", "is_track_limited": "false", "query_times": "1", "id": cdid, "time": fmt.Sprintf("%d", stamp-200)},
	}
	payload, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": stamp})
	if err != nil {
		return hongguoAnonDevice{}, err
	}
	var gzipBuf bytes.Buffer
	gzipWriter := gzip.NewWriter(&gzipBuf)
	if _, err := gzipWriter.Write(payload); err != nil {
		return hongguoAnonDevice{}, err
	}
	if err := gzipWriter.Close(); err != nil {
		return hongguoAnonDevice{}, err
	}
	compressed, err := hongguoNormalizeTTGzipHeader(gzipBuf.Bytes())
	if err != nil {
		return hongguoAnonDevice{}, err
	}
	body, err := hongguoTTEncrypt(compressed, seed)
	if err != nil {
		return hongguoAnonDevice{}, err
	}

	ts := uint32(nowMS / 1000)
	query := hongguoAnonSortedQuery([][2]string{
		{"ac", "wifi"}, {"aid", "8662"}, {"app_name", "novelread"}, {"cdid", cdid},
		{"channel", "xiaomi_8662_64"}, {"compliance_status", "0"}, {"device_brand", "Xiaomi"},
		{"device_platform", "android"}, {"device_type", "23127PN0CC"}, {"dpi", "460"},
		{"dragon_device_type", "phone"}, {"host_abi", "arm64-v8a"}, {"is_android_pad_screen", "0"},
		{"language", "zh"}, {"manifest_version_code", "73932"}, {"need_personal_recommend", "1"},
		{"openudid", openUDID}, {"os", "android"}, {"os_api", "34"}, {"os_version", "14"},
		{"package", "com.phoenix.read"}, {"player_so_load", "1"}, {"pv_player", "73932"},
		{"resolution", "1200*2670"}, {"ssmix", "a"}, {"tt_data", "a"},
		{"ts", fmt.Sprintf("%d", ts)}, {"update_version_code", "73932"},
		{"version_code", "73932"}, {"version_name", "7.3.9.32"},
		{"_rticket", fmt.Sprintf("%d", stamp)},
	})
	bodyMD5 := hongguoV5MD5(body)
	var gorgonNonce [2]byte
	if _, err := rand.Read(gorgonNonce[:]); err != nil {
		return hongguoAnonDevice{}, err
	}
	gorgonSeed := uint16(gorgonNonce[0]) | uint16(gorgonNonce[1])<<8
	argusBytes := hongguoV5LE32(ts)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, hongguoAnonRegisterBase+hongguoAnonRegisterPath+"?"+query, bytes.NewReader(body))
	if err != nil {
		return hongguoAnonDevice{}, err
	}
	request.Header.Set("User-Agent", hongguoAnonUserAgent)
	request.Header.Set("Content-Type", "application/octet-stream;tt-data=a")
	request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
	request.Header.Set("Content-Encoding", "gzip")
	request.Header.Set("X-Tt-Request-Tag", "t=0;n=1")
	request.Header.Set("Log-Encode-Type", "gzip")
	request.Header.Set("Lc", "102")
	request.Header.Set("Sdk-Version", "2")
	request.Header.Set("Passport-Sdk-Version", "60755")
	request.Header.Set("Passport-Sdk-Settings", "device_transfer_s_0,device_transfer_ab_1")
	request.Header.Set("X-SS-DP", "8662")
	request.Header.Set("X-Vc-Bdturing-Sdk-Version", "4.0.3.cn")
	request.Header.Set("X-Tt-Store-Region", "cn")
	request.Header.Set("X-Tt-Store-Region-Src", "did")
	request.Header.Set("X-Khronos", fmt.Sprintf("%d", ts))
	request.Header.Set("X-Argus", base64.StdEncoding.EncodeToString(argusBytes[:]))
	request.Header.Set("X-SS-Req-Ticket", fmt.Sprintf("%d", stamp))
	request.Header.Set("X-SS-STUB", hex.EncodeToString(bodyMD5[:]))
	request.Header.Set("X-Gorgon", hongguoV5GenerateGorgon(query, body, ts, gorgonSeed))

	client := downloader.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return hongguoAnonDevice{}, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, hongguoAnonResponseLimit+1))
	response.Body.Close()
	if readErr != nil {
		return hongguoAnonDevice{}, readErr
	}
	if response.StatusCode != http.StatusOK {
		return hongguoAnonDevice{}, fmt.Errorf("device_register HTTP %d", response.StatusCode)
	}
	plain := content
	if bytes.HasPrefix(content, hongguoTTMagic[:]) {
		decrypted, err := hongguoTTDecryptResponse(content)
		if err != nil {
			return hongguoAnonDevice{}, err
		}
		plain = decrypted
	}
	var root map[string]any
	decoder := json.NewDecoder(bytes.NewReader(plain))
	decoder.UseNumber()
	if err := decoder.Decode(&root); err != nil {
		return hongguoAnonDevice{}, errors.New("device_register json: " + err.Error())
	}
	deviceID := hongguoAnonPickID(root, "device_id_str", "device_id")
	installID := hongguoAnonPickID(root, "install_id_str", "install_id")
	if !hongguoAnonValidID(deviceID) || !hongguoAnonValidID(installID) {
		return hongguoAnonDevice{}, errors.New("device_register did not return a valid identity")
	}
	egdi := hongguoAnonPickID(root, "klink_egdi", "egdi")

	// Activation call: 1s timeout, result ignored (upstream activate()).
	activateCtx, activateCancel := context.WithTimeout(ctx, hongguoAnonActivationTimeout)
	defer activateCancel()
	activateQuery := hongguoAnonSortedQuery([][2]string{
		{"aid", "8662"}, {"app_name", "novelread"}, {"channel", "xiaomi_8662_64"},
		{"device_id", deviceID}, {"device_platform", "android"}, {"iid", installID},
		{"os", "android"}, {"_rticket", fmt.Sprintf("%d", time.Now().UnixMilli())},
		{"version_code", "73932"}, {"version_name", "7.3.9.32"},
	})
	activateReq, err := http.NewRequestWithContext(activateCtx, http.MethodGet, hongguoAnonActivateBase+hongguoAnonActivatePath+"?"+activateQuery, nil)
	if err == nil {
		activateReq.Header.Set("User-Agent", hongguoAnonUserAgent)
		activateResp, err := client.Do(activateReq)
		if err == nil {
			io.Copy(io.Discard, io.LimitReader(activateResp.Body, 4096))
			activateResp.Body.Close()
		}
	}

	return hongguoAnonDevice{
		DeviceID: deviceID, InstallID: installID, CDID: cdid,
		OpenUDID: openUDID, ClientUDID: clientUDID, EGDI: egdi,
	}, nil
}
