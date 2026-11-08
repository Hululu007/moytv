package core

import "testing"

func TestApplyParseTemplate(t *testing.T) {
	if got := applyParseTemplate("https://jx.test/?url={url}", "https://play.test/p?id=1&x=2"); got != "https://jx.test/?url=https%3A%2F%2Fplay.test%2Fp%3Fid%3D1%26x%3D2" {
		t.Fatalf("placeholder template wrong: %s", got)
	}
	if got := applyParseTemplate("https://jx.test/parse/", "https://play.test/p"); got != "https://jx.test/parse/https://play.test/p" {
		t.Fatalf("suffix template wrong: %s", got)
	}
}

func TestExtractParsedURL(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		contentType string
		finalURL    string
		want        string
		wantHeaders map[string]string
		wantOK      bool
	}{
		{"top url", `{"url":"https://cdn.test/a.m3u8"}`, "application/json", "https://jx.test/", "https://cdn.test/a.m3u8", nil, true},
		{"top playUrl", `{"playUrl":"https://cdn.test/b.m3u8"}`, "application/json", "https://jx.test/", "https://cdn.test/b.m3u8", nil, true},
		{"data url", `{"code":200,"data":{"url":"https://cdn.test/c.m3u8"}}`, "application/json", "https://jx.test/", "https://cdn.test/c.m3u8", nil, true},
		{"data string", `{"data":"https://cdn.test/d.m3u8"}`, "application/json", "https://jx.test/", "https://cdn.test/d.m3u8", nil, true},
		{"data list", `{"data":[{"url":"https://cdn.test/e.m3u8"}]}`, "application/json", "https://jx.test/", "https://cdn.test/e.m3u8", nil, true},
		{"header", `{"url":"https://cdn.test/f.m3u8","header":{"Referer":"https://site.test/"}}`, "application/json", "https://jx.test/", "https://cdn.test/f.m3u8", map[string]string{"Referer": "https://site.test/"}, true},
		{"plain url", "https://cdn.test/g.m3u8", "text/plain", "https://jx.test/", "https://cdn.test/g.m3u8", nil, true},
		{"redirect media", "", "application/vnd.apple.mpegurl", "https://cdn.test/h.m3u8", "https://cdn.test/h.m3u8", nil, true},
		{"json no url", `{"code":500,"msg":"fail"}`, "application/json", "https://jx.test/", "", nil, false},
		{"html body", "<html>challenge</html>", "text/html", "https://jx.test/", "", nil, false},
		{"deep nested", `{"result":{"play":{"streams":[{"file":"https://cdn.test/deep.m3u8"}]}}}`, "application/json", "https://jx.test/", "https://cdn.test/deep.m3u8", nil, true},
		{"video_url key", `{"video_url":"https://cdn.test/v.mp4"}`, "application/json", "https://jx.test/", "https://cdn.test/v.mp4", nil, true},
		{"jsonp", `cb({"url":"https://cdn.test/j.m3u8"})`, "application/javascript", "https://jx.test/", "https://cdn.test/j.m3u8", nil, true},
		{"base64 url", `{"data":"aHR0cHM6Ly9jZG4udGVzdC9iLm0zdTg="}`, "application/json", "https://jx.test/", "https://cdn.test/b.m3u8", nil, true},
		{"html video src", `<video src="https://cdn.test/h.mp4"></video>`, "text/html", "https://jx.test/", "https://cdn.test/h.mp4", nil, true},
		{"text embedded", `ok https://cdn.test/t.m3u8 done`, "text/plain", "https://jx.test/", "https://cdn.test/t.m3u8", nil, true},
		{"empty", "", "application/json", "https://jx.test/", "", nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, headers, ok := extractParsedURL([]byte(tc.body), tc.contentType, tc.finalURL)
			if ok != tc.wantOK || got != tc.want {
				t.Fatalf("got (%q, %v), want (%q, %v)", got, ok, tc.want, tc.wantOK)
			}
			for k, v := range tc.wantHeaders {
				if headers[k] != v {
					t.Fatalf("header %s got %q want %q", k, headers[k], v)
				}
			}
		})
	}
}

func TestParseFlagFromMap(t *testing.T) {
	if !parseFlagFromMap(map[string]interface{}{"parse": float64(1)}) {
		t.Fatal("float parse=1 not detected")
	}
	if !parseFlagFromMap(map[string]interface{}{"jx": true}) {
		t.Fatal("bool jx=true not detected")
	}
	if !parseFlagFromMap(map[string]interface{}{"parse": "1"}) {
		t.Fatal("string parse=1 not detected")
	}
	if parseFlagFromMap(map[string]interface{}{"parse": float64(0)}) {
		t.Fatal("parse=0 misdetected")
	}
	if parseFlagFromMap(map[string]interface{}{"url": "https://cdn.test/a.m3u8"}) {
		t.Fatal("missing flag misdetected")
	}
}
