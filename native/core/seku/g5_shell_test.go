package seku

import (
	"os"
	"path/filepath"
	"testing"
)

// 色堂列表回归夹具：testdata/setang_f18_shell.html 为 2026-10-24 本机出口
// 实抓的 fid=18 加密壳页。真机症状「分类能出、列表恒空」的根因是活站
// 模板在 extra 页码后追加了 &amp;mobile=2 后缀，交付期正则 0 命中；
// 解密本身一直正常。本测试锁死：壳页可解开 + 现行模板可解析出真卡片。
func TestSetangShellFixtureDecryptAndParse(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "setang_f18_shell.html"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	page := string(raw)
	dec := g5SetangDecryptPage(page)
	if dec == page {
		t.Fatal("shell page did not decrypt")
	}
	items := g5Setang.parseListLocked("niuguo", dec, "国产自拍")
	if len(items) == 0 {
		t.Fatal("decrypted list page parsed to 0 cards")
	}
	first, _ := items[0].(map[string]interface{})
	t.Logf("cards=%d first id=%v name=%v pic=%v", len(items), first["id"], first["name"], first["pic"])
	if first["name"] == "" || first["pic"] == "" {
		t.Fatalf("first card missing name/pic: %v", first)
	}
}
