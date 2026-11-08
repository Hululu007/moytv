package seku

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
)

func TestMjv011Categories(t *testing.T) {
	cats := mjvCategories("mjv011")
	if len(cats) != len(mjvCats) {
		t.Fatalf("categories %d, want %d", len(cats), len(mjvCats))
	}
	if !mjvIsNovel("novel_random/all") || mjvIsNovel("chinese_random/all") {
		t.Fatal("novel classification wrong")
	}
	if !mjvIsImage("18H_random/all") || !mjvIsImage("cg_random/all") || mjvIsImage("novel_random/all") {
		t.Fatal("image classification wrong")
	}
}

func TestMjv011ParsePostsClassicAndFigure(t *testing.T) {
	html := `<div class='post'><a href="https://mjv011.com/zh/chinese_content/1/ABC.html"><img src='https://cdn.example/a.jpg'></a><div class='con'><h3><a href="#">Title One</a></h3><div class='meta'>2026/11/01</div></div></div>` +
		`<div class='post video_9s'><figure><a href="https://mjv011.com/zh/18H_content/9987/content.html"><img src='https://cdn.example/b.jpg'></a></figure><div class='con'><h3><a href="#">Title Two</a></h3><div class='meta'></div></div></div>`
	items := mjvParsePosts(html)
	if len(items) != 2 {
		t.Fatalf("posts %d, want 2", len(items))
	}
	first, _ := items[0].(map[string]interface{})
	if first["vod_id"] != "chinese#1#ABC" {
		t.Fatalf("first vod_id %v", first["vod_id"])
	}
}

func TestMjv011ImageURLsLargeCgurl(t *testing.T) {
	html := `<script>Large_cgurl[2] = "https://cdn.example/002.jpg"; Large_cgurl[1] = "https://cdn.example/001.jpg"; Large_cgurl[2] = "https://cdn.example/002.jpg";</script>`
	urls := mjvImageURLs(html)
	if len(urls) != 2 || urls[0] != "https://cdn.example/001.jpg" || urls[1] != "https://cdn.example/002.jpg" {
		t.Fatalf("image urls %v", urls)
	}
	if got := mjvImageURLs(`<img src='https://x.eemmhh02.com/a.jpg'>`); len(got) != 1 {
		t.Fatalf("eemmhh02 fallback %v", got)
	}
}

func TestMjv011DecryptRoundtrip(t *testing.T) {
	key := []byte("0123456789abcdef")
	iv := []byte("fedcba9876543210")
	plain := []byte("12345")
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	padded := append(append([]byte{}, plain...), strings.Repeat(string(rune(pad)), pad)...)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	enc := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(enc, padded)
	b64 := base64.StdEncoding.EncodeToString(enc)
	xorKey := 5
	base := 10
	sep := string(rune(base + 97))
	parts := []string{}
	for _, ch := range []byte(b64) {
		parts = append(parts, strconv.FormatInt(int64(ch)^int64(xorKey), base))
	}
	got := mjvDecryptID(strings.Join(parts, sep), xorKey, base, string(key), string(iv))
	if got != "12345" {
		t.Fatalf("decrypt %q, want 12345", got)
	}
	if mjvDecryptID("not-a-valid-id", 1, 10, string(key), string(iv)) != "" {
		t.Fatal("bad decrypt should be empty")
	}
}

func TestMjv011VideoParseFallback(t *testing.T) {
	res, err := mjvResolve("mjv011", "video|chinese#12345#test-slug")
	if err != nil {
		t.Fatal(err)
	}
	if res["parse"] != float64(1) || res["jx"] != float64(1) {
		t.Fatalf("video resolve must carry parse+jx, got %v", res)
	}
	url, _ := res["url"].(string)
	if url != "https://mjv011.com/zh/chinese_content/12345/test-slug.html" {
		t.Fatalf("video resolve page wrong: %q", url)
	}
}

func TestMjv011ResolveNonVideoPassthrough(t *testing.T) {
	for _, id := range []string{`novel://{"title":"T","content":"c"}`, "pics://https://a.example/1.jpg&&https://a.example/2.jpg"} {
		res, err := mjvResolve("mjv011", id)
		if err != nil || res["url"] != id {
			t.Fatalf("resolve %s err %v res %v", id, err, res)
		}
	}
}
