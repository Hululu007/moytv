package core

import (
	"context"
	"testing"
)

func TestResolveViaParseAPIsAllFail(t *testing.T) {
	if _, _, err := resolveViaParseAPIs(context.Background(), "https://example.test/play", "", []string{"https://127.0.0.1:1/?url="}); err == nil {
		t.Fatal("unreachable parse API should fail")
	}
}

func TestNativeParseFallbackPlan(t *testing.T) {
	plan := nativeParseFallbackPlan("https://mjv011.com/zh/chinese_content/1/x.html", "https://mjv011.com/")
	if !plan.Parse || plan.URL != "https://mjv011.com/zh/chinese_content/1/x.html" || plan.OriginalURL != plan.URL {
		t.Fatalf("fallback plan wrong: %+v", plan)
	}
	if plan.Headers["Referer"] != "https://mjv011.com/" {
		t.Fatalf("fallback headers wrong: %v", plan.Headers)
	}
}
