package seku

import (
	"bytes"
	"crypto/aes"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestHxcEncShape(t *testing.T) {
	enc := hxcEnc(`{"page":1}`)
	if enc == "" {
		t.Fatal("enc empty")
	}
	// CBC 输出长度必为 16 的倍数（base64 解码后）
	raw, err := decodeB64(enc)
	if err != nil || len(raw)%aes.BlockSize != 0 {
		t.Fatalf("enc output not block-aligned: %v %d", err, len(raw))
	}
	if hxcEnc(`{"page":1}`) != enc {
		t.Fatal("enc must be deterministic (fixed IV)")
	}
}

func decodeB64(s string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(s)
}

func TestHxcCoverDecrypt(t *testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05}
	// ECB/NoPadding 加密（尾部补零到块对齐，与站方 .aes 形态一致）
	block, _ := aes.NewCipher(hxcPicKey)
	src := make([]byte, 32)
	copy(src, jpeg)
	enc := make([]byte, len(src))
	for i := 0; i < len(src); i += aes.BlockSize {
		block.Encrypt(enc[i:i+aes.BlockSize], src[i:i+aes.BlockSize])
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(enc)
	}))
	defer srv.Close()
	got, err := hxcCoverFetch(srv.URL + "/aes/video/x.jpg.aes")
	if err != nil {
		t.Fatalf("cover fetch err: %v", err)
	}
	if !bytes.HasPrefix(got, jpeg) {
		t.Fatalf("decrypted cover mismatch: %x", got[:8])
	}
}

func TestHxcRegisteredAndDur(t *testing.T) {
	if implForSlot("hxc") == nil {
		t.Fatal("hxc not registered")
	}
	if hxcDur(2214) != "36分54秒" || hxcDur(37) != "37秒" || hxcDur(7200) != "2小时0分" {
		t.Fatalf("dur wrong: %q %q %q", hxcDur(2214), hxcDur(37), hxcDur(7200))
	}
}

func TestHjwParseFixtures(t *testing.T) {
	home, err := os.ReadFile("testdata/hjw_home_excerpt.html")
	if err != nil {
		t.Fatal(err)
	}
	items := hjwParseCards(string(home))
	if len(items) == 0 {
		t.Fatal("hjw fixture parsed 0 cards")
	}
	if !strings.HasPrefix(g5StrVal(items[0]["id"]), "hjw:") {
		t.Fatalf("bad card id %v", items[0]["id"])
	}
	det, err := os.ReadFile("testdata/hjw_detail_excerpt.html")
	if err != nil {
		t.Fatal(err)
	}
	u := ""
	if m := hjwReVideo.FindStringSubmatch(string(det)); m != nil {
		u = strings.ReplaceAll(m[1], `\/`, "/")
	}
	if !strings.Contains(u, ".m3u8") {
		t.Fatalf("detail fixture stream not found: %q", u)
	}
	if implForSlot("hjw") == nil {
		t.Fatal("hjw not registered")
	}
}
