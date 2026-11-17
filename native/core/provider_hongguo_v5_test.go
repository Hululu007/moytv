package core

// V5 signer and single-leg policy tests.
//
// Upstream fqapp ships no fixed V5 fixtures (sign/mod.rs: the legacy
// fixtures do not cover v5), so the signer is verified structurally: the
// branch-12 property is recomputed independently, the header set and the
// query shape are asserted field by field, and the medusa envelope is
// decoded and checked against the wire layout. Bit-exactness against the
// Rust implementation is covered by the live probe (see
// ~/workspace/hongguo_v5_go_port_20261117/PROBE.md), not by fixtures here.

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func hongguoV5TestIdentity() hongguoV5Identity {
	return hongguoV5Identity{DeviceID: "12345678901", InstallID: "12345678902", CDID: "2233aabb-ccdd-eeff-0011-223344556677"}
}

func hongguoV5TestState() hongguoV5ProcessState {
	return hongguoV5ProcessState{nonce: "dGVzdG5vbmNlMTIzNDU2Nzg5", startedMS: 1760000000000}
}

func hongguoV5TestEntropy() hongguoV5Entropy {
	return hongguoV5Entropy{helios: 0x11223344, medusaNonce: 0x55667788, packed: 0x99aabbcc, message: 0xddeeff00}
}

func hongguoV5TestBody() []byte {
	compressed, err := hongguoV5PlaybackBodyBytes("12345", nil)
	if err != nil {
		panic(err)
	}
	return compressed
}

func TestHongguoV5Tables(t *testing.T) {
	if len(hongguoV5SBOX) != 1024 {
		t.Fatalf("SBOX length: got %d", len(hongguoV5SBOX))
	}
	if got := md5.Sum(hongguoV5SBOX[:]); hex.EncodeToString(got[:]) != "09ca50739f19fc28a261e31b7ee58ae2" {
		t.Fatalf("SBOX md5 mismatch: %x", got)
	}
	if len(hongguoV5HashTable) != 64 {
		t.Fatalf("HASH_TABLE length: got %d", len(hongguoV5HashTable))
	}
	if hongguoV5HashTable[0] != 0xebb64faf || hongguoV5HashTable[63] != 0x5fb37586 {
		t.Fatalf("HASH_TABLE ends mismatch: %08x %08x", hongguoV5HashTable[0], hongguoV5HashTable[63])
	}
}

func TestHongguoV5EncodeComponent(t *testing.T) {
	cases := map[string]string{
		"vivo_8662_64": "vivo_8662_64",
		"7.4.3.32":     "7.4.3.32",
		"a*b~c":        "a*b~c",
		"a b":          "a%20b",
		"a+b/c":        "a%2Bb%2Fc",
		"a?b=c&d":      "a%3Fb%3Dc%26d",
	}
	for in, want := range cases {
		if got := hongguoV5EncodeComponent(in); got != want {
			t.Fatalf("encode %q: got %q want %q", in, got, want)
		}
	}
}

func TestHongguoV5SignPlaybackBranch12(t *testing.T) {
	nowMS := int64(1760000000000)
	identity := hongguoV5TestIdentity()
	compressed := hongguoV5TestBody()
	signed, err := hongguoV5SignPlaybackAt(hongguoV5PlayerURL, compressed, identity, nowMS, hongguoV5TestState(), hongguoV5TestEntropy())
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(signed.URL)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "https" || parsed.Host != "api5-normal-sinfonlinea.fqnovel.com" || parsed.Path != "/novel/player/multi_video_model/player/v1" {
		t.Fatalf("signed URL shape wrong: %s", signed.URL)
	}
	// Query pairs in the upstream order.
	wantOrder := []string{"aid=", "app_name=", "version_code=", "version_name=", "channel=", "device_platform=", "device_type=", "os_version=", "update_version_code=", "iid=", "cdid=", "device_id=", "_rticket="}
	raw := parsed.RawQuery
	last := -1
	for _, key := range wantOrder {
		at := strings.Index(raw, key)
		if at < 0 || at < last {
			t.Fatalf("query order broken at %q: %s", key, raw)
		}
		last = at
	}
	query := parsed.Query()
	if query.Get("aid") != "8662" || query.Get("app_name") != "novelread" || query.Get("version_code") != "74332" ||
		query.Get("version_name") != "7.4.3.32" || query.Get("channel") != "vivo_8662_64" ||
		query.Get("device_platform") != "android" || query.Get("device_type") != "PGT-AN10" ||
		query.Get("os_version") != "12" || query.Get("update_version_code") != "74332" ||
		query.Get("iid") != identity.InstallID || query.Get("cdid") != identity.CDID || query.Get("device_id") != identity.DeviceID {
		t.Fatalf("query values wrong: %s", raw)
	}
	ticket, err := strconv.ParseInt(query.Get("_rticket"), 10, 64)
	if err != nil || ticket < nowMS || ticket >= nowMS+1024 {
		t.Fatalf("ticket out of range: %q", query.Get("_rticket"))
	}
	// Branch-12 property recomputed from the wire bytes.
	ts := uint32(nowMS / 1000)
	queryHash := hongguoSM3([]byte(raw))
	bodyMD5 := hongguoV5MD5(compressed)
	if got := hongguoV5BranchIV(queryHash, bodyMD5, ts) & 15; got != 12 {
		t.Fatalf("branch must be 12, got %d", got)
	}
	// Header set: exactly the 8 upstream headers.
	headers := signed.Headers
	if headers.Get("X-Khronos") != strconv.FormatUint(uint64(ts), 10) {
		t.Fatalf("x-khronos wrong: %q", headers.Get("X-Khronos"))
	}
	if headers.Get("X-Helios") == "" || headers.Get("X-Medusa") == "" {
		t.Fatal("helios/medusa headers must be present")
	}
	if headers.Get("User-Agent") != hongguoV5UserAgent {
		t.Fatalf("UA wrong: %q", headers.Get("User-Agent"))
	}
	if headers.Get("Accept") != "application/json" || headers.Get("Content-Type") != "application/json; charset=utf-8" || headers.Get("Content-Encoding") != "gzip" {
		t.Fatal("content headers wrong", headers)
	}
	if headers.Get("X-Ss-Stub") != strings.ToUpper(hex.EncodeToString(bodyMD5[:])) {
		t.Fatalf("x-ss-stub must be the uppercase hex body MD5, got %q", headers.Get("X-Ss-Stub"))
	}
	if len(headers) != 8 {
		t.Fatalf("exactly 8 headers expected, got %d: %v", len(headers), headers)
	}
}

func TestHongguoV5SignPlaybackDeterministic(t *testing.T) {
	nowMS := int64(1760000000000)
	identity := hongguoV5TestIdentity()
	compressed := hongguoV5TestBody()
	first, err := hongguoV5SignPlaybackAt(hongguoV5PlayerURL, compressed, identity, nowMS, hongguoV5TestState(), hongguoV5TestEntropy())
	if err != nil {
		t.Fatal(err)
	}
	second, err := hongguoV5SignPlaybackAt(hongguoV5PlayerURL, compressed, identity, nowMS, hongguoV5TestState(), hongguoV5TestEntropy())
	if err != nil {
		t.Fatal(err)
	}
	if first.URL != second.URL || first.Headers.Get("X-Medusa") != second.Headers.Get("X-Medusa") || first.Headers.Get("X-Helios") != second.Headers.Get("X-Helios") {
		t.Fatal("fixed inputs must sign identically")
	}
	other := hongguoV5TestEntropy()
	other.message++
	third, err := hongguoV5SignPlaybackAt(hongguoV5PlayerURL, compressed, identity, nowMS, hongguoV5TestState(), other)
	if err != nil {
		t.Fatal(err)
	}
	if third.Headers.Get("X-Medusa") == first.Headers.Get("X-Medusa") {
		t.Fatal("entropy must change the medusa value")
	}
	if third.URL != first.URL {
		t.Fatal("entropy must not change the ticket search")
	}
}

func TestHongguoV5SignPlaybackValidation(t *testing.T) {
	identity := hongguoV5TestIdentity()
	compressed := hongguoV5TestBody()
	state, entropy := hongguoV5TestState(), hongguoV5TestEntropy()
	nowMS := int64(1760000000000)
	cases := []struct {
		name     string
		base     string
		identity hongguoV5Identity
		nowMS    int64
	}{
		{"empty base", "", identity, nowMS},
		{"base with query", hongguoV5PlayerURL + "?aid=1", identity, nowMS},
		{"base with fragment", hongguoV5PlayerURL + "#x", identity, nowMS},
		{"empty device", hongguoV5PlayerURL, hongguoV5Identity{InstallID: "1", CDID: "2"}, nowMS},
		{"empty install", hongguoV5PlayerURL, hongguoV5Identity{DeviceID: "1", CDID: "2"}, nowMS},
		{"empty cdid", hongguoV5PlayerURL, hongguoV5Identity{DeviceID: "1", InstallID: "2"}, nowMS},
		{"negative time", hongguoV5PlayerURL, identity, -1000},
	}
	for _, tc := range cases {
		if _, err := hongguoV5SignPlaybackAt(tc.base, compressed, tc.identity, tc.nowMS, state, entropy); err == nil {
			t.Fatalf("%s: must fail", tc.name)
		}
	}
}

func TestHongguoV5MedusaStructure(t *testing.T) {
	nowMS := int64(1760000000000)
	ts := uint32(nowMS / 1000)
	identity := hongguoV5TestIdentity()
	compressed := hongguoV5TestBody()
	query := hongguoV5PlaybackQuery(identity, nowMS, "8662")
	queryHash := hongguoSM3([]byte(query))
	bodyMD5 := hongguoV5MD5(compressed)
	entropy := hongguoV5TestEntropy()
	encoded, err := hongguoV5Medusa(queryHash, bodyMD5, ts, identity, hongguoV5TestState(), entropy)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	// Layout: 20-byte XORed prefix + 2 nonce bytes + 0,1 + AES output
	// (packed length + 1, packed >= 248).
	if len(decoded) < 20+4+249 {
		t.Fatalf("medusa too short: %d", len(decoded))
	}
	tsBytes := hongguoV5LE32(ts)
	var wantPrefix [20]byte
	five := hongguoV5LE32(5)
	copy(wantPrefix[:4], five[:])
	copy(wantPrefix[4:], hongguoV5Magic[:])
	for i := range wantPrefix {
		wantPrefix[i] ^= tsBytes[i&3]
	}
	if !bytes.Equal(decoded[:20], wantPrefix[:]) {
		t.Fatal("medusa prefix must be le32(5)+MAGIC xored with the timestamp bytes")
	}
	if decoded[20] != byte(entropy.medusaNonce) || decoded[21] != byte(entropy.medusaNonce>>8) || decoded[22] != 0 || decoded[23] != 1 {
		t.Fatalf("medusa nonce trailer wrong: %v", decoded[20:24])
	}
}

func TestHongguoV5HeliosLicense(t *testing.T) {
	ts := uint32(1760000000)
	prefix := hongguoV5LE32(0x11223344)
	helios := hongguoV5Helios(ts, 0x11223344)
	decoded, err := base64.StdEncoding.DecodeString(helios)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded) < 4 || !bytes.Equal(decoded[:4], prefix[:]) {
		t.Fatal("helios must start with the le32(random) prefix")
	}
	// The license parameter must actually change the output: the legacy
	// license 1611921764 with the same inputs must differ.
	legacy := hongguoPlayerLadon("8662", ts, prefix[:])
	if legacy == helios {
		t.Fatal("V5 license must produce a different ladon value than the legacy license")
	}
	if got := hongguoPlayerLadonWithLicense("8662", hongguoV5License, ts, prefix[:]); got != helios {
		t.Fatal("helios must equal the parameterized ladon call")
	}
}

func TestHongguoV5HashF13Shape(t *testing.T) {
	var queryHash [32]byte
	for i := range queryHash {
		queryHash[i] = byte(i)
	}
	var bodyMD5 [16]byte
	for i := range bodyMD5 {
		bodyMD5[i] = byte(0x80 + i)
	}
	first := hongguoV5HashF13(queryHash, bodyMD5, 1760000000)
	second := hongguoV5HashF13(queryHash, bodyMD5, 1760000000)
	if first != second {
		t.Fatal("hash_f13 must be deterministic")
	}
	if hongguoV5HashF13(queryHash, bodyMD5, 1760000001) == first {
		t.Fatal("hash_f13 must depend on ts")
	}
	var folded [16]byte
	copy(folded[:], first[:16])
	wantTag := hongguoV5LE32(hongguoV5SumMD5(folded) | 0x20)
	if !bytes.Equal(first[16:], wantTag[:]) {
		t.Fatal("hash_f13 tag must be le32(sum_md5(folded)|0x20)")
	}
}

func TestHongguoV5ProcessStateStable(t *testing.T) {
	first := hongguoV5LoadProcessState(1760000000000)
	second := hongguoV5LoadProcessState(1760000001000)
	if first != second {
		t.Fatal("process state must be fixed at first use")
	}
	if first.nonce == "" || first.startedMS == 0 {
		t.Fatal("process state must carry a nonce and a start time")
	}
	if len(first.nonce) != 24 {
		t.Fatalf("nonce must be 18 random bytes in base64url without padding, got %q", first.nonce)
	}
}

func TestHongguoV5PlaybackBodyBytes(t *testing.T) {
	compressed, err := hongguoV5PlaybackBodyBytes("12345", []string{"12346", "12347", "12348", "bogus", "12345"})
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(plain, &body); err != nil {
		t.Fatal(err)
	}
	biz := nestedMap(body, "biz_param")
	if mapString(biz, "video_platform") != "1024" || mapString(biz, "device_level") != "1" || mapString(biz, "detail_page_version") != "0" {
		t.Fatalf("biz_param values wrong: %v", biz)
	}
	if len(biz) != 9 {
		t.Fatalf("biz_param must carry exactly the 9 upstream fields, got %d", len(biz))
	}
	ids := anyList(nestedMap(body, "mixed_video_id_map")["1004"])
	if len(ids) != 3 || ids[0] != "12345" || ids[1] != "12346" || ids[2] != "12347" {
		t.Fatalf("mixed_video_id_map must carry current + up to 2 upcoming, got %v", ids)
	}
	if mapString(body, "dr_scene") != "player" {
		t.Fatalf("dr_scene wrong: %v", body)
	}
}

func TestHongguoV5ModelEntry(t *testing.T) {
	model := map[string]any{"video_list": []any{"x"}}
	grouped := map[string]any{"1004": map[string]any{"12345": map[string]any{"video_model": model}}}
	if got := hongguoV5ModelEntry(grouped, "12345"); got == nil || got["video_model"] == nil {
		t.Fatal("1004 group shape must resolve")
	}
	direct := map[string]any{"12345": map[string]any{"video_model": model}}
	if got := hongguoV5ModelEntry(direct, "12345"); got == nil {
		t.Fatal("direct id shape must resolve")
	}
	nested := map[string]any{"other": map[string]any{"12345": map[string]any{"video_model": model}}}
	if got := hongguoV5ModelEntry(nested, "12345"); got == nil {
		t.Fatal("nested group shape must resolve")
	}
	legacy := map[string]any{"video_model": model}
	if got := hongguoV5ModelEntry(legacy, "12345"); got == nil {
		t.Fatal("legacy direct video_model shape must resolve")
	}
	if got := hongguoV5ModelEntry(map[string]any{}, "12345"); got != nil {
		t.Fatal("empty data must not resolve")
	}
}

func TestHongguoV5ParseRetryAfter(t *testing.T) {
	if got := hongguoV5ParseRetryAfter("2"); got != 2*time.Second {
		t.Fatalf("got %v", got)
	}
	if got := hongguoV5ParseRetryAfter("30"); got != hongguoV5RetryAfterCap {
		t.Fatalf("Retry-After must cap at 5s, got %v", got)
	}
	if got := hongguoV5ParseRetryAfter("0"); got != 0 {
		t.Fatalf("zero must be ignored, got %v", got)
	}
	if got := hongguoV5ParseRetryAfter("bogus"); got != 0 {
		t.Fatalf("non-numeric must be ignored, got %v", got)
	}
}

// hongguoV5PolicyFixture: model requests are answered per device id; register
// requests mint sequential ids. The transport records every model request's
// device id in order.
func hongguoV5PolicyFixture(t *testing.T, answer func(device string) (int, string)) (*Downloader, *[]string) {
	var requests []string
	registered := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "device_register") {
			registered++
			requests = append(requests, "register")
			id := strconv.Itoa(1000 + registered)
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"`+id+`","install_id_str":"`+id+`9"}`), nil
		}
		device := request.URL.Query().Get("device_id")
		requests = append(requests, "model@"+device)
		status, body := answer(device)
		return sourceFixtureResponse(request, status, body), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	return d, &requests
}

func TestHongguoV5DeviceSwapOnAuthFailure(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
			if device == "7" {
				return status, ""
			}
			return http.StatusOK, hongguoRotationModelOK
		})
		media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
		if err != nil {
			t.Fatalf("status %d: %v", status, err)
		}
		if !strings.HasSuffix(media.URL, "high.mp4") {
			t.Fatalf("status %d: swapped device did not return media: %v", status, media)
		}
		if state := d.hongguoCatalogSnapshot(); state.DeviceID != "1001" {
			t.Fatalf("status %d: device was not swapped: %v", status, state)
		}
		if d.hongguoPlayerSuspended() {
			t.Fatalf("status %d: successful swap must not suspend the player", status)
		}
		if got := *requests; len(got) != 3 || got[0] != "model@7" || got[1] != "register" || got[2] != "model@1001" {
			t.Fatalf("status %d: unexpected request sequence %v", status, got)
		}
	}
}

func TestHongguoV5DeviceAttemptsExhausted(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		return http.StatusUnauthorized, ""
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err == nil || !strings.Contains(err.Error(), "换设备 3 次") {
		t.Fatal("exhausted device attempts must report the swap budget", err)
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
	if models != 3 || registers != 2 {
		t.Fatal("exactly 3 device attempts and 2 swaps expected", *requests)
	}
	if d.hongguoPlayerSuspended() {
		t.Fatal("auth exhaustion must not suspend the player (suspension is for empty bodies)")
	}
}

func TestHongguoV5TransientRetrySameDevice(t *testing.T) {
	calls := 0
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		calls++
		if calls == 1 {
			return http.StatusInternalServerError, "boom"
		}
		if calls == 2 {
			return http.StatusTooManyRequests, "slow down"
		}
		return http.StatusOK, hongguoRotationModelOK
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("transient retries did not recover", media)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("transient retries must stay on the same device", state)
	}
	if got := *requests; len(got) != 3 || got[0] != "model@7" || got[1] != "model@7" || got[2] != "model@7" {
		t.Fatal("unexpected request sequence", got)
	}
}

func TestHongguoV5TransientExhaustionDoesNotSwapDevice(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		return http.StatusInternalServerError, "boom"
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Fatal("exhausted transient retries must report the last status", err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("transient exhaustion must not swap the device", state)
	}
	if got := *requests; len(got) != 3 {
		t.Fatal("initial attempt + 2 transient retries expected", got)
	}
	for _, r := range *requests {
		if r == "register" {
			t.Fatal("transient exhaustion must not register", *requests)
		}
	}
}

func TestHongguoV5EmptyBodyFailsWithoutSwap(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		return http.StatusOK, ""
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if !errors.Is(err, errHongguoAppEmptyBody) || !strings.Contains(err.Error(), "限流") {
		t.Fatal("empty body must surface the rate-limit error", err)
	}
	if state := d.hongguoCatalogSnapshot(); state.DeviceID != "7" {
		t.Fatal("empty body must not swap the device", state)
	}
	if got := *requests; len(got) != 1 || got[0] != "model@7" {
		t.Fatal("empty body must cost exactly one request", got)
	}
	if !d.hongguoPlayerSuspended() {
		t.Fatal("empty body must open the suspend window for the next call")
	}
}

func TestHongguoV5EmptyModelFailsWithoutSwap(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		return http.StatusOK, `{"code":0,"data":{}}`
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if !errors.Is(err, errHongguoAppEmptyBody) {
		t.Fatal("empty model must surface the empty-body error", err)
	}
	if got := *requests; len(got) != 1 {
		t.Fatal("empty model must cost exactly one request", got)
	}
	if !d.hongguoPlayerSuspended() {
		t.Fatal("empty model must open the suspend window")
	}
}

func TestHongguoV5NonRetryableStatusFailsFast(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(device string) (int, string) {
		return http.StatusBadRequest, "nope"
	})
	_, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err == nil || !strings.Contains(err.Error(), "HTTP 400") {
		t.Fatal("non-retryable status must fail fast", err)
	}
	if got := *requests; len(got) != 1 {
		t.Fatal("non-retryable status must cost exactly one request", got)
	}
}

func TestHongguoV5RequestWireShape(t *testing.T) {
	var seen *http.Request
	var rawBody []byte
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		seen = request
		rawBody, _ = io.ReadAll(request.Body)
		return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
		t.Fatal(err)
	}
	if seen.Method != http.MethodPost || seen.URL.Host != "api5-normal-sinfonlinea.fqnovel.com" || seen.URL.Path != "/novel/player/multi_video_model/player/v1" {
		t.Fatalf("V5 request must POST to the player endpoint, got %s %s", seen.Method, seen.URL)
	}
	if seen.Header.Get("X-Gorgon") != "" || seen.Header.Get("X-Argus") != "" || seen.Header.Get("X-Ladon") != "" {
		t.Fatal("V5 request must not carry legacy signing headers", seen.Header)
	}
	if seen.Header.Get("Cookie") != "" {
		t.Fatal("V5 request must not carry cookies", seen.Header)
	}
	if seen.Header.Get("X-Khronos") == "" || seen.Header.Get("X-Helios") == "" || seen.Header.Get("X-Medusa") == "" || seen.Header.Get("X-Ss-Stub") == "" {
		t.Fatal("V5 request must carry the V5 signature headers", seen.Header)
	}
	if seen.Header.Get("Content-Encoding") != "gzip" {
		t.Fatal("V5 request must be gzip-encoded", seen.Header)
	}
	reader, err := gzip.NewReader(bytes.NewReader(rawBody))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(plain), `"1004":["12345"]`) || !strings.Contains(string(plain), `"dr_scene":"player"`) || !strings.Contains(string(plain), `"need_all_video_definition":true`) {
		t.Fatalf("V5 body shape wrong: %s", plain)
	}
}
