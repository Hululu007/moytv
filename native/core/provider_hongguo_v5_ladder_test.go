package core

// Playback ladder tests.
//
// The four reference vectors come from upstream fqapp sign/v5.rs
// (bef83c90): the anonymous query hash, the anonymous Gorgon, the helios
// hash and the anonymous Medusa hash are byte-exact against the lvguo-tv
// reference implementation. The ladder behaviour tests run against the
// same door-tagging fixture as provider_hongguo_v5_test.go.

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func hongguoV5AnonTestIdentity() hongguoAnonV5Identity {
	return hongguoAnonV5Identity{DeviceID: "1234567890", InstallID: "install-test", CDID: "cdid-test", EGDI: "egdi-test"}
}

func TestHongguoV5AnonymousQueryVector(t *testing.T) {
	query := hongguoAnonymousPlaybackQuery(hongguoV5AnonTestIdentity(), 1700000000000)
	if !strings.HasPrefix(query, "device_platform=android&os=android&ssmix=a&_rticket=1700000000000&cdid=cdid-test&channel=vivo_8662_64&aid=8662&app_name=novelread") {
		t.Fatalf("anonymous query prefix wrong: %s", query)
	}
	digest := sha256.Sum256([]byte(query))
	if got := hex.EncodeToString(digest[:]); got != "8aa5299b13ca4f08159a1b96f15baff67c59a094f1526d5f2082c2e1d808bae8" {
		t.Fatalf("anonymous query sha256 mismatch: %s", got)
	}
	if !strings.HasSuffix(query, "&klink_egdi=egdi-test") {
		t.Fatalf("egdi must ride last when present: %s", query)
	}
	empty := hongguoAnonV5Identity{DeviceID: "1234567890", InstallID: "install-test", CDID: "cdid-test"}
	if strings.Contains(hongguoAnonymousPlaybackQuery(empty, 1700000000000), "klink_egdi") {
		t.Fatal("egdi must be omitted while empty")
	}
}

func TestHongguoV5AnonymousGorgonVector(t *testing.T) {
	query := hongguoAnonymousPlaybackQuery(hongguoV5AnonTestIdentity(), 1700000000000)
	if got := hongguoV5GenerateGorgon(query, []byte("fixture-gzip-body"), 1700000000, 0x1234); got != "840434124001185d1e30dc93eebe1364e71df6105a46126993f2" {
		t.Fatalf("anonymous gorgon mismatch: %s", got)
	}
}

func TestHongguoV5AnonymousHeliosAndMedusaVectors(t *testing.T) {
	helios := hongguoV5Helios(1700000000, 0x11223344)
	digest := sha256.Sum256([]byte(helios))
	if got := hex.EncodeToString(digest[:]); got != "ec80528b33a651318025292ef6969bb841634eb142ebe5679b6ad562baa2ae76" {
		t.Fatalf("helios sha256 mismatch: %s", got)
	}
	query := hongguoAnonymousPlaybackQuery(hongguoV5AnonTestIdentity(), 1700000000000)
	queryHash := hongguoSM3([]byte(query))
	bodyMD5 := hongguoV5MD5([]byte("fixture-gzip-body"))
	medusa, err := hongguoAnonymousMedusa(queryHash, bodyMD5, 1700000000, 1700000000000, hongguoV5AnonTestIdentity(),
		hongguoV5ProcessState{nonce: "AAAAAAAAAAAAAAAAAAAAAAAA", startedMS: 1700000000000},
		hongguoAnonEntropy{gorgon: 0x1234, helios: 0x11223344, envLaunch: 105, envPID: 10124, message: 0x55667788, medusaNonce: 0x99aabbcc, packed: 0xddeeff00})
	if err != nil {
		t.Fatal(err)
	}
	medusaDigest := sha256.Sum256([]byte(medusa))
	if got := hex.EncodeToString(medusaDigest[:]); got != "1dcbde6e6b80b7270d7276a129fc88ff71596f478549e0b5f09893a19c8ae35d" {
		t.Fatalf("anonymous medusa sha256 mismatch: %s", got)
	}
}

func TestHongguoV5AnonymousMedusaToken(t *testing.T) {
	if got := hongguoAnonymousMedusaToken("AAAAAAAAAAAAAAAAAAAAAAAAA"); got != "AAAAAAAAAAAAAAAAAAAAAAAAA" {
		t.Fatalf("25-char A nonce must pass through: %q", got)
	}
	if got := hongguoAnonymousMedusaToken("BBBBBBBBBBBBBBBBBBBBBBBB"); got != "ABBBBBBBBBBBBBBBBBBBBBBBB" {
		t.Fatalf("24-char nonce must gain an A prefix: %q", got)
	}
	if got := hongguoAnonymousMedusaToken("ABC"); got != "AABC"+strings.Repeat("A", 21) {
		t.Fatalf("short nonce must be padded to 25 with A: %q", got)
	}
}

func TestHongguoV5EnvelopeIsFull(t *testing.T) {
	identity := hongguoV5TestIdentity()
	full := hongguoV5PlaybackQuery(identity, 1760000000000, "8662", nil)
	if !hongguoV5PlaybackEnvelopeIsFull(full) {
		t.Fatal("28-field envelope must be full")
	}
	legacy := "aid=8662&app_name=novelread&version_code=74332&version_name=7.4.3.32&channel=vivo_8662_64&device_platform=android&device_type=PGT-AN10&os_version=12&update_version_code=74332&iid=1&cdid=2&device_id=3&_rticket=1760000000000"
	if hongguoV5PlaybackEnvelopeIsFull(legacy) {
		t.Fatal("12-field legacy envelope must not be full")
	}
}

func TestHongguoV5PlaybackRoutes(t *testing.T) {
	tags := []string{}
	for _, route := range hongguoPlaybackRoutes() {
		tags = append(tags, route.tag())
	}
	if got := strings.Join(tags, ","); got != "anon,v5,model-a,model-c,tab-b" {
		t.Fatalf("ladder order wrong: %s", got)
	}
	if hongguoPlaybackRoutes()[2].host() == hongguoPlaybackRoutes()[3].host() {
		t.Fatal("model-a and model-c must live on different hosts")
	}

	state := &hongguoPlaybackRouteState{}
	now := int64(100000)
	if got := state.Plan(now, false); len(got) != 5 {
		t.Fatalf("fresh state must plan all doors, got %d", len(got))
	}
	if got := state.Plan(now, true); len(got) != 1 || got[0].tag() != "anon" {
		t.Fatalf("speculative plan must take only the first door, got %v", got)
	}

	// An empty body parks one door for 30s; the others stay available.
	anon := hongguoPlaybackRoutes()[0]
	state.Failed(anon, now, true)
	if !state.Parked(anon, now+1000) || state.Parked(anon, now+31000) {
		t.Fatal("empty cooldown must last 30s")
	}
	if got := state.Plan(now+1000, false); len(got) != 4 || got[0].tag() != "v5" {
		t.Fatalf("parked door must drop out of the plan: %v", got)
	}
	if got := state.Plan(now+1000, true); len(got) != 1 || got[0].tag() != "v5" {
		t.Fatalf("speculative plan must take the first healthy door: %v", got)
	}
	// A non-empty failure parks briefly.
	v5 := hongguoPlaybackRoutes()[1]
	state.Failed(v5, now, false)
	if !state.Parked(v5, now+1000) || state.Parked(v5, now+6000) {
		t.Fatal("error cooldown must last 5s")
	}
	// Success clears the park and wins the plan order.
	state.Success(v5, now+2000)
	if state.Parked(v5, now+2000) {
		t.Fatal("success must clear the park")
	}
	if got := state.Plan(now+2000, false); got[0].tag() != "v5" {
		t.Fatalf("most recently successful door must lead the plan: %v", got)
	}
}

func TestHongguoV5PlaybackRoutesExhaustedAndRotation(t *testing.T) {
	state := &hongguoPlaybackRouteState{}
	now := int64(100000)
	for _, route := range hongguoPlaybackRoutes() {
		state.Failed(route, now, true)
	}
	if !state.Exhausted(now + 1000) {
		t.Fatal("all doors empty and parked must read as exhausted")
	}
	// Foreground still gets every cooling door, ordered by recovery time.
	if got := state.Plan(now+1000, false); len(got) != 5 {
		t.Fatalf("foreground must get all cooling doors, got %d", len(got))
	}
	if got := state.Plan(now+1000, true); len(got) != 0 {
		t.Fatalf("speculative must get nothing while all doors cool, got %v", got)
	}
	// Two all-empty rounds justify a rotation, paced by the settled
	// cooldown afterwards.
	if state.RotateDue(now+1000, false) {
		t.Fatal("rotation must wait for two all-empty rounds")
	}
	state.NoteRound(true)
	state.NoteRound(true)
	if !state.RotateDue(now+1000, false) {
		t.Fatal("two all-empty rounds must justify a rotation")
	}
	if state.RotateDue(now+1000, true) {
		t.Fatal("speculative work must never rotate")
	}
	state.NoteRotate(now+1000, true)
	if state.RotateDue(now+2000, false) {
		t.Fatal("a settled rotation must pace the next one for 30s")
	}
	if !state.RotateDue(now+32000, false) {
		t.Fatal("rotation pacing must clear after the settled cooldown")
	}
	if state.Rotations() != 1 {
		t.Fatalf("rotations must count successful registrations, got %d", state.Rotations())
	}
	state.NoteRound(false)
	if state.EmptyRounds() != 0 {
		t.Fatal("a non-empty round must reset the empty streak")
	}
}

func TestHongguoTTEncryptRoundTrip(t *testing.T) {
	var seed [32]byte
	for i := range seed {
		seed[i] = byte(i * 7)
	}
	plain := []byte("playback device payload")
	encrypted, err := hongguoTTEncrypt(plain, seed)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(encrypted, hongguoTTMagic[:]) {
		t.Fatal("TTEncrypt output must start with the magic")
	}
	if got := encrypted[6:38]; !bytes.Equal(got, seed[:]) {
		t.Fatal("TTEncrypt envelope must carry the seed verbatim")
	}
	// The decrypt path expects SHA512(gzip)||gzip inside; build that
	// envelope with the same key derivation as the request side.
	var gzipBuf bytes.Buffer
	writer := gzip.NewWriter(&gzipBuf)
	if _, err := writer.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	compressed := gzipBuf.Bytes()
	decrypted, err := hongguoTTDecryptResponse(mustHongguoTTEncryptResponse(t, compressed, seed))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decrypted, compressed) {
		t.Fatal("TTDecryptResponse must return the original gzip bytes")
	}
	normalized, err := hongguoNormalizeTTGzipHeader(compressed)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(normalized[:10], []byte{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0}) {
		t.Fatalf("gzip header must normalize to the fixed ten bytes: %v", normalized[:10])
	}
	if _, err := hongguoNormalizeTTGzipHeader([]byte("not gzip")); err == nil {
		t.Fatal("a non-gzip body must fail header normalization")
	}
}

// mustHongguoTTEncryptResponse builds a TTEncrypt response envelope for
// the given gzip bytes: magic || seed || AES-128-CBC(PKCS7(SHA512(gzip) ||
// gzip)) with the same key derivation as the request side.
func mustHongguoTTEncryptResponse(t *testing.T, compressed []byte, seed [32]byte) []byte {
	t.Helper()
	fixed, err := base64.StdEncoding.DecodeString(hongguoTTFixedStringB64)
	if err != nil {
		t.Fatal(err)
	}
	inner := sha512.Sum512(seed[:])
	derived := sha512.New()
	derived.Write(inner[:])
	derived.Write(fixed)
	hv := derived.Sum(nil)
	key, iv := hv[:16], hv[16:32]
	dataHash := sha512.Sum512(compressed)
	payload := hongguoPKCS7Pad(append(append([]byte(nil), dataHash[:]...), compressed...), 16)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	encrypted := make([]byte, len(payload))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, payload)
	out := append(append([]byte(nil), hongguoTTMagic[:]...), seed[:]...)
	out = append(out, encrypted...)
	return out
}

func TestHongguoV5VideoModelBody(t *testing.T) {
	compressed, err := hongguoV5VideoModelBodyBytes("12345")
	if err != nil {
		t.Fatal(err)
	}
	plain := hongguoV5GunzipForTest(t, compressed)
	var body map[string]any
	if err := json.Unmarshal(plain, &body); err != nil {
		t.Fatal(err)
	}
	if mapString(body, "video_id") != "12345" || mapString(body, "content_type") != "1004" {
		t.Fatalf("model body must carry the single id and content_type 1004: %s", plain)
	}
	biz := nestedMap(body, "biz_param")
	if mapString(biz, "device_level") != "3" || mapString(biz, "source") != "9" || mapString(biz, "video_platform") != "3" {
		t.Fatalf("model biz_param must differ from the v5 body: %v", biz)
	}
	if len(biz) != 10 {
		t.Fatalf("model biz_param must carry exactly the 10 upstream fields, got %d", len(biz))
	}
	if _, ok := body["mixed_video_id_map"]; ok {
		t.Fatal("model body must not carry the v5 mixed id map")
	}
}

func TestHongguoV5AnonBody(t *testing.T) {
	compressed, err := hongguoV5AnonPlaybackBodyBytes("12345")
	if err != nil {
		t.Fatal(err)
	}
	plain := hongguoV5GunzipForTest(t, compressed)
	var body map[string]any
	if err := json.Unmarshal(plain, &body); err != nil {
		t.Fatal(err)
	}
	if mapString(body, "video_id") != "12345" || mapString(body, "content_type") != "1" {
		t.Fatalf("anon body must carry the single id and content_type 1: %s", plain)
	}
	ids := anyList(nestedMap(body, "mixed_video_id_map")["1004"])
	if len(ids) != 1 || ids[0] != "12345" {
		t.Fatalf("anon body must carry only the current episode: %v", ids)
	}
}

func TestHongguoV5VideoTabQueryAndShape(t *testing.T) {
	extra := hongguoV5VideoTabQuery("12345")
	if len(extra) != 9 {
		t.Fatalf("tab query must carry 9 fields, got %d", len(extra))
	}
	want := map[string]string{
		"video_id": "12345", "video_id_type": "0", "device_level": "1",
		"need_all_video_definition": "1", "need_mp4_align": "0", "use_os_player": "0",
		"video_platform": "1024", "source": "0", "from_video_id": "",
	}
	for _, pair := range extra {
		if want[pair[0]] != pair[1] {
			t.Fatalf("tab query field %q: got %q want %q", pair[0], pair[1], want[pair[0]])
		}
	}
	shaped, ok := hongguoV5VideoTabShape([]byte(`{"code":0,"data":{"video_model_data":{"12345":{"video_model":{"video_list":[]}}}}}`))
	if !ok {
		t.Fatal("valid tab payload must shape")
	}
	var root map[string]any
	if err := json.Unmarshal(shaped, &root); err != nil {
		t.Fatal(err)
	}
	if _, ok := root["data"]; !ok || len(root) != 1 {
		t.Fatalf("shaped tab payload must be exactly {data}: %s", shaped)
	}
	if _, ok := hongguoV5VideoTabShape([]byte(`{"code":1001,"data":{}}`)); ok {
		t.Fatal("business code must fail the tab door")
	}
	if _, ok := hongguoV5VideoTabShape([]byte(`{"code":0}`)); ok {
		t.Fatal("payload without data must fail the tab door")
	}
	if _, ok := hongguoV5VideoTabShape([]byte(`not json`)); ok {
		t.Fatal("invalid JSON must fail the tab door")
	}
}

func TestHongguoV5LadderAnonWinsFirst(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(door, device string) (int, string) {
		return http.StatusOK, hongguoRotationModelOK
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("anon door must return media", media)
	}
	hongguoV5RequestsEqual(t, *requests, []string{"anon-register", "activate", "anon@1001"})
}

func TestHongguoV5LadderFallsToModelDoor(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(door, device string) (int, string) {
		switch door {
		case "anon", "v5":
			return http.StatusOK, ""
		}
		return http.StatusOK, hongguoRotationModelOK
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("model door must return media", media)
	}
	// The anonymous door empties three times (initial send, the internal
	// refresh-and-resend, then the ladder's same-door reprobe); the v5
	// door empties once; the model-a door answers; model-c and tab-b are
	// never reached.
	hongguoV5RequestsEqual(t, *requests, []string{
		"anon-register", "activate", "anon@1001",
		"anon-register", "activate", "anon@1002", "anon@1002",
		"v5@7", "model-a@7",
	})
}

func TestHongguoV5LadderFallsToTabDoor(t *testing.T) {
	tabBody := `{"code":0,"data":{"video_model_data":{"12345":{"video_model":{"video_list":[{"main_url":"https://media.example.test/high.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}}}}}`
	d, requests := hongguoV5PolicyFixture(t, func(door, device string) (int, string) {
		switch door {
		case "anon", "v5", "model-a", "model-c":
			return http.StatusOK, ""
		}
		return http.StatusOK, tabBody
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("tab door must return media", media)
	}
	hongguoV5RequestsEqual(t, *requests, []string{
		"anon-register", "activate", "anon@1001",
		"anon-register", "activate", "anon@1002", "anon@1002",
		"v5@7", "model-a@7", "model-c@7", "tab-b@7",
	})
}

func TestHongguoV5LadderV5BusinessFailureFallsToModel(t *testing.T) {
	d, requests := hongguoV5PolicyFixture(t, func(door, device string) (int, string) {
		switch door {
		case "anon":
			return http.StatusUnauthorized, ""
		case "v5":
			return http.StatusOK, `{"code":1001,"message":"device rejected"}`
		}
		return http.StatusOK, hongguoRotationModelOK
	})
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatal("model door must return media after the v5 business failure", media)
	}
	hongguoV5RequestsEqual(t, *requests, []string{
		"anon-register", "activate", "anon@1001",
		"v5@7", "model-a@7",
	})
}

func TestHongguoV5AnonRequestWireShape(t *testing.T) {
	var seen []*http.Request
	var rawBodies [][]byte
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		seen = append(seen, request)
		var rawBody []byte
		if request.Body != nil {
			rawBody, _ = io.ReadAll(request.Body)
		}
		rawBodies = append(rawBodies, rawBody)
		if strings.Contains(request.URL.Path, "device_register") {
			return sourceFixtureResponse(request, http.StatusOK, `{"device_id_str":"1001","install_id_str":"10019","klink_egdi":"egdi-test"}`), nil
		}
		if strings.Contains(request.URL.Host, "log5-applog-lf") {
			return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, hongguoRotationModelOK), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	if _, err := d.resolveHongguoAppMedia(context.Background(), "12345"); err != nil {
		t.Fatal(err)
	}
	var anonRequest *http.Request
	var anonBody []byte
	for i, request := range seen {
		if request.URL.Path == "/novel/player/multi_video_model/player/v1/" {
			anonRequest, anonBody = request, rawBodies[i]
			break
		}
	}
	if anonRequest == nil {
		t.Fatalf("no anonymous request seen in %v", seen)
	}
	if anonRequest.Method != http.MethodPost || anonRequest.URL.Host != "api5-normal-sinfonlinea.fqnovel.com" {
		t.Fatalf("anon request must POST to the player endpoint with a trailing slash, got %s %s", anonRequest.Method, anonRequest.URL)
	}
	if anonRequest.Header.Get("X-Gorgon") == "" || anonRequest.Header.Get("X-Argus") == "" || anonRequest.Header.Get("X-Ladon") == "" {
		t.Fatal("anon request must carry the Gorgon/Argus/Ladon headers", anonRequest.Header)
	}
	if anonRequest.Header.Get("X-Xs-From-Web") != "0" {
		t.Fatalf("anon request must carry X-Xs-From-Web: 0, got %q", anonRequest.Header.Get("X-Xs-From-Web"))
	}
	if anonRequest.URL.Query().Get("klink_egdi") != "egdi-test" {
		t.Fatal("anon query must carry the registered egdi", anonRequest.URL)
	}
	plain := hongguoV5GunzipForTest(t, anonBody)
	if !strings.Contains(string(plain), `"video_id":"12345"`) || !strings.Contains(string(plain), `"content_type":1`) {
		t.Fatalf("anon body must carry the single id and content_type 1: %s", plain)
	}
}

func hongguoV5GunzipForTest(t *testing.T, compressed []byte) []byte {
	t.Helper()
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return plain
}
