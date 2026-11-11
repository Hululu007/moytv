package core

import (
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

func hongguoMultiFixture(t *testing.T, multiBody string, singleBody string) (*Downloader, *[]string, *[]string) {
	var paths []string
	var bodies []string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		paths = append(paths, request.URL.Path)
		if request.Body != nil {
			content, _ := io.ReadAll(request.Body)
			bodies = append(bodies, string(content))
		}
		if strings.Contains(request.URL.Path, "video_tab") {
			// GET 首选 leg 在本夹具里回空，走 POST 批量。
			return sourceFixtureResponse(request, http.StatusOK, ``), nil
		}
		if strings.Contains(request.URL.Path, "multi_video_model") {
			return sourceFixtureResponse(request, http.StatusOK, multiBody), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, singleBody), nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "7", "8", true
	return d, &paths, &bodies
}

func TestHongguoMultiModelSuccessSkipsSingle(t *testing.T) {
	multiBody := `{"code":0,"data":{"12345":{"video_model":{"video_list":[{"main_url":"https://media.example.test/multi1080.mp4","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"}}}}`
	d, paths, bodies := hongguoMultiFixture(t, multiBody, hongguoRotationModelOK)
	media, err := d.resolveHongguoAppMediaLine(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/multi1080.mp4" {
		t.Fatal("multi model did not win", media.URL)
	}
	if len(*paths) != 2 || !strings.Contains((*paths)[0], "video_tab") || !strings.Contains((*paths)[1], "multi_video_model") {
		t.Fatal("GET leg must run first, then multi; single must not run after multi success", *paths)
	}
	if len(*bodies) != 2 || !strings.Contains((*bodies)[1], "1004") || !strings.Contains((*bodies)[1], "12345") || !strings.Contains((*bodies)[1], "need_all_video_definition") {
		t.Fatal("multi payload must carry mixed_video_id_map and need_all_video_definition", *bodies)
	}
}

func TestHongguoMultiModelFallsBackToSingle(t *testing.T) {
	d, paths, _ := hongguoMultiFixture(t, `{"code":0,"data":{}}`, hongguoRotationModelOK)
	media, err := d.resolveHongguoAppMediaLine(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/high.mp4" {
		t.Fatal("multi failure must fall back to single", media.URL)
	}
	if len(*paths) != 3 || !strings.Contains((*paths)[0], "video_tab") || !strings.Contains((*paths)[1], "multi_video_model") || !strings.Contains((*paths)[2], "video_model/v1") {
		t.Fatal("GET leg first, multi second, single third", *paths)
	}
}

func TestHongguoMultiModelSpadeWithNestedSeed(t *testing.T) {
	multiBody := `{"code":0,"data":{"12345":{"video_model":{"video_list":[{"main_url":"` + hongguoSpadeTestCipher + `","video_meta":{"codec_type":"h264","definition":"1080p"}}],"video_duration":"60"},"video_info":{"data":{"key_seed":"` + hongguoSpadeTestSeed + `"}}}}}`
	d, _, _ := hongguoMultiFixture(t, multiBody, hongguoRotationModelOK)
	media, err := d.resolveHongguoAppMediaLine(context.Background(), "12345")
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != hongguoSpadeTestPlain {
		t.Fatal("multi spade URL was not decrypted", media.URL)
	}
}
