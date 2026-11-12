package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// 红果登录客户端（Go 核一半，供 Dart 登录组接线；Dart 侧只改 lib/*.dart）。
// 两条路都要做：扫码登录（站内 passport）与手机号登录（站内网页 + App 形态）。
// 只借结构，设备参数（aid 8662 / 版本 74332 / 7.4.3.32）用魔蚁自己的；
// 站内网页登录的 aid（513755）与桌面 UA 是该端点自身的形态，随请求结构走。
// 严禁 live 调用发码接口：发码与校验只做到请求构造 + 响应解析可单测，
// live 实测只做到扫码取码那一步；发码 live 验要等用户手机号，由 Dart 侧在用户手机上走。

const hongguoWebBaseURL = "https://hongguoduanju.com"

const hongguoWebUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

const hongguoWebAID = "513755"

const hongguoPassportBaseURL = "https://security.snssdk.com"

const hongguoLoginCodeType = "24"

var errHongguoQRCodeExpired = errors.New("二维码已过期，请重新获取")

var errHongguoLoginSessionExpired = errors.New("本次登录会话已失效，请重新获取验证码")

// hongguoMixParam：站内网页登录的参数混淆——字节异或 5 后转小写十六进制。
func hongguoMixParam(value string) string {
	var builder strings.Builder
	for _, b := range []byte(value) {
		fmt.Fprintf(&builder, "%02x", b^5)
	}
	return builder.String()
}

// hongguoFormatMobile：区号 + 本地号码 → 平台认的手机号。
// 大陆（86）：1 开头的 11 位；境外：+区号 号码。
func hongguoFormatMobile(countryCode, number string) (string, error) {
	cc := digitsOnly(countryCode)
	digits := strings.TrimPrefix(digitsOnly(number), "0")
	if cc == "86" {
		// 容错：Dart 侧 forBridge 曾把区号拼进来（"+86 138…"），数字
		// 串会变成 13 位的 "86"+11 位；先剥掉这层区号再校验，别把
		// 合法号码误报成“大陆手机号是 1 开头的 11 位数字”。
		if len(digits) == 13 && strings.HasPrefix(digits, "86") {
			digits = digits[2:]
		}
		if len(digits) != 11 || !strings.HasPrefix(digits, "1") {
			return "", errors.New("大陆手机号是 1 开头的 11 位数字")
		}
		return digits, nil
	}
	if len(cc) < 1 || len(cc) > 3 || len(digits) < 4 || len(cc)+len(digits) > 15 {
		return "", errors.New("手机号格式无效")
	}
	return "+" + cc + " " + digits, nil
}

func digitsOnly(value string) string {
	var builder strings.Builder
	for _, r := range value {
		if r >= '0' && r <= '9' {
			builder.WriteRune(r)
		}
	}
	return builder.String()
}

func hongguoClientCookie(client *hongguoAppClient, host, name string) string {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.cookies[host][name]
}

func hongguoClientHasWebSession(client *hongguoAppClient) bool {
	client.mu.Lock()
	defer client.mu.Unlock()
	jar := client.cookies["hongguoduanju.com"]
	return jar["sessionid"] != "" || jar["sessionid_ss"] != ""
}

func hongguoClientWebCookie(client *hongguoAppClient) string {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.hongguoCookieHeader("hongguoduanju.com")
}

// hongguoWebChecked：站内 passport 返回的通用校验——message 须为 success，
// 否则按 description/error_code 报错；含滑块验证字段时明确报“请改用扫码登录”。
func hongguoWebChecked(reply map[string]any) (map[string]any, error) {
	data := nestedMap(reply, "data")
	if mapString(reply, "message") != "success" {
		if _, has := data["verify_center_decision_conf"]; has {
			return nil, errors.New("红果要求完成滑块验证，请改用扫码登录")
		}
		code := hongguoAnyInt(data["error_code"])
		message := mapString(data, "description")
		if message == "" {
			message = "官网登录失败"
		}
		if code != 0 && code != -1 {
			return nil, fmt.Errorf("%s（错误码 %d）", message, code)
		}
		return nil, errors.New(message)
	}
	return data, nil
}

// hongguoWebCall：站内 passport 请求（无签名）。params 进查询串，form 非空时 POST
// 表单；自动带站内 Cookie 与 csrf token 头，收 Set-Cookie。
func (downloader *Downloader) hongguoWebCall(ctx context.Context, path string, params url.Values, form map[string]string) (map[string]any, error) {
	client := downloader.hongguoClient()
	query := url.Values{
		"aid": {"513755"}, "passport_jssdk_version": {"3.4.10"},
		"passport_jssdk_type": {"normal"}, "account_sdk_source": {"web"},
		"is_from_ttaccountsdk": {"1"}, "language": {"zh"},
	}
	for key, values := range params {
		query[key] = append([]string(nil), values...)
	}
	target := hongguoWebBaseURL + path + "?" + query.Encode()
	var body io.Reader
	if form != nil {
		values := url.Values{}
		for key, value := range form {
			values.Set(key, value)
		}
		body = strings.NewReader(values.Encode())
	}
	method := http.MethodGet
	if form != nil {
		method = http.MethodPost
	}
	request, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", hongguoWebUserAgent)
	request.Header.Set("Referer", hongguoWebBaseURL+"/")
	request.Header.Set("Origin", hongguoWebBaseURL)
	request.Header.Set("Accept", "application/json, text/javascript")
	if cookie := hongguoClientWebCookie(client); cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	if csrf := hongguoClientCookie(client, "hongguoduanju.com", "passport_csrf_token"); csrf != "" {
		request.Header.Set("X-Tt-Passport-Csrf-Token", csrf)
	}
	if form != nil {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, nil)
	if err != nil {
		return nil, err
	}
	client.mu.Lock()
	client.hongguoStoreCookies(request.URL.Host, response)
	client.mu.Unlock()
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("红果官网登录 HTTP %d", response.StatusCode)
	}
	result, err := hongguoDecodeJSONMap(string(content))
	if err != nil {
		return nil, errors.New("官网登录返回格式异常")
	}
	return result, nil
}

// hongguoLoginQR：扫码登录第一步——取二维码图（base64，不带 data: 前缀）与有效秒数。
func (downloader *Downloader) hongguoLoginQR(ctx context.Context) (string, int, error) {
	reply, err := downloader.hongguoWebCall(ctx, "/passport/web/get_qrcode/", url.Values{"next": {hongguoWebBaseURL + "/"}}, nil)
	if err != nil {
		return "", 0, err
	}
	data, err := hongguoWebChecked(reply)
	if err != nil {
		return "", 0, err
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	client.qrToken = mapString(data, "token")
	client.mu.Unlock()
	encoded := mapString(data, "qrcode")
	if index := strings.Index(encoded, "base64,"); index >= 0 {
		encoded = encoded[index+len("base64,"):]
	}
	if encoded == "" {
		return "", 0, errors.New("官网未返回二维码")
	}
	expiry := hongguoAnyInt(data["expire_time"])
	seconds := 0
	if expiry > 1000000000 {
		seconds = int(expiry - time.Now().Unix())
	} else {
		seconds = int(expiry)
	}
	if seconds < 0 {
		seconds = 0
	}
	if seconds > 600 {
		seconds = 600
	}
	return encoded, seconds, nil
}

// hongguoLoginQRPoll：扫码登录第二步——轮询扫码状态；用户在手机上确认后返回 true。
func (downloader *Downloader) hongguoLoginQRPoll(ctx context.Context) (bool, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	token := client.qrToken
	client.mu.Unlock()
	if token == "" {
		return false, errors.New("请先获取二维码")
	}
	reply, err := downloader.hongguoWebCall(ctx, "/passport/web/check_qrconnect/", url.Values{"next": {hongguoWebBaseURL + "/"}, "token": {token}}, nil)
	if err != nil {
		return false, err
	}
	data, err := hongguoWebChecked(reply)
	if err != nil {
		return false, err
	}
	status := mapString(data, "status")
	if status == "5" || status == "expired" {
		return false, errHongguoQRCodeExpired
	}
	if status == "3" || status == "confirmed" {
		if redirect := mapString(data, "redirect_url"); redirect != "" {
			if err := downloader.hongguoLoginFinishRedirect(ctx, redirect); err != nil {
				return false, err
			}
		}
		// 确认后 Cookie 已经进了站内 Cookie 罐：当场落进账号会话槽，
		// 别等 hongguoAccountInfo——否则轮询明明报已登录，账号会话槽
		// 还是空的，hongguoAccountStatus 也报未登录。身份（账号 ID/
		// 用户名）未知，等随后调 hongguoAccountInfo 时再补。
		if hongguoClientHasWebSession(client) {
			client.mu.Lock()
			cookie := client.hongguoCookieHeader("hongguoduanju.com")
			expiry := client.hongguoCookieExpiryLocked("hongguoduanju.com")
			deviceID, installID := client.state.DeviceID, client.state.InstallID
			client.mu.Unlock()
			downloader.setHongguoAccountSession(hongguoAccountSession{
				Cookie: cookie, DeviceID: deviceID, InstallID: installID,
				ExpiresAt: expiry, Source: hongguoAccountCookieWebSource,
			})
		}
	}
	return hongguoClientHasWebSession(client), nil
}

// hongguoLoginFinishRedirect：只跟官方站内的确认跳转（最多 5 跳），收沿途 Cookie。
func (downloader *Downloader) hongguoLoginFinishRedirect(ctx context.Context, redirect string) error {
	target, err := url.Parse(redirect)
	if err != nil {
		return errors.New("登录确认地址无效")
	}
	base, _ := url.Parse(hongguoWebBaseURL + "/")
	target = base.ResolveReference(target)
	transport := downloader.client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	noRedirect := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	client := downloader.hongguoClient()
	for hop := 0; hop < 5; hop++ {
		if target.Scheme != "https" || target.Host != "hongguoduanju.com" {
			return errors.New("登录确认跳转到不支持的站点")
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
		if err != nil {
			return err
		}
		request.Header.Set("User-Agent", hongguoWebUserAgent)
		request.Header.Set("Referer", hongguoWebBaseURL+"/")
		if cookie := hongguoClientWebCookie(client); cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
		response, err := noRedirect.Do(request)
		if err != nil {
			return err
		}
		client.mu.Lock()
		client.hongguoStoreCookies(request.URL.Host, response)
		client.mu.Unlock()
		location := response.Header.Get("Location")
		isRedirect := response.StatusCode >= 300 && response.StatusCode < 400 && location != ""
		response.Body.Close()
		if !isRedirect {
			if response.StatusCode != http.StatusOK {
				return fmt.Errorf("登录确认失败（HTTP %d）", response.StatusCode)
			}
			return nil
		}
		next, err := target.Parse(location)
		if err != nil {
			return errors.New("登录确认地址无效")
		}
		target = next
	}
	return errors.New("登录确认跳转次数过多")
}

// hongguoLoginAccountInfo：取账号信息，并把站内 Cookie 落成账号会话。
func (downloader *Downloader) hongguoLoginAccountInfo(ctx context.Context) (map[string]any, error) {
	client := downloader.hongguoClient()
	if !hongguoClientHasWebSession(client) {
		return nil, errors.New("官网尚未下发登录态，请先在手机确认登录")
	}
	reply, err := downloader.hongguoWebCall(ctx, "/passport/account/info/v2/", nil, nil)
	if err != nil {
		return nil, err
	}
	data, err := hongguoWebChecked(reply)
	if err != nil {
		return nil, err
	}
	accountID := firstNonEmpty(mapString(data, "user_id"), mapString(data, "id"), mapString(data, "unique_id"))
	userName := firstNonEmpty(mapString(data, "user_name"), mapString(data, "nickname"), mapString(data, "name"), "红果用户")
	cookie := hongguoClientWebCookie(client)
	client.mu.Lock()
	expiry := client.hongguoCookieExpiryLocked("hongguoduanju.com")
	client.mu.Unlock()
	downloader.setHongguoAccountSession(hongguoAccountSession{
		Cookie: cookie, DeviceID: downloader.hongguoDeviceID(), InstallID: func() string {
			client.mu.Lock()
			defer client.mu.Unlock()
			return client.state.InstallID
		}(), AccountID: accountID, UserName: userName,
		ExpiresAt: expiry, Source: hongguoAccountCookieWebSource,
	})
	return map[string]any{
		"userId":   accountID,
		"userName": userName,
		"avatar":   firstNonEmpty(mapString(data, "avatar_url"), mapString(data, "avatar")),
	}, nil
}

// hongguoLoginWebSendCode：站内短信登录发码（POST 表单，手机号与类型先混淆）。
// 注意：live 调用会给真实号码发短信，只由 Dart 侧在用户手机上调。
func (downloader *Downloader) hongguoLoginWebSendCode(ctx context.Context, phone string) (string, int, error) {
	client := downloader.hongguoClient()
	if hongguoClientCookie(client, "hongguoduanju.com", "passport_csrf_token") == "" {
		if _, _, err := downloader.hongguoLoginQR(ctx); err != nil {
			return "", 0, err
		}
	}
	mobile, err := hongguoFormatMobile("86", phone)
	if err != nil {
		return "", 0, err
	}
	display := "+86 " + mobile
	reply, err := downloader.hongguoWebCall(ctx, "/passport/web/send_code/", nil, map[string]string{
		"mobile": hongguoMixParam(display), "type": hongguoMixParam("24"),
		"mix_mode": "1", "fixed_mix_mode": "1",
	})
	if err != nil {
		return "", 0, err
	}
	data, err := hongguoWebChecked(reply)
	if err != nil {
		return "", 0, err
	}
	client.mu.Lock()
	client.webSent = true
	client.webMobile = display
	client.mu.Unlock()
	masked := mapString(data, "mobile")
	if masked == "" {
		masked = "你的手机"
	}
	retry := int(hongguoAnyInt(data["retry_time"]))
	if retry <= 0 {
		retry = 60
	}
	return masked, retry, nil
}

// hongguoLoginWebVerify：站内短信登录校验，成功后落账号会话。
func (downloader *Downloader) hongguoLoginWebVerify(ctx context.Context, phone, code string) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	sent, mobile := client.webSent, client.webMobile
	client.mu.Unlock()
	if !sent {
		return nil, errors.New("请先发送验证码")
	}
	if _, err := hongguoFormatMobile("86", phone); err != nil {
		return nil, err
	}
	if strings.TrimSpace(code) == "" {
		return nil, errors.New("验证码为空")
	}
	reply, err := downloader.hongguoWebCall(ctx, "/passport/web/sms_login/", nil, map[string]string{
		"mobile": hongguoMixParam(mobile), "code": hongguoMixParam(code),
		"login_only": "true", "mix_mode": "1", "fixed_mix_mode": "1",
	})
	if err != nil {
		return nil, err
	}
	if _, err := hongguoWebChecked(reply); err != nil {
		return nil, err
	}
	// 校验通过后取账号信息落会话。
	return downloader.hongguoLoginAccountInfo(ctx)
}

// hongguoAppPassportCall：App 形态 passport 请求（security.snssdk.com，签名）。
// form 为真时参数进表单体（POST），为假时进查询串（GET）；查询串刻意不带
// device_id/iid（设备靠签名内的设备身份识别，带了会被判 2046）；
// 刻意不回发 Cookie（实测把 send_code 下发的 cookie 带到 sms_login 会被判 2046），
// Set-Cookie 只收不发。
func (downloader *Downloader) hongguoAppPassportCall(ctx context.Context, path string, params map[string]string, form bool) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	deviceID, installID := client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	query := hongguoAppQuery(deviceID, installID)
	query.Del("device_id")
	query.Del("iid")
	query.Set("aid", "8662")
	query.Set("app_name", "novelread")
	query.Set("device_platform", "android")
	passport := map[string]string{"aid": "8662", "app_name": "novelread", "device_platform": "android"}
	for key, value := range params {
		if strings.TrimSpace(value) == "" {
			continue
		}
		passport[key] = value
		if !form {
			query.Set(key, value)
		}
	}
	var body []byte
	if form {
		values := url.Values{}
		for key, value := range passport {
			values.Set(key, value)
		}
		body = []byte(values.Encode())
	}
	method := http.MethodGet
	if form {
		method = http.MethodPost
	}
	request, err := http.NewRequestWithContext(ctx, method, hongguoPassportBaseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", hongguoAppUserAgent)
	request.Header.Set("Accept", "application/json")
	if form {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	hongguoPrepareSignedRequest(request, query, body, time.Now(), false, deviceID)
	response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, nil)
	if err != nil {
		return nil, err
	}
	client.mu.Lock()
	client.hongguoStoreCookies(request.URL.Host, response)
	client.mu.Unlock()
	content, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	if err != nil {
		return nil, err
	}
	if len(content) == 0 {
		return nil, errors.New("短信登录接口未返回有效数据")
	}
	if decoded, err := hongguoDecodeJSONMap(string(content)); err == nil {
		return decoded, nil
	}
	return map[string]any{"http": response.StatusCode, "raw": string(content[:minInt(len(content), 300)])}, nil
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

// hongguoLoginAppSendCode：App 形态发码。注意：live 调用会给真实号码发短信，
// 只由 Dart 侧在用户手机上调；本机只做请求构造 + 响应解析单测。
func (downloader *Downloader) hongguoLoginAppSendCode(ctx context.Context, phone string) (string, int, error) {
	mobile, err := hongguoFormatMobile("86", phone)
	if err != nil {
		return "", 0, err
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	client.appTicket = ""
	client.appMobile = mobile
	// 清掉上次登录残留的 sessionid：App 校验只认 Set-Cookie 下发的 sessionid，
	// 不清会把旧会话当成这次校验换来的。只清会话名，不动罐里其他 Cookie。
	for _, name := range hongguoAccountSessionCookieNames {
		delete(client.cookies["security.snssdk.com"], name)
		delete(client.cookieExpires["security.snssdk.com"], name)
	}
	client.mu.Unlock()
	reply, err := downloader.hongguoAppPassportCall(ctx, "/passport/mobile/send_code/v1/", map[string]string{"mobile": mobile, "type": hongguoLoginCodeType}, false)
	if err != nil {
		return "", 0, err
	}
	data := nestedMap(reply, "data")
	if _, has := data["verify_center_decision_conf"]; has {
		return "", 0, errors.New("平台要求先完成滑块验证，当前电视登录流程不支持，尚未完成登录")
	}
	if mapString(reply, "message") != "success" {
		description := mapString(data, "description")
		if description == "" {
			description = "验证码没发出去"
		}
		return "", 0, fmt.Errorf("%s（错误码 %d）", description, hongguoAnyInt(data["error_code"]))
	}
	client.mu.Lock()
	client.appTicket = mapString(data, "mobile_ticket")
	client.mu.Unlock()
	masked := mapString(data, "mobile")
	if masked == "" {
		masked = mobile
	}
	retry := int(hongguoAnyInt(data["retry_time"]))
	if retry <= 0 {
		retry = 60
	}
	return masked, retry, nil
}

// hongguoLoginAppVerify：App 形态校验，依次试 sms_login / sms_login_only /
// sms_login_continue / validate_code（GET 再 POST）；拿到 sessionid 即落账号会话。
func (downloader *Downloader) hongguoLoginAppVerify(ctx context.Context, phone, code string) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	mobile, ticket := client.appMobile, client.appTicket
	client.mu.Unlock()
	if mobile == "" {
		return nil, errors.New("请先发送验证码")
	}
	if _, err := hongguoFormatMobile("86", phone); err != nil {
		return nil, err
	}
	if strings.TrimSpace(code) == "" {
		return nil, errors.New("验证码为空")
	}
	type attempt struct {
		path string
		form bool
	}
	Attempts := []attempt{
		{"/passport/mobile/sms_login/", true},
		{"/passport/mobile/sms_login_only/", true},
		{"/passport/mobile/sms_login_continue/", true},
		{"/passport/mobile/validate_code/v1/", false},
		{"/passport/mobile/validate_code/v1/", true},
	}
	var firstErr error
	for _, item := range Attempts {
		params := map[string]string{"mobile": mobile, "code": code, "type": hongguoLoginCodeType, "mobile_ticket": ticket}
		reply, err := downloader.hongguoAppPassportCall(ctx, item.path, params, item.form)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if session := hongguoClientCookie(client, "security.snssdk.com", "sessionid"); session != "" {
			accountID, userName := hongguoAppReplyIdentity(reply)
			return downloader.hongguoAppSessionFromJar(ctx, accountID, userName)
		}
		data := nestedMap(reply, "data")
		if fresh := mapString(data, "mobile_ticket"); fresh != "" {
			ticket = fresh
			client.mu.Lock()
			client.appTicket = fresh
			client.mu.Unlock()
		}
		errorCode := hongguoAnyInt(data["error_code"])
		switch {
		case errorCode == 0 || errorCode == 1:
			if errorCode == 1 && firstErr == nil {
				firstErr = errors.New("会话过期，请重新登录（错误码 1）")
			}
			continue
		case errorCode == 1203:
			client.mu.Lock()
			client.appTicket = ""
			client.mu.Unlock()
			return nil, errHongguoLoginSessionExpired
		default:
			description := mapString(data, "description")
			if description == "" {
				description = "验证码校验失败"
			}
			return nil, fmt.Errorf("%s（错误码 %d）", description, errorCode)
		}
	}
	if firstErr != nil {
		return nil, firstErr
	}
	return nil, errors.New("登录没有成功，平台没有下发登录态")
}

// hongguoAppReplyIdentity：App 短信校验响应里如果带了账号身份就取出来；
// 对照仓实测里校验响应只下发 Set-Cookie、不带身份，拿不到时返回空串，
// 不因此报错（身份未知，等账号信息接口补）。
func hongguoAppReplyIdentity(reply map[string]any) (accountID, userName string) {
	data := nestedMap(reply, "data")
	accountID = firstNonEmpty(
		mapString(data, "user_id"), mapString(data, "id"), mapString(data, "unique_id"),
		mapString(nestedMap(data, "user_info"), "user_id"), mapString(nestedMap(data, "user_info"), "id"),
		mapString(nestedMap(data, "user"), "user_id"),
	)
	userName = firstNonEmpty(
		mapString(data, "user_name"), mapString(data, "nickname"), mapString(data, "name"),
		mapString(nestedMap(data, "user_info"), "user_name"), mapString(nestedMap(data, "user_info"), "nickname"),
		mapString(nestedMap(data, "user"), "nickname"),
	)
	return accountID, userName
}

// hongguoAppSessionFromJar：从 App 登录收到的 Cookie 落账号会话。
// Cookie 只认 Set-Cookie 下发的 sessionid（响应体里没有会话字段可补，
// 与对照仓一致）；账号 ID/用户名只有校验响应里带了才有，没有就是空串。
func (downloader *Downloader) hongguoAppSessionFromJar(ctx context.Context, accountID, userName string) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	cookie := client.hongguoCookieHeader("security.snssdk.com")
	expiry := client.hongguoCookieExpiryLocked("security.snssdk.com")
	deviceID, installID := client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	if cookie == "" {
		return nil, errors.New("登录没有成功，平台没有下发登录态")
	}
	downloader.setHongguoAccountSession(hongguoAccountSession{
		Cookie: cookie, DeviceID: deviceID, InstallID: installID,
		AccountID: accountID, UserName: userName,
		ExpiresAt: expiry, Source: hongguoAccountCookieAppSource,
	})
	return map[string]any{"loggedIn": true, "accountId": accountID}, nil
}
