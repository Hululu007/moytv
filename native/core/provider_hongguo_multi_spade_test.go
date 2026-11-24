package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

const hongguoSpadeTestSeed = "aG9uZ2d1by1zcGFkZS10ZXN0LXNlZWQ="
const hongguoSpadeTestCipher = "qAABAATFiNGEze/kB8gDGgtM94AP+gvI4O+3nnJ7GChL1UorChij9U9VjcTk8QNHCf76SA=="
const hongguoSpadeTestPlain = "https://media.example.test/spade1080.mp4"

func TestDecryptHongguoSpadeURL(t *testing.T) {
	seed, err := decodeHongguoSpadeBase64(hongguoSpadeTestSeed)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := decryptHongguoSpadeURL(hongguoSpadeTestCipher, seed)
	if err != nil {
		t.Fatal(err)
	}
	if plain != hongguoSpadeTestPlain {
		t.Fatal("spade decryption mismatch", plain)
	}
	if decrypted, err := decryptHongguoSpadeURL(hongguoSpadeTestCipher, []byte("wrong-seed")); err == nil && strings.HasPrefix(decrypted, "http") {
		t.Fatal("wrong seed must not decrypt to a playable URL", decrypted)
	}
	if _, err := decryptHongguoSpadeURL("aGVsbG8=", seed); err == nil {
		t.Fatal("short non-spade value must fail spade decryption")
	}
}

func TestSelectHongguoAppMediaSpadeURL(t *testing.T) {
	model := map[string]any{
		"key_seed":       hongguoSpadeTestSeed,
		"video_duration": "60",
		"video_list": []any{map[string]any{
			"main_url":   hongguoSpadeTestCipher,
			"video_meta": map[string]any{"codec_type": "h264", "definition": "1080p"},
		}},
	}
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != hongguoSpadeTestPlain {
		t.Fatal("spade URL was not decrypted", media.URL)
	}
}

func TestSelectHongguoAppMediaSpadeInvalidSeedFallsBack(t *testing.T) {
	model := map[string]any{
		"key_seed":       "d3Jvbmctc2VlZA==",
		"video_duration": "60",
		"video_list": []any{map[string]any{
			"main_url":   hongguoSpadeTestCipher,
			"backup_url": "https://media.example.test/backup720.mp4",
			"video_meta": map[string]any{"codec_type": "h264", "definition": "1080p"},
		}},
	}
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/backup720.mp4" {
		t.Fatal("invalid seed must fall back to the plain backup URL", media.URL)
	}
}

func TestSelectHongguoAppMediaSpadeMissingSeed(t *testing.T) {
	model := map[string]any{
		"video_duration": "60",
		"video_list": []any{map[string]any{
			"main_url":   hongguoSpadeTestCipher,
			"video_meta": map[string]any{"codec_type": "h264", "definition": "1080p"},
		}},
	}
	if _, err := selectHongguoAppMedia(model); err == nil {
		t.Fatal("spade-only address without a seed must not fabricate a URL")
	}
}

func TestSelectHongguoAppMediaPlainBase64StillWorks(t *testing.T) {
	model := map[string]any{
		"video_duration": "60",
		"video_list": []any{map[string]any{
			"main_url":   "aHR0cHM6Ly9tZWRpYS5leGFtcGxlLnRlc3QvcGxhaW4ubXA0",
			"video_meta": map[string]any{"codec_type": "h264", "definition": "720p"},
		}},
	}
	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/plain.mp4" {
		t.Fatal("plain base64 URL regression", media.URL)
	}
}

func hongguoMultiFixture(t *testing.T, multiBody string) (*Downloader, *[]string, *[]string) {
	var paths []string
	var bodies []string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		paths = append(paths, request.URL.Path)
		if request.Body != nil {
			raw, _ := io.ReadAll(request.Body)
			if decoded, err := gzipDecompress(raw); err == nil {
				raw = decoded
			}
			bodies = append(bodies, string(raw))
		}
		return sourceFixtureResponse(request, http.StatusOK, multiBody), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	return d, &paths, &bodies
}

// gzipDecompress：V5 请求体是 gzip 字节，测试里解开验 JSON 形状。
func gzipDecompress(raw []byte) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	return io.ReadAll(reader)
}

// The ladder replaced the old single V5 leg: the anonymous door runs
// first and its registration fails on this fixture (the model body carries
// no device id), so the v5 door answers with one player request. The test
// pins that exactly one v5 player request goes out and that its body keeps
// the mixed_video_id_map shape.
func TestHongguoV5ModelSingleRequest(t *testing.T) {
	multiBody := `{"code":0,"data":{"12345":{"video_model":{"video_list":[{"main_url":"https://media.example.test/multi1080.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}}}}`
	d, paths, bodies := hongguoMultiFixture(t, multiBody)
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/multi1080.mp4" {
		t.Fatal("V5 model did not win", media.URL)
	}
	if len(*paths) != 2 || !strings.Contains((*paths)[0], "device_register") || (*paths)[1] != "/novel/player/multi_video_model/player/v1" {
		t.Fatal("ladder must register the anonymous identity, then issue exactly one v5 player request", *paths)
	}
	var playerBody string
	for _, body := range *bodies {
		if strings.Contains(body, "1004") {
			playerBody = body
		}
	}
	if playerBody == "" || !strings.Contains(playerBody, "12345") || !strings.Contains(playerBody, "need_all_video_definition") {
		t.Fatal("V5 payload must carry mixed_video_id_map and need_all_video_definition", *bodies)
	}
}

func TestHongguoV5ModelSpadeWithNestedSeed(t *testing.T) {
	multiBody := `{"code":0,"data":{"12345":{"video_model":{"video_list":[{"main_url":"` + hongguoSpadeTestCipher + `","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"},"video_info":{"data":{"key_seed":"` + hongguoSpadeTestSeed + `"}}}}}`
	d, _, _ := hongguoMultiFixture(t, multiBody)
	media, err := d.resolveHongguoAppMedia(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != hongguoSpadeTestPlain {
		t.Fatal("V5 spade URL was not decrypted", media.URL)
	}
}
