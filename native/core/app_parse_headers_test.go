package core

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestResolveViaParseAPIsUsesPerAPIHeaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Parse-Key") != "secret1" {
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, `{"msg": "forbidden"}`)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"url": "https://cdn.example.test/1.m3u8"}`)
	}))
	defer server.Close()

	template := server.URL + "/jx?url="
	// 带配置 header：解析成功。
	found, _, err := resolveViaParseAPIs(context.Background(), "https://example.test/play", "", []string{template}, []map[string]string{{"X-Parse-Key": "secret1"}})
	if err != nil {
		t.Fatalf("with headers: %v", err)
	}
	if found != "https://cdn.example.test/1.m3u8" {
		t.Fatalf("found = %q", found)
	}
	// 不带 header：同一接口 403，整体失败（旧行为：无 header 列表时等价）。
	if _, _, err := resolveViaParseAPIs(context.Background(), "https://example.test/play", "", []string{template}, nil); err == nil {
		t.Fatal("without headers the guarded parse API should fail")
	}
	// header 列表比接口列表短：缺失的条目按空处理，不越界。
	if _, _, err := resolveViaParseAPIs(context.Background(), "https://example.test/play", "", []string{template, template}, []map[string]string{{"X-Parse-Key": "wrong"}}); err == nil {
		t.Fatal("wrong header must fail")
	}
}
