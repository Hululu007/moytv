package seku

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ---- G4 shared engine: t1-template channel sites (17c / 91n) ----
//
// Both sites serve a Vue SPA backed by /v1 JSON endpoints whose
// responses are an RSA+AES hybrid envelope:
//
//	{data: <base64 AES ciphertext>, key: <base64 RSA ciphertext>}
//
// The frontend bundle embeds a 512-bit RSA private key (parsed to n/d
// integers in the py sources). RSA PKCS#1 v1.5 private decryption of
// "key" yields a 24-char AES key string (AES-192); the CBC IV is the
// first 16 chars of that string reversed. The decrypted plaintext is
// JSON whose "data" field is the business payload.
//
// The py sources prefer the Crypto library and fall back to a bundled
// pure-Python AES. Go needs no fallback tier: crypto/rsa +
// crypto/aes from the standard library cover both steps (verified
// against live envelopes in the G4 smoke run). The RSA parameters are
// PER SITE and must never be mixed: each g4T1Config carries its own
// n/d pair, copied verbatim from that site's py source.

type g4T1Config struct {
	Key     string // internal site key ("17c" / "91n")
	Host    string // no trailing slash
	Channel string
	UA      string

	AvatarPrefix string

	RSAN string // decimal, verbatim from the site's py source
	RSAD string // decimal, verbatim from the site's py source

	// Referer for API calls: {host}/{channel}.html on both sites.
	// Referer for image fetches: 17c uses {host}/ (its localProxy),
	// 91n uses {host}/{channel}.html.
	ImgReferer string
	// Referer handed to the player: 17c's Tencent Lego CDN accepts
	// any non-empty Referer (py sends {host}/); 91n's media CDN
	// requires an in-site Referer (py sends {host}/{channel}.html).
	PlayReferer string
	// BlankOnMiss mirrors 91n's localProxy: a missing image (some
	// actresses have no avatar file server-side) yields a 1x1
	// transparent PNG instead of an error.
	BlankOnMiss bool
}

func (c *g4T1Config) headers() map[string]string {
	return map[string]string{
		"User-Agent":       c.UA,
		"X-Requested-With": "XMLHttpRequest",
		"Referer":          c.Host + "/" + c.Channel + ".html",
		"Accept":           "application/json,*/*",
	}
}

// g4RSADecryptKey recovers the AES key string bytes from the envelope
// "key" field. Primary path is crypto/rsa DecryptPKCS1v15 with a key
// rebuilt from n/d only (no primes are known); the fallback is the
// py-equivalent raw modexp + PKCS#1 v1.5 unpad.
func g4RSADecryptKey(nStr, dStr, b64Key string) ([]byte, error) {
	ct, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64Key))
	if err != nil {
		return nil, fmt.Errorf("g4 rsa key b64: %v", err)
	}
	n, ok := new(big.Int).SetString(nStr, 10)
	if !ok {
		return nil, fmt.Errorf("g4 rsa bad n")
	}
	d, ok := new(big.Int).SetString(dStr, 10)
	if !ok {
		return nil, fmt.Errorf("g4 rsa bad d")
	}
	priv := &rsa.PrivateKey{PublicKey: rsa.PublicKey{N: n, E: 65537}, D: d}
	if pt, err := rsa.DecryptPKCS1v15(rand.Reader, priv, ct); err == nil && len(pt) > 0 {
		return pt, nil
	}
	// Fallback: m = c^d mod n, then strip the 00 02 PS 00 padding.
	k := (n.BitLen() + 7) / 8
	m := new(big.Int).Exp(new(big.Int).SetBytes(ct), d, n)
	em := m.Bytes()
	if len(em) < k {
		padded := make([]byte, k)
		copy(padded[k-len(em):], em)
		em = padded
	}
	if len(em) < 11 || em[0] != 0x00 || em[1] != 0x02 {
		return nil, fmt.Errorf("g4 rsa bad padding")
	}
	sep := bytes.IndexByte(em[2:], 0x00)
	if sep < 0 {
		return nil, fmt.Errorf("g4 rsa no separator")
	}
	return em[2+sep+1:], nil
}

// g4AESDecryptCBC decrypts with PKCS#7 unpadding (py _aes_cbc_decrypt).
func g4AESDecryptCBC(ct, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("g4 aes: %v", err)
	}
	if len(ct) == 0 || len(ct)%aes.BlockSize != 0 {
		return nil, fmt.Errorf("g4 aes bad ciphertext length %d", len(ct))
	}
	out := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, ct)
	if n := int(out[len(out)-1]); n >= 1 && n <= aes.BlockSize && n <= len(out) {
		ok := true
		for _, b := range out[len(out)-n:] {
			if int(b) != n {
				ok = false
				break
			}
		}
		if ok {
			out = out[:len(out)-n]
		}
	}
	return out, nil
}

// g4DecryptEnvelope decrypts one {data, key} envelope and returns the
// business payload (the inner JSON's "data" object).
func g4DecryptEnvelope(cfg *g4T1Config, env map[string]interface{}) (map[string]interface{}, error) {
	dataB64, _ := env["data"].(string)
	keyB64, _ := env["key"].(string)
	if dataB64 == "" || keyB64 == "" {
		return nil, fmt.Errorf("g4 envelope missing data/key")
	}
	aks, err := g4RSADecryptKey(cfg.RSAN, cfg.RSAD, keyB64)
	if err != nil {
		return nil, err
	}
	// IV = first 16 chars of the reversed key string (py: aks[::-1][:16]).
	runes := []rune(string(aks))
	for i, j := 0, len(runes)-1; i < j; i, j = i+1, j-1 {
		runes[i], runes[j] = runes[j], runes[i]
	}
	iv := []byte(string(runes))
	if len(iv) > 16 {
		iv = iv[:16]
	}
	ct, err := base64.StdEncoding.DecodeString(dataB64)
	if err != nil {
		return nil, fmt.Errorf("g4 envelope data b64: %v", err)
	}
	pt, err := g4AESDecryptCBC(ct, aks, iv)
	if err != nil {
		return nil, err
	}
	var inner map[string]interface{}
	if err := json.Unmarshal(pt, &inner); err != nil {
		return nil, fmt.Errorf("g4 envelope plaintext json: %v", err)
	}
	if data, ok := inner["data"].(map[string]interface{}); ok {
		return data, nil
	}
	return map[string]interface{}{}, nil
}

// g4API performs one /v1 API call (3 attempts, mirroring the py
// RETRY=3) and returns the decrypted business payload object.
func (c *g4T1Config) g4API(path string, params map[string]string) (map[string]interface{}, error) {
	q := url.Values{}
	q.Set("c", c.Channel)
	for k, v := range params {
		q.Set(k, v)
	}
	u := c.Host + path + "?" + q.Encode()
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(400*(attempt)) * time.Millisecond)
		}
		body, code, _, err := httpGet(u, c.headers())
		if err != nil || code != 200 {
			lastErr = fmt.Errorf("g4 api http %d err %v", code, err)
			continue
		}
		var obj map[string]interface{}
		if err := json.Unmarshal(body, &obj); err != nil {
			lastErr = fmt.Errorf("g4 api json: %v", err)
			continue
		}
		// Envelope form: {data: string, key: string}. Anything else is
		// treated as a plaintext response whose "data" is the payload
		// (91n's _api does the same check).
		if ds, isStr := obj["data"].(string); isStr && ds != "" {
			if _, hasKey := obj["key"].(string); hasKey {
				data, derr := g4DecryptEnvelope(c, obj)
				if derr != nil {
					lastErr = derr
					continue
				}
				return data, nil
			}
		}
		if data, ok := obj["data"].(map[string]interface{}); ok {
			return data, nil
		}
		return map[string]interface{}{}, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return map[string]interface{}{}, nil
}

// ---- payload field helpers (JSON numbers arrive as float64) ----

func g4Str(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatInt(int64(t), 10)
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		return ""
	}
}

func g4Int(v interface{}) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(t))
		return n
	default:
		return 0
	}
}

func g4Map(v interface{}) map[string]interface{} {
	if m, ok := v.(map[string]interface{}); ok {
		return m
	}
	return nil
}

func g4List(v interface{}) []interface{} {
	if l, ok := v.([]interface{}); ok {
		return l
	}
	return nil
}

// g4IsAd mirrors the py list filter: mixed-in ad entries carry an
// "href" field (or no id at all) and are dropped.
func g4IsAd(item map[string]interface{}) bool {
	if item == nil {
		return true
	}
	if _, has := item["href"]; has {
		return true
	}
	return g4Str(item["id"]) == ""
}

// g4ListPage derives (total, hasMore) from a decrypted list payload.
func g4ListPage(data map[string]interface{}, page, limit int) (int, bool) {
	total := g4Int(data["total"])
	lastPage := g4Int(data["last_page"])
	hasMore := false
	if lastPage > 0 {
		hasMore = page < lastPage
	} else if total > 0 {
		hasMore = page*limit < total
	}
	return total, hasMore
}

// ---- cover fetch: XOR-0x88 image deobfuscation ----
//
// Every image on both sites is stored byte-wise XOR 0x88 obfuscated,
// which image loaders cannot decode. The py sources route covers
// through localProxy; the Go core's equivalent is impl.CoverFetch
// (wired to the core's cover action in main.go): fetch with an
// in-site Referer, return the bytes unchanged when they already look
// like an image, else XOR-decode them.

var g4BlankPNG, _ = base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==")

func g4LooksLikeImage(b []byte) bool {
	if len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
		return true
	}
	if len(b) >= 8 && bytes.Equal(b[:8], []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}) {
		return true
	}
	if len(b) >= 6 && (string(b[:6]) == "GIF87a" || string(b[:6]) == "GIF89a") {
		return true
	}
	if len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP" {
		return true
	}
	return false
}

func g4CoverFetch(cfg *g4T1Config) func(string) ([]byte, error) {
	return func(rawURL string) ([]byte, error) {
		if strings.TrimSpace(rawURL) == "" {
			return nil, fmt.Errorf("g4 cover empty url")
		}
		body, code, _, err := httpGet(rawURL, map[string]string{
			"User-Agent": cfg.UA,
			"Referer":    cfg.ImgReferer,
		})
		if err != nil || code != 200 || len(body) == 0 {
			if cfg.BlankOnMiss {
				return g4BlankPNG, nil
			}
			return nil, fmt.Errorf("g4 cover http %d err %v", code, err)
		}
		if g4LooksLikeImage(body) {
			return body, nil
		}
		out := make([]byte, len(body))
		for i, b := range body {
			out[i] = b ^ 0x88
		}
		if g4LooksLikeImage(out) {
			return out, nil
		}
		if cfg.BlankOnMiss {
			return g4BlankPNG, nil
		}
		return nil, fmt.Errorf("g4 cover undecodable bytes")
	}
}

// g4Chapter builds one chapter object in the shape makeDrama /
// maccms_api use, pointing at another rawID of the same slot.
func g4Chapter(slot, dramaRaw, epRaw, title string, idx int) map[string]interface{} {
	return map[string]interface{}{
		"episodeId": epRaw,
		"id":        dramaID(slot, epRaw),
		"dramaId":   dramaID(slot, dramaRaw),
		"sourceId":  slot,
		"source":    slot,
		"title":     title,
		"name":      title,
		"index":     idx,
		"episode":   idx,
		"url":       "",
		"videoUrl":  "",
		"mediaSize": 0,
	}
}

// g4SetChapters replaces a drama's chapter list (folder drill-down:
// an actress folder's chapters are her works).
func g4SetChapters(d map[string]interface{}, chapters []interface{}) {
	d["chapters"] = chapters
	d["episodeList"] = chapters
	d["episodes"] = len(chapters)
	d["episodeCount"] = len(chapters)
	d["chapterCount"] = len(chapters)
	d["totalEpisode"] = len(chapters)
	d["totalEpisodes"] = len(chapters)
}

// g4PlayFormat classifies a resolved URL for playResult.
func g4PlayFormat(u string) (string, string) {
	if strings.Contains(u, ".m3u8") {
		return "m3u8", "hls"
	}
	return "mp4", "file"
}
