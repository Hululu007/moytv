package core

import "testing"

func TestHTTPAggPlaySubs(t *testing.T) {
	played := httpAggPlay(map[string]any{
		"url": "https://cdn.example/v.m3u8",
		"subs": []any{
			map[string]any{"url": "https://a.example/zh.srt", "name": "中文", "lang": "zh", "format": "srt"},
			map[string]any{"v": "https://a.example/en.vtt?token=1"},
			"https://a.example/ja.ass",
			map[string]any{"name": "没有地址"},
			map[string]any{"url": "https://a.example/zh.srt", "name": "重复"},
			"",
		},
	})
	if !played.hasURL {
		t.Fatal("expected playable url")
	}
	if len(played.subs) != 3 {
		t.Fatalf("subs = %+v, want 3 entries", played.subs)
	}
	if played.subs[0].Name != "中文" || played.subs[0].Lang != "zh" || played.subs[0].Format != "srt" {
		t.Fatalf("first sub = %+v", played.subs[0])
	}
	if played.subs[1].Format != "vtt" {
		t.Fatalf("format should be inferred ignoring query, got %+v", played.subs[1])
	}
	if played.subs[2].Format != "ass" {
		t.Fatalf("bare string sub = %+v", played.subs[2])
	}
}

func TestHTTPAggPlayNoSubs(t *testing.T) {
	played := httpAggPlay(map[string]any{"url": "https://cdn.example/v.m3u8"})
	if len(played.subs) != 0 {
		t.Fatalf("subs should be empty, got %+v", played.subs)
	}
}
