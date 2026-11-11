package core

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 红果账号会话导出/恢复单测：夹具 Cookie，不用真值；不发真实账号请求。
// 覆盖：导出→恢复往返、恢复后账号接口请求头带 Cookie、扫码轮询与两条
// 短信校验返回后 Cookie 确实进了会话槽、App 发码清掉旧 sessionid。

func TestHongguoAccountSessionExportRestore(t *testing.T) {
	expiry := time.Date(2030, time.January, 2, 3, 4, 5, 0, time.UTC)
	original := hongguoAccountSession{
		Cookie: "sessionid=fixture-cookie-1; sessionid_ss=fixture-cookie-2",
		DeviceID: "12345678901", InstallID: "12345678902",
		AccountID: "99001", UserName: "测试用户",
		ExpiresAt: expiry, Source: hongguoAccountCookieWebSource,
	}
	first := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	first.setHongguoAccountSession(original)
	exported := first.hongguoAccountExportSession()
	if exported["loggedIn"] != true || exported["accountCookie"] != original.Cookie {
		t.Fatalf("export must carry the fixture cookie, got %+v", exported)
	}
	if exported["deviceId"] != "12345678901" || exported["installId"] != "12345678902" ||
		exported["accountId"] != "99001" || exported["userName"] != "测试用户" ||
		exported["expiresAtMs"] != expiry.UnixMilli() || exported["cookieSource"] != "web" {
		t.Fatalf("export fields must round-trip, got %+v", exported)
	}

	// 冷启动模拟：全新 Downloader，只拿导出的 JSON 恢复。
	restored := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, http.StatusOK, `{}`), nil
	})
	if status := restored.hongguoAccountStatus(); status["loggedIn"] != false {
		t.Fatalf("fresh process must start logged out, got %+v", status)
	}
	if exported := restored.hongguoAccountExportSession(); exported["loggedIn"] != false || exported["accountCookie"] != "" {
		t.Fatalf("export while logged out must be empty, got %+v", exported)
	}
	restored.setHongguoAccountSession(hongguoAccountSession{
		Cookie: exported["accountCookie"].(string), DeviceID: exported["deviceId"].(string),
		InstallID: exported["installId"].(string), AccountID: exported["accountId"].(string),
		UserName: exported["userName"].(string),
		ExpiresAt: time.UnixMilli(exported["expiresAtMs"].(int64)),
		Source:    exported["cookieSource"].(string),
	})
	status := restored.hongguoAccountStatus()
	if status["loggedIn"] != true || status["accountId"] != "99001" ||
		status["userName"] != "测试用户" || status["expiresAtMs"] != expiry.UnixMilli() {
		t.Fatalf("status after restore must report the session, got %+v", status)
	}
	// 恢复时 Cookie 按来源种回站内 Cookie 罐，AccountInfo 刷新身份才能走通。
	if cookie := hongguoClientWebCookie(restored.hongguoClient()); !strings.Contains(cookie, "sessionid=fixture-cookie-1") {
		t.Fatalf("restore must seed the web cookie jar, got %q", cookie)
	}
	// 清掉后状态与罐里会话 Cookie 一起消失。
	restored.setHongguoAccountSession(hongguoAccountSession{})
	if status := restored.hongguoAccountStatus(); status["loggedIn"] != false {
		t.Fatalf("clear must log out, got %+v", status)
	}
	if cookie := hongguoClientWebCookie(restored.hongguoClient()); strings.Contains(cookie, "sessionid=") {
		t.Fatalf("clear must drop the jar session cookie, got %q", cookie)
	}
}

func TestHongguoAccountRestoreSendsCookie(t *testing.T) {
	var seenCookie, seenHost string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		seenCookie = request.Header.Get("Cookie")
		seenHost = request.URL.Host
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"video_shelf_info":[]}}`), nil
	})
	d.setHongguoAccountSession(hongguoAccountSession{
		Cookie: "sessionid=fixture-cookie-1", DeviceID: "12345678901",
		InstallID: "12345678902", AccountID: "99001",
		Source: hongguoAccountCookieWebSource,
	})
	if _, err := d.hongguoAccountFavorites(context.Background()); err != nil {
		t.Fatal(err)
	}
	if seenHost != "api5-normal-sinfonlinea.fqnovel.com" {
		t.Fatalf("account calls must go to the account host, got %q", seenHost)
	}
	if seenCookie != "sessionid=fixture-cookie-1" {
		t.Fatalf("restored session cookie must reach the account request, got %q", seenCookie)
	}
}

func TestHongguoLoginQrPollLandsSession(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "check_qrconnect") {
			return sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"status":"3","redirect_url":"/"}}`), nil
		}
		resp := sourceFixtureResponse(request, http.StatusOK, ``)
		resp.Header.Set("Set-Cookie", "sessionid=qr-fixture-1; Path=/")
		return resp, nil
	})
	client := d.hongguoClient()
	client.mu.Lock()
	client.qrToken = "qr-token-1"
	client.mu.Unlock()
	loggedIn, err := d.hongguoLoginQRPoll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !loggedIn {
		t.Fatal("confirmed QR poll must report logged in")
	}
	// 轮询确认后 Cookie 必须已经进了账号会话槽，不能只留在 Cookie 罐里。
	if status := d.hongguoAccountStatus(); status["loggedIn"] != true {
		t.Fatalf("account status after confirmed poll must be logged in, got %+v", status)
	}
	exported := d.hongguoAccountExportSession()
	if !strings.Contains(exported["accountCookie"].(string), "sessionid=qr-fixture-1") {
		t.Fatalf("poll must land the redirect cookie in the session, got %+v", exported)
	}
	if exported["accountId"] != "" || exported["cookieSource"] != "web" {
		t.Fatalf("poll lands cookie only, identity comes from AccountInfo, got %+v", exported)
	}
}

func TestHongguoLoginWebVerifyLandsSession(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "sms_login") {
			resp := sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{}}`)
			resp.Header.Set("Set-Cookie", "sessionid=web-fixture-1; Expires=Wed, 01 Jan 2030 00:00:00 GMT; Path=/")
			return resp, nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"user_id":"99001","user_name":"测试用户","avatar_url":"https://cover.example.test/a.jpg"}}`), nil
	})
	client := d.hongguoClient()
	client.mu.Lock()
	client.webSent = true
	client.webMobile = "+86 13800138000"
	client.mu.Unlock()
	info, err := d.hongguoLoginWebVerify(context.Background(), "13800138000", "123456")
	if err != nil {
		t.Fatal(err)
	}
	if info["userId"] != "99001" || info["userName"] != "测试用户" {
		t.Fatalf("web verify must return identity, got %+v", info)
	}
	exported := d.hongguoAccountExportSession()
	if !strings.Contains(exported["accountCookie"].(string), "sessionid=web-fixture-1") {
		t.Fatalf("web verify must land the Set-Cookie session, got %+v", exported)
	}
	if exported["accountId"] != "99001" || exported["userName"] != "测试用户" ||
		exported["cookieSource"] != "web" ||
		exported["expiresAtMs"] != time.Date(2030, time.January, 1, 0, 0, 0, 0, time.UTC).UnixMilli() {
		t.Fatalf("web verify export must carry identity and expiry, got %+v", exported)
	}
}

func TestHongguoLoginAppVerifyLandsSession(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "send_code") {
			return sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"mobile":"138****8000","retry_time":60,"mobile_ticket":"ticket-fixture"}}`), nil
		}
		resp := sourceFixtureResponse(request, http.StatusOK, `{"message":"success","data":{"error_code":0}}`)
		resp.Header.Set("Set-Cookie", "sessionid=app-fixture-1; Path=/")
		return resp, nil
	})
	d.cfg.Retries = 1
	client := d.hongguoClient()
	client.state.DeviceID, client.state.InstallID, client.state.Registered = "12345678901", "12345678902", true
	// 上次登录残留的 sessionid：发码时必须清掉，否则校验会把旧会话当成这次换来的。
	client.mu.Lock()
	if client.cookies == nil {
		client.cookies = map[string]map[string]string{}
	}
	client.cookies["security.snssdk.com"] = map[string]string{"sessionid": "stale-fixture"}
	client.mu.Unlock()
	if _, _, err := d.hongguoLoginAppSendCode(context.Background(), "13800138000"); err != nil {
		t.Fatal(err)
	}
	if got := hongguoClientCookie(client, "security.snssdk.com", "sessionid"); got != "" {
		t.Fatalf("app send_code must clear the stale sessionid, got %q", got)
	}
	result, err := d.hongguoLoginAppVerify(context.Background(), "13800138000", "123456")
	if err != nil {
		t.Fatal(err)
	}
	if result["loggedIn"] != true {
		t.Fatalf("app verify must report logged in, got %+v", result)
	}
	exported := d.hongguoAccountExportSession()
	if !strings.Contains(exported["accountCookie"].(string), "sessionid=app-fixture-1") {
		t.Fatalf("app verify must land the Set-Cookie session, got %+v", exported)
	}
	if strings.Contains(exported["accountCookie"].(string), "stale-fixture") {
		t.Fatalf("app verify must not land the stale session, got %+v", exported)
	}
	if exported["cookieSource"] != "app" {
		t.Fatalf("app verify export must mark the app source, got %+v", exported)
	}
	// 校验响应体里没有身份字段（与对照仓一致），账号 ID 为空是预期内的，
	// 不是没存 Cookie。
	if exported["accountId"] != "" {
		t.Fatalf("app verify has no identity in the reply body, got %+v", exported)
	}
}
