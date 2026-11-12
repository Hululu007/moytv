package core

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
)

// App 路校验成功后取账号信息：站内罐为空、已有 App 会话时，改走会话制
// 资料接口取身份并落盘；资料拿不到时登入照样成立（identityPending），
// 不再报扫码路的“请先在手机确认登录”。只走 httptest 夹具，不发真实短信。
func TestHongguoLoginAccountInfoAppSessionProfile(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "/passport/account/info/") {
			t.Fatal("app session must not call the web info endpoint", request.URL.Path)
		}
		if !strings.Contains(request.URL.Path, "/reading/user/info/v1/") {
			t.Fatal("unexpected path", request.URL.Path)
		}
		if request.Header.Get("Cookie") != "sessionid=s1" {
			t.Fatal("profile must carry the session cookie", request.Header.Get("Cookie"))
		}
		return hongguoAccountJSONResponse(request, `{"code":0,"data":{"biz_user_id":"u1","user_name":"小明"}}`), nil
	})
	d.setHongguoAccountSession(hongguoAccountSession{
		Cookie: "sessionid=s1", DeviceID: "123456789", InstallID: "987654321",
		Source: hongguoAccountCookieAppSource,
	})
	result, err := d.hongguoLoginAccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mapString(result, "userId") != "u1" || mapString(result, "userName") != "小明" {
		t.Fatal("identity mismatch", result)
	}
	if _, pending := result["identityPending"]; pending {
		t.Fatal("identity resolved, must not be pending", result)
	}
	session := d.hongguoAccountSessionSnapshot()
	if session.AccountID != "u1" || session.UserName != "小明" || session.Source != hongguoAccountCookieAppSource {
		t.Fatal("session identity not persisted", session)
	}
}

func TestHongguoLoginAccountInfoAppSessionProfileFails(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		return nil, errors.New("dial boom")
	})
	d.setHongguoAccountSession(hongguoAccountSession{
		Cookie: "sessionid=s1", DeviceID: "123456789", InstallID: "987654321",
		Source: hongguoAccountCookieAppSource,
	})
	result, err := d.hongguoLoginAccountInfo(context.Background())
	if err != nil {
		t.Fatal("profile failure must not void the verified login", err)
	}
	if result["loggedIn"] != true || result["identityPending"] != true {
		t.Fatal("expected session-established pending result", result)
	}
	if mapString(result, "userId") != "" {
		t.Fatal("userId must stay empty pending later refresh", result)
	}
	if !d.hongguoAccountSessionSnapshot().loggedIn() {
		t.Fatal("app session must survive a failed profile fetch")
	}
}

func TestHongguoLoginAccountInfoAppSessionEmptyProfile(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		return hongguoAccountJSONResponse(request, `{"code":0,"data":{}}`), nil
	})
	d.setHongguoAccountSession(hongguoAccountSession{
		Cookie: "sessionid=s1", DeviceID: "123456789", InstallID: "987654321",
		Source: hongguoAccountCookieAppSource,
	})
	result, err := d.hongguoLoginAccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result["loggedIn"] != true || result["identityPending"] != true {
		t.Fatal("expected pending result for empty profile", result)
	}
}

func TestHongguoLoginAccountInfoAppJarOnly(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		if !strings.Contains(request.URL.Path, "/reading/user/info/v1/") {
			t.Fatal("unexpected path", request.URL.Path)
		}
		return hongguoAccountJSONResponse(request, `{"code":0,"data":{"biz_user_id":"u9","user_name":"阿九"}}`), nil
	})
	client := d.hongguoClient()
	client.cookies["security.snssdk.com"] = map[string]string{"sessionid": "s9"}
	result, err := d.hongguoLoginAccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mapString(result, "userId") != "u9" {
		t.Fatal("identity mismatch", result)
	}
	session := d.hongguoAccountSessionSnapshot()
	if !session.loggedIn() || session.Source != hongguoAccountCookieAppSource {
		t.Fatal("jar session must be adopted into the account slot", session)
	}
}

func TestHongguoLoginAccountInfoNoSession(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		t.Fatal("no request must be made without any session")
		return nil, nil
	})
	_, err := d.hongguoLoginAccountInfo(context.Background())
	if err == nil {
		t.Fatal("expected an error without any session")
	}
	if strings.Contains(err.Error(), "手机确认登录") {
		t.Fatal("sms path must not show qr wording", err)
	}
	if !strings.Contains(err.Error(), "重新登录") {
		t.Fatal("expected sms-understandable wording", err)
	}
}

func TestHongguoLoginAccountInfoWebPathUnchanged(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "/reading/user/info/") {
			t.Fatal("web session must not call the profile endpoint", request.URL.Path)
		}
		if !strings.Contains(request.URL.Path, "/passport/account/info/v2/") {
			t.Fatal("unexpected path", request.URL.Path)
		}
		return hongguoAccountJSONResponse(request, `{"message":"success","data":{"user_id":"w1","user_name":"站内用户","avatar_url":"https://example.com/a.png"}}`), nil
	})
	d.setHongguoAccountSession(hongguoAccountSession{
		Cookie: "sessionid=w1", DeviceID: "123456789", InstallID: "987654321",
		AccountID: "old", Source: hongguoAccountCookieWebSource,
	})
	result, err := d.hongguoLoginAccountInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mapString(result, "userId") != "w1" || mapString(result, "userName") != "站内用户" || mapString(result, "avatar") != "https://example.com/a.png" {
		t.Fatal("web identity mismatch", result)
	}
	if _, pending := result["identityPending"]; pending {
		t.Fatal("web path must not report pending", result)
	}
	if d.hongguoAccountSessionSnapshot().Source != hongguoAccountCookieWebSource {
		t.Fatal("web session source must stay web")
	}
}

func TestHongguoAccountQrConfirmKeepsQrWording(t *testing.T) {
	d := hongguoAccountFixture(t, func(request *http.Request) (*http.Response, error) {
		t.Fatal("no request must be made without a web session")
		return nil, nil
	})
	_, err := d.hongguoAccountQrConfirm(context.Background())
	if err == nil || !strings.Contains(err.Error(), "请先在手机确认登录") {
		t.Fatal("qr confirm must keep its web-session check and wording", err)
	}
}


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
