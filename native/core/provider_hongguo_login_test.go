package core

import "testing"

func TestHongguoFormatMobileAcceptsCountryCodePrefix(t *testing.T) {
	// Dart 侧 forBridge 曾把区号拼进来（"+86 138…"），数字串变成 13 位；
	// 格式化应先剥掉这层区号再校验，合法号码不能误报。
	for _, input := range []string{
		"+86 13812345678",
		"86 13812345678",
		"8613812345678",
		"13812345678",
		"138 1234 5678",
	} {
		got, err := hongguoFormatMobile("86", input)
		if err != nil {
			t.Fatalf("input %q 应通过，实际报错 %v", input, err)
		}
		if got != "13812345678" {
			t.Fatalf("input %q 格式化后 %q，应为 13812345678", input, got)
		}
	}
}

func TestHongguoFormatMobileRejectsInvalid(t *testing.T) {
	for _, input := range []string{
		"3812345678",
		"1381234567",
		"23812345678",
		"",
	} {
		if _, err := hongguoFormatMobile("86", input); err == nil {
			t.Fatalf("input %q 应报错", input)
		}
	}
}
