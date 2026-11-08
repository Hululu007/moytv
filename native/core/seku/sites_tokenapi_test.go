package seku

import (
	"crypto/aes"
	"encoding/base64"
	"strings"
	"testing"
)

// tokenAPIEncryptForTest mirrors the server side: AES/ECB + PKCS#7.
func tokenAPIEncryptForTest(plain string) string {
	block, _ := aes.NewCipher(tokenAPIKey)
	src := []byte(plain)
	pad := aes.BlockSize - len(src)%aes.BlockSize
	for i := 0; i < pad; i++ {
		src = append(src, byte(pad))
	}
	out := make([]byte, len(src))
	for i := 0; i < len(src); i += aes.BlockSize {
		block.Encrypt(out[i:i+aes.BlockSize], src[i:i+aes.BlockSize])
	}
	return base64.StdEncoding.EncodeToString(out)
}

func TestTokenAPIUnwrap(t *testing.T) {
	// 明文 JSON 直通
	if got := tokenAPIUnwrap(`{"code":1}`); got != `{"code":1}` {
		t.Fatalf("plain JSON mangled: %q", got)
	}
	// 引号包裹 + \/ 转义
	if got := tokenAPIUnwrap(`"{\"a\":\"https:\/\/x\/y\"}"`); !strings.Contains(got, "https://x/y") {
		t.Fatalf("quoted/escaped unwrap failed: %q", got)
	}
	// base64 + AES/ECB 密文
	enc := tokenAPIEncryptForTest(`{"code":1,"data":{"token":"tok123"}}`)
	if got := tokenAPIUnwrap(enc); got != `{"code":1,"data":{"token":"tok123"}}` {
		t.Fatalf("cipher unwrap failed: %q", got)
	}
	// Not Found / HTML 页拒绝
	if got := tokenAPIUnwrap(`"404 Not Found!"`); got != "" {
		t.Fatalf("404 body must unwrap to empty, got %q", got)
	}
	if got := tokenAPIUnwrap(`<html><body>x</body></html>`); got != "" {
		t.Fatalf("html must unwrap to empty, got %q", got)
	}
}

func TestTokenAPIPickVideosFlatten(t *testing.T) {
	grouped := []interface{}{
		map[string]interface{}{"videoList": []interface{}{
			map[string]interface{}{"vid": "1", "vod_name": "a"},
			map[string]interface{}{"vid": "2", "vod_name": "b"},
		}},
		map[string]interface{}{"vid": "3", "vod_name": "c"},
	}
	if got := tokenAPIPickVideos(grouped); len(got) != 3 {
		t.Fatalf("grouped flatten = %d, want 3", len(got))
	}
	wrapped := map[string]interface{}{"list": grouped}
	if got := tokenAPIPickVideos(wrapped); len(got) != 3 {
		t.Fatalf("wrapped flatten = %d, want 3", len(got))
	}
}

func TestTokenAPICardAndIDs(t *testing.T) {
	// 前缀型配置（原盒子AI形态，站点已撤、引擎行为保留验证）
	prefixed := &tokenAPIConfig{Slot: "hzai", PrefixedIDs: true, Dark: true}
	v := map[string]interface{}{
		"vid": "9981", "vod_name": "测试片", "enpic": "https://img/x.jpg",
		"duration": "12:30", "eyes": "3.2万", "update_time": "2026-10-24 01:02:03",
	}
	item, ok := prefixed.card(v, false)
	if !ok {
		t.Fatal("hzai card rejected")
	}
	if got := item["id"]; got != dramaID("hzai", "v9981") {
		t.Fatalf("hzai card id = %v", got)
	}
	if item2, ok := prefixed.card(v, true); !ok || item2["id"] != dramaID("hzai", "d9981") {
		t.Fatalf("hzai dark card id wrong: %v %v", ok, item2)
	}
	if vid, dark := prefixed.stripID("d9981"); vid != "9981" || !dark {
		t.Fatalf("stripID d9981 = %q %v", vid, dark)
	}
	if vid, dark := prefixed.stripID("v9981"); vid != "9981" || dark {
		t.Fatalf("stripID v9981 = %q %v", vid, dark)
	}
	// 裸 vid 形态（原樱桃形态）
	bare := &tokenAPIConfig{Slot: "xme"}
	item3, ok := bare.card(v, false)
	if !ok || item3["id"] != dramaID("xme", "9981") {
		t.Fatalf("xme card id wrong: %v %v", ok, item3)
	}
}

func TestTokenAPICoverXOR(t *testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46}
	if mime := sniffImageMime(jpeg); mime != "image/jpeg" {
		t.Fatalf("jpeg sniff = %q", mime)
	}
	xored := make([]byte, len(jpeg))
	for i := range jpeg {
		xored[i] = jpeg[i] ^ 0x88
	}
	if mime := sniffImageMime(xored); mime != "" {
		t.Fatalf("xored bytes must not sniff as image, got %q", mime)
	}
	back := make([]byte, len(xored))
	for i := range xored {
		back[i] = xored[i] ^ 0x88
	}
	if mime := sniffImageMime(back); mime != "image/jpeg" {
		t.Fatalf("de-xored sniff = %q", mime)
	}
}

// 盒子AI/樱桃已按用户 2026-10-24「坏站不进成品」通则撤注册
// （服务端 register 全 404 / 500），引擎单测保留存档。
func TestTokenAPISlotsUnregistered(t *testing.T) {
	for _, slot := range []string{"hzai", "xme"} {
		if implForSlot(slot) != nil {
			t.Fatalf("slot %s must stay unregistered (dead server)", slot)
		}
	}
}
