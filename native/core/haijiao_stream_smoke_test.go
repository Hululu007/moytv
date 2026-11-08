package core

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"

	"moyi/native/core/seku"
)

func TestHaijiaoFanguoStreamServesDerivedKey(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	res, err := seku.Resolve("fanguo", "hjpl|https://ts10.hj260302818.top/hjstore/video/20230720/110cb8071f6f3de8adee696da7bc20df/187609_i_preview.m3u8")
	if err != nil {
		t.Fatal(err)
	}
	url, _ := res["url"].(string)
	keyHex, _ := res["hlsKey"].(string)
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 16 {
		t.Fatalf("bad hlsKey %q err %v", keyHex, err)
	}
	if !strings.HasPrefix(url, "https://") {
		t.Fatalf("expected https full playlist, got %q", url)
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	media := providerMedia{URL: url, Referer: "https://haijiao.com/", HLSKey: key}
	choice := nativePlaybackChoices(media, 0)
	if len(choice.media) == 0 {
		t.Fatal("playback choices dropped the https playlist")
	}
	plan, err := engine.nativeOpenPlayback(t.Context(), choice)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.Get(plan.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "#EXTINF:") {
		t.Fatalf("stream playlist status %d body %.200q", resp.StatusCode, string(body))
	}
	pl := string(body)
	km := regexp.MustCompile(`#EXT-X-KEY:[^\r\n]*URI="([^"]+)"[^\r\n]*IV=0x([0-9a-fA-F]+)`).FindStringSubmatch(pl)
	if km == nil {
		t.Fatalf("no key line in stream playlist: %.300q", pl)
	}
	keyURL, ivHex := km[1], km[2]
	kresp, err := http.Get(keyURL)
	if err != nil {
		t.Fatal(err)
	}
	kbody, _ := io.ReadAll(kresp.Body)
	kresp.Body.Close()
	if hex.EncodeToString(kbody) != keyHex {
		t.Fatalf("stream key mismatch: got %x want %s", kbody, keyHex)
	}
	var seg string
	for _, line := range strings.Split(pl, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			seg = line
			break
		}
	}
	if seg == "" {
		t.Fatal("no segment in stream playlist")
	}
	sresp, err := http.Get(seg)
	if err != nil {
		t.Fatal(err)
	}
	sbody, _ := io.ReadAll(sresp.Body)
	sresp.Body.Close()
	if len(sbody) < 16 {
		t.Fatalf("segment too short: %d", len(sbody))
	}
	iv, err := hex.DecodeString(ivHex)
	if err != nil || len(iv) != 16 {
		t.Fatalf("bad iv %q", ivHex)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	plain := make([]byte, 16)
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, sbody[:16])
	if plain[0] != 0x47 {
		t.Fatalf("first decrypted byte %02x, expected TS sync 0x47", plain[0])
	}
	t.Logf("stream playlist ok, segments decrypted to TS, key matches derived key")
}

func TestHaijiaoFanguoAppResolvePath(t *testing.T) {
	if os.Getenv("ZZ_LIVE") == "" {
		t.Skip("live smoke off")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	task := Task{
		DramaID: "v_haijiao_fanguo:927428",
		Chapter: Chapter{
			ID:     "v_haijiao_fanguo:927428:hjpl|https://ts10.hj260302818.top/hjstore/video/20230720/110cb8071f6f3de8adee696da7bc20df/187609_i_preview.m3u8",
			Source: "v_haijiao_fanguo",
		},
	}
	media, err := engine.downloader.resolveProviderMedia(t.Context(), task)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(media.URL, "https://") {
		t.Fatalf("app resolve must return https, got %q", media.URL)
	}
	if len(media.HLSKey) != 16 {
		t.Fatalf("app resolve must carry 16-byte HLSKey, got %d", len(media.HLSKey))
	}
	t.Logf("app resolve url=%q hlsKey=%x", media.URL, media.HLSKey)
}
