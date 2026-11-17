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

// V5 单腿取代了旧的三腿：一次 POST 到 player 端点即取回模型，没有
// tab 首选、multi、single 三腿的先后顺序可言；以下测试钉住单次请求与
// 请求体形状（mixed_video_id_map + need_all_video_definition）。
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
	if len(*paths) != 1 || !strings.Contains((*paths)[0], "multi_video_model/player/v1") {
		t.Fatal("V5 must issue exactly one player request", *paths)
	}
	if len(*bodies) != 1 || !strings.Contains((*bodies)[0], "1004") || !strings.Contains((*bodies)[0], "12345") || !strings.Contains((*bodies)[0], "need_all_video_definition") {
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
