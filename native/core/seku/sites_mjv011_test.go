package seku

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
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

func TestMjv011ParseTextPosts(t *testing.T) {
	// Structure copied from the live novel_random page 2026-11-15:
	// imageless posts, title link only. A video post with a figure
	// must not match, so the mixed _list page yields zero novels.
	html := "<div class='post'>\n<div class='con'>\n<h3 itemprop='name headline'><a target=\"_top\" href=\"https://mjv011.com/zh/novel_content/87516/content.html\">[長篇連載]五姊妹（８）</a></h3>\n<div class='meta'></div>\n</div>\n</div>" +
		"<div class='post'>\n<div class='con'>\n<h3 itemprop='name headline'><a target=\"_top\" href=\"https://mjv011.com/zh/novel_content/86947/content.html\">[人妻熟女]全職高手Ｈ</a></h3>\n<div class='meta'></div>\n</div>\n</div>" +
		`<div class='post video_9s'><figure class='video-preview thumb'><a href="https://mjv011.com/zh/chinese_content/330947/ABF-339.html"><img src='https://cdn.example/a.jpg'></a></figure><div class='con'><h3><a href="#">Video Title</a></h3></div></div>`
	items := mjvParseTextPosts(html)
	if len(items) != 2 {
		t.Fatalf("text posts %d, want 2", len(items))
	}
	first, _ := items[0].(map[string]interface{})
	if first["vod_id"] != "novel#87516#content" {
		t.Fatalf("first vod_id %v", first["vod_id"])
	}
	if pic, _ := first["vod_pic"].(string); pic != "" {
		t.Fatalf("novel pic must be empty, got %q", pic)
	}
	if got := mjvParsePosts(html); len(got) != 1 {
		t.Fatalf("image parser on mixed page %d, want 1 (video only)", len(got))
	}
}

func TestMjv011NovelContentFullText(t *testing.T) {
	long := strings.Repeat("字", 4000)
	html := `<div id="novel_content_txtsize" style="font-size:18px">` + long + `</div>`
	if got := mjvNovelContent(html); len([]rune(got)) != 4000 {
		t.Fatalf("novel content %d runes, want 4000 (no truncation)", len([]rune(got)))
	}
	if got := mjvNovelContent(`<span class='content_18h_wpcg'>fallback text</span><div class='contents'>`); got != "fallback text" {
		t.Fatalf("wpcg fallback %q", got)
	}
	if got := mjvNovelContent(`<html><body>no novel here</body></html>`); got != "" {
		t.Fatalf("empty page must yield empty content, got %q", got)
	}
}

// TestMjv011LiveChain hits the real site end to end: detail page rows,
// PID decrypt, play.php videoSources, and the m3u8 body fetched with the
// site headers. Gated on MJV011_LIVE=1 because it needs network access;
// run with the egress proxy env vars. Retries absorb flaky connections.
func TestMjv011LiveChain(t *testing.T) {
	if os.Getenv("MJV011_LIVE") != "1" {
		t.Skip("set MJV011_LIVE=1 to run the live mjv011 chain test")
	}
	var detail map[string]interface{}
	var err error
	for i := 0; i < 4; i++ {
		detail, err = mjvDetail("mjv011", "chinese#342225#ROE-476")
		if err == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		t.Fatalf("live detail: %v", err)
	}
	chapters, _ := detail["chapters"].([]interface{})
	if len(chapters) != 3 {
		t.Fatalf("live detail chapters %d, want 3", len(chapters))
	}
	first, _ := chapters[0].(map[string]interface{})
	ep, _ := first["videoUrl"].(string)
	if strings.Count(ep, "|") != 3 {
		t.Fatalf("episode id %q, want num|slug|pid|res", ep)
	}
	var res map[string]interface{}
	for i := 0; i < 4; i++ {
		res, err = mjvResolve("mjv011", ep)
		if err == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		t.Fatalf("live resolve: %v", err)
	}
	m3u8, _ := res["url"].(string)
	if !strings.HasSuffix(m3u8, ".m3u8") {
		t.Fatalf("resolve url %q, want .m3u8", m3u8)
	}
	var body []byte
	for i := 0; i < 4; i++ {
		req, _ := http.NewRequest("GET", m3u8, nil)
		req.Header.Set("User-Agent", mjvUA)
		req.Header.Set("Referer", mjvHost+"/")
		resp, reqErr := http.DefaultClient.Do(req)
		if reqErr == nil {
			body, reqErr = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
		}
		if reqErr == nil && strings.HasPrefix(string(body), "#EXTM3U") {
			break
		}
		body = nil
		time.Sleep(2 * time.Second)
	}
	if len(body) == 0 || !strings.HasPrefix(string(body), "#EXTM3U") {
		t.Fatalf("m3u8 body missing #EXTM3U, got %d bytes", len(body))
	}

	// Novel list must return novels only (text posts, no video leakage).
	var novels []interface{}
	for i := 0; i < 3; i++ {
		novels, _, _, err = mjvCatalog("mjv011", "novel_random/all", 1)
		if err == nil && len(novels) > 0 {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil || len(novels) == 0 {
		t.Fatalf("live novel catalog: %v items %d", err, len(novels))
	}
	for _, it := range novels {
		m, _ := it.(map[string]interface{})
		if id, _ := m["vod_id"].(string); !strings.HasPrefix(id, "novel#") {
			t.Fatalf("novel catalog leaked non-novel id %q", id)
		}
	}

	// Novel detail serves the full text (verified 6414 chars 2026-11-15).
	var nd map[string]interface{}
	for i := 0; i < 3; i++ {
		nd, err = mjvDetail("mjv011", "novel#85914#content")
		if err == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		t.Fatalf("live novel detail: %v", err)
	}
	nch, _ := nd["chapters"].([]interface{})
	if len(nch) != 1 {
		t.Fatalf("novel chapters %d, want 1", len(nch))
	}
	nfirst, _ := nch[0].(map[string]interface{})
	npay, _ := nfirst["videoUrl"].(string)
	if !strings.HasPrefix(npay, "novel://") {
		t.Fatalf("novel episode %q, want novel:// payload", npay)
	}
	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimPrefix(npay, "novel://")), &payload); err != nil {
		t.Fatalf("novel payload json: %v", err)
	}
	if len([]rune(payload["content"])) <= 3000 {
		t.Fatalf("novel content %d runes, want >3000 (full text)", len([]rune(payload["content"])))
	}
}
