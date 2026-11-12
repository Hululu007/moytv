package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 红果账号登录动作（对照 tree_104 的 provider_hongguo_account.go 补齐的 6 个）：
// 发码 SendSms、验码 VerifySms、扫码 QrCode/QrPoll/QrConfirm、资料 Profile。
// 云端 6 个已有函数（收藏/历史/进度/预约/相关/筛选）在 provider_hongguo_account.go，
// 不动签名、不动行为。旧的 hongguoLogin* 路（provider_hongguo_login.go）也原样保留，
// 这里是另一套与对照仓验通版对齐的账号动作；验码成功后会话落进魔蚁现有的
// hongguoAccountSession（来源 app），云端函数与 ExportSession 都能直接读到。

const hongguoAccountRequestTimeout = 20 * time.Second
const hongguoAccountMaxBodyBytes = 2 * 1024 * 1024

// passport 的 UA 按对照仓：无 body（GET 发码）用 72232，有 body（POST 验码）用 71332；
// 查询串版本号与取流/签名栈一致用 74332 / 7.4.3.32（修仙版 _passportDeviceParams
// 同款修法：签名里嵌的版本号是 7.4.3.32，query 再留 73932 会让签名与 query
// 各说一个版本；旧路 hongguoAppPassportCall 用的 hongguoAppQuery 本来就是 74332）。
const hongguoAccountPassportAppUA = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
const hongguoAccountPassportVideoUA = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

var errHongguoAccountEmptyBody = errors.New("账号接口返回空响应")

type hongguoAccountPhoneSession struct {
	mobile    string
	ticket    string
	deviceID  string
	installID string
	cookies   map[string]string
	expired   bool
}

func hongguoAccountMix(value string) string {
	var out strings.Builder
	for _, b := range []byte(value) {
		out.WriteString(strconv.FormatInt(int64(b^5), 16))
	}
	return out.String()
}

type hongguoAccountFormField struct {
	key   string
	value string
}

func hongguoAccountFormEscape(value string) string {
	escaped := url.QueryEscape(value)
	escaped = strings.ReplaceAll(escaped, "+", "%20")
	escaped = strings.ReplaceAll(escaped, "%7E", "~")
	return escaped
}

func hongguoAccountFormEncode(fields []hongguoAccountFormField) string {
	parts := make([]string, 0, len(fields))
	for _, field := range fields {
		if field.value == "" {
			continue
		}
		parts = append(parts, hongguoAccountFormEscape(field.key)+"="+hongguoAccountFormEscape(field.value))
	}
	return strings.Join(parts, "&")
}

func hongguoAccountQuery(deviceID, installID, versionCode, versionName string, includeIDs bool) url.Values {
	query := hongguoAppQuery(deviceID, installID)
	query.Set("version_code", versionCode)
	query.Set("version_name", versionName)
	query.Set("manifest_version_code", versionCode)
	query.Set("update_version_code", versionCode)
	query.Set("pv_player", versionCode)
	// 其余 5 个是对照仓 hongguoAppQuery 里自带的静态参数，魔蚁的 hongguoAppQuery
	// 没有，在这里补上，让 passport 查询串与对照仓发出的完全一致。
	query.Set("host_abi", "arm64-v8a")
	query.Set("dragon_device_type", "phone")
	query.Set("compliance_status", "0")
	query.Set("need_personal_recommend", "1")
	query.Set("player_so_load", "1")
	if !includeIDs {
		query.Del("device_id")
		query.Del("iid")
	}
	return query
}

func hongguoAccountInt(row map[string]any, key string, fallback int) int {
	return int(hongguoAccountInt64(row, key, int64(fallback)))
}

func hongguoAccountInt64(row map[string]any, key string, fallback int64) int64 {
	value, ok := row[key]
	if !ok || value == nil {
		return fallback
	}
	switch number := value.(type) {
	case json.Number:
		if parsed, err := number.Int64(); err == nil {
			return parsed
		}
		if parsed, err := number.Float64(); err == nil {
			return int64(parsed)
		}
	case float64:
		return int64(number)
	case int:
		return int64(number)
	case int64:
		return number
	case string:
		if parsed, err := strconv.ParseInt(number, 10, 64); err == nil {
			return parsed
		}
	}
	return fallback
}

func hongguoAccountErrorCode(data map[string]any) int {
	return hongguoAccountInt(data, "error_code", 0)
}

func hongguoAccountDescribe(data map[string]any) string {
	description := mapString(data, "description")
	if description == "" {
		return ""
	}
	return description + "（错误码 " + mapString(data, "error_code") + "）"
}

func hongguoAccountReadJSON(response *http.Response) (map[string]any, error) {
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("账号请求失败（HTTP %d）", response.StatusCode)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, hongguoAccountMaxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if len(content) == 0 {
		return nil, errHongguoAccountEmptyBody
	}
	if len(content) > hongguoAccountMaxBodyBytes {
		return nil, errors.New("账号接口响应过大")
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil || result == nil {
		return nil, errors.New("账号接口返回格式异常")
	}
	return result, nil
}

func hongguoAccountContentParams(content string) (map[string]any, error) {
	if strings.TrimSpace(content) == "" {
		return map[string]any{}, nil
	}
	var params map[string]any
	decoder := json.NewDecoder(strings.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&params); err != nil || params == nil {
		return nil, errors.New("请求格式无效")
	}
	return params, nil
}

func hongguoAccountContentBool(params map[string]any, key string) bool {
	value, _ := params[key].(bool)
	return value
}

// hongguoAccountPassportCall：对照仓验通的 App 形态 passport 请求。form 为真时
// 参数进表单体（POST），为假时进查询串（GET）；查询串刻意不带 device_id/iid；
// 刻意不回发 Cookie，Set-Cookie 只收进本次登录会话、不进共享 Cookie 罐。
func (downloader *Downloader) hongguoAccountPassportCall(ctx context.Context, baseURL, deviceID, installID, path string, params []hongguoAccountFormField, form bool, session *hongguoAccountPhoneSession) (map[string]any, error) {
	query := hongguoAccountQuery(deviceID, installID, "74332", "7.4.3.32", false)
	var body []byte
	method := http.MethodGet
	if form {
		fields := []hongguoAccountFormField{
			{key: "aid", value: "8662"},
			{key: "app_name", value: "novelread"},
			{key: "device_platform", value: "android"},
		}
		fields = append(fields, params...)
		body = []byte(hongguoAccountFormEncode(fields))
		method = http.MethodPost
	} else {
		for _, field := range params {
			if field.value != "" {
				query.Set(field.key, field.value)
			}
		}
		query.Set("aid", "8662")
		query.Set("app_name", "novelread")
		query.Set("device_platform", "android")
	}
	request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(baseURL, "/")+path+"?"+query.Encode(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if form {
		request.Header.Set("User-Agent", hongguoAccountPassportVideoUA)
	} else {
		request.Header.Set("User-Agent", hongguoAccountPassportAppUA)
	}
	request.Header.Set("Accept", "application/json")
	if form {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	hongguoSignRequest(request, body, time.Now(), hongguoSignOptions{MedusaDeviceID: deviceID})
	response, err := downloader.doPreparedCatalogRequest(request, hongguoAccountRequestTimeout, nil)
	if err != nil {
		return nil, err
	}
	for _, cookie := range response.Cookies() {
		if cookie.Name == "" || cookie.Value == "" {
			continue
		}
		session.cookies[cookie.Name] = cookie.Value
	}
	return hongguoAccountReadJSON(response)
}

func (downloader *Downloader) hongguoAccountDevice(ctx context.Context) (string, string, error) {
	if err := downloader.ensureHongguoDevice(ctx, ""); err != nil {
		return "", "", err
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.state.DeviceID, client.state.InstallID, nil
}

func (downloader *Downloader) hongguoAccountPhoneSession() *hongguoAccountPhoneSession {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.accountPhone
}

func (downloader *Downloader) hongguoAccountSetPhoneSession(session *hongguoAccountPhoneSession) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	client.accountPhone = session
}

func (downloader *Downloader) hongguoAccountSendSms(ctx context.Context, mobile string) (map[string]any, error) {
	deviceID, installID, err := downloader.hongguoAccountDevice(ctx)
	if err != nil {
		return nil, err
	}
	session := &hongguoAccountPhoneSession{
		mobile:    mobile,
		deviceID:  deviceID,
		installID: installID,
		cookies:   map[string]string{},
	}
	downloader.hongguoAccountSetPhoneSession(session)
	reply, err := downloader.hongguoAccountPassportCall(ctx, hongguoPassportBaseURL, deviceID, installID, "/passport/mobile/send_code/v1/", []hongguoAccountFormField{
		{key: "mobile", value: mobile},
		{key: "type", value: "24"},
	}, false, session)
	if err != nil {
		return nil, err
	}
	data, _ := reply["data"].(map[string]any)
	if data == nil {
		data = map[string]any{}
	}
	if _, slider := data["verify_center_decision_conf"]; slider {
		return nil, errors.New("平台要求先完成滑块验证，当前电视登录流程不支持，尚未完成登录")
	}
	if mapString(reply, "message") != "success" {
		if hongguoAccountErrorCode(data) == 7 {
			return nil, errors.New("平台限流：请求太频繁，请等 60 秒后再试（错误码 7）")
		}
		if described := hongguoAccountDescribe(data); described != "" {
			return nil, errors.New(described)
		}
		return nil, errors.New("验证码没发出去")
	}
	session.ticket = mapString(data, "mobile_ticket")
	masked := mapString(data, "mobile")
	if masked == "" {
		masked = mobile
	}
	return map[string]any{
		"maskedMobile": masked,
		"retrySeconds": hongguoAccountInt(data, "retry_time", 60),
	}, nil
}

var hongguoAccountVerifyAttempts = []struct {
	path string
	form bool
}{
	{"/passport/mobile/sms_login/", true},
	{"/passport/mobile/sms_login_only/", true},
	{"/passport/mobile/sms_login_continue/", true},
	{"/passport/mobile/validate_code/v1/", false},
	{"/passport/mobile/validate_code/v1/", true},
}

func (downloader *Downloader) hongguoAccountVerifySms(ctx context.Context, mobile, code string) (map[string]any, error) {
	session := downloader.hongguoAccountPhoneSession()
	if session == nil || session.deviceID == "" {
		return nil, errors.New("请先发送验证码")
	}
	if session.expired {
		return nil, errors.New("本次登录会话已失效，请重新获取验证码")
	}
	var firstFailure error
	for _, attempt := range hongguoAccountVerifyAttempts {
		reply, err := downloader.hongguoAccountPassportCall(ctx, hongguoPassportBaseURL, session.deviceID, session.installID, attempt.path, []hongguoAccountFormField{
			{key: "mobile", value: mobile},
			{key: "code", value: code},
			{key: "type", value: "24"},
			{key: "mobile_ticket", value: session.ticket},
		}, attempt.form, session)
		if err != nil {
			return nil, err
		}
		if _, ok := session.cookies["sessionid"]; ok {
			break
		}
		data, _ := reply["data"].(map[string]any)
		if data == nil {
			data = map[string]any{}
		}
		if fresh := mapString(data, "mobile_ticket"); fresh != "" {
			session.ticket = fresh
		}
		errorCode := hongguoAccountErrorCode(data)
		switch {
		case errorCode == 0 || errorCode == 1:
			if errorCode == 1 && firstFailure == nil {
				firstFailure = errors.New("会话过期，请重新登录（错误码 1）")
			}
			continue
		case errorCode == 1203:
			session.expired = true
			session.cookies = map[string]string{}
			session.ticket = ""
			if described := hongguoAccountDescribe(data); described != "" {
				return nil, errors.New(described)
			}
			return nil, errors.New("错误次数过多或验证码过期，请重新获取验证码（错误码 1203）")
		default:
			if described := hongguoAccountDescribe(data); described != "" {
				return nil, errors.New(described)
			}
			return nil, fmt.Errorf("验证码校验失败（错误码 %d）", errorCode)
		}
	}
	if _, ok := session.cookies["sessionid"]; !ok {
		if firstFailure != nil {
			return nil, firstFailure
		}
		return nil, errors.New("登录没有成功，平台没有下发登录态")
	}
	parts := make([]string, 0, len(session.cookies))
	for name, value := range session.cookies {
		parts = append(parts, name+"="+value)
	}
	sort.Strings(parts)
	cookie := strings.Join(parts, "; ")
	// 对照仓的验码路只返回 Cookie；魔蚁是会话制，这里再落进 hongguoAccountSession
	//（来源 app），云端函数与 ExportSession 才能直接读到，不另起一套会话。
	downloader.setHongguoAccountSession(hongguoAccountSession{
		Cookie: cookie, DeviceID: session.deviceID, InstallID: session.installID,
		Source: hongguoAccountCookieAppSource,
	})
	return map[string]any{
		"cookie":    cookie,
		"deviceId":  session.deviceID,
		"installId": session.installID,
	}, nil
}

func hongguoAccountQRSeconds(expiry, now int64) int {
	if expiry > 1000000000 {
		seconds := expiry - now
		if seconds < 0 {
			seconds = 0
		}
		if seconds > 600 {
			seconds = 600
		}
		return int(seconds)
	}
	if expiry < 0 {
		expiry = 0
	}
	if expiry > 600 {
		expiry = 600
	}
	return int(expiry)
}

func (downloader *Downloader) hongguoAccountQrCode(ctx context.Context) (map[string]any, error) {
	image, seconds, err := downloader.hongguoLoginQR(ctx)
	if err != nil {
		return nil, err
	}
	decoded, err := base64.StdEncoding.DecodeString(image)
	if err != nil {
		return nil, errors.New("官网登录返回格式异常")
	}
	return map[string]any{
		"imageBase64":      base64.StdEncoding.EncodeToString(decoded),
		"expiresInSeconds": seconds,
	}, nil
}

func (downloader *Downloader) hongguoAccountQrPoll(ctx context.Context) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	token := client.qrToken
	client.mu.Unlock()
	if token == "" {
		return nil, errors.New("请先获取二维码")
	}
	reply, err := downloader.hongguoWebCall(ctx, "/passport/web/check_qrconnect/", url.Values{"next": {hongguoWebBaseURL + "/"}, "token": {token}}, nil)
	if err != nil {
		return nil, err
	}
	data, err := hongguoWebChecked(reply)
	if err != nil {
		return nil, err
	}
	switch status := mapString(data, "status"); status {
	case "5", "expired":
		return map[string]any{"result": "expired"}, nil
	case "3", "confirmed":
		if redirect := mapString(data, "redirect_url"); redirect != "" {
			if err := downloader.hongguoLoginFinishRedirect(ctx, redirect); err != nil {
				return nil, err
			}
		}
		if hongguoClientHasWebSession(client) {
			// 与 hongguoLoginQRPoll 同样：确认后当场把站内 Cookie 落进账号会话槽。
			client.mu.Lock()
			cookie := client.hongguoCookieHeader("hongguoduanju.com")
			expiry := client.hongguoCookieExpiryLocked("hongguoduanju.com")
			deviceID, installID := client.state.DeviceID, client.state.InstallID
			client.mu.Unlock()
			downloader.setHongguoAccountSession(hongguoAccountSession{
				Cookie: cookie, DeviceID: deviceID, InstallID: installID,
				ExpiresAt: expiry, Source: hongguoAccountCookieWebSource,
			})
			return map[string]any{"result": "confirmed"}, nil
		}
		return map[string]any{"result": "scanned"}, nil
	case "2":
		return map[string]any{"result": "scanned"}, nil
	default:
		return map[string]any{"result": "waiting"}, nil
	}
}

func (downloader *Downloader) hongguoAccountQrConfirm(ctx context.Context) (map[string]any, error) {
	client := downloader.hongguoClient()
	if !hongguoClientHasWebSession(client) {
		return nil, errors.New("官网尚未下发登录态，请先在手机确认登录")
	}
	if _, err := downloader.hongguoLoginAccountInfo(ctx); err != nil {
		return nil, err
	}
	return map[string]any{
		"cookie":    hongguoClientWebCookie(client),
		"deviceId":  "",
		"installId": "",
	}, nil
}

// hongguoAccountProfile：读账号资料。魔蚁云端调用走会话制（hongguoAccountRequest
// 读 hongguoAccountSession 的 Cookie），不像对照仓那样由调用方传 cookie 参数；
// dispatch 层同样只解析 Content、不收 cookie。
func (downloader *Downloader) hongguoAccountProfile(ctx context.Context) (map[string]any, error) {
	reply, err := downloader.hongguoAccountRequest(ctx, http.MethodGet, "/reading/user/info/v1/", nil, nil)
	if err != nil {
		return nil, err
	}
	data := nestedMap(reply, "data")
	if data == nil {
		return nil, errors.New("账号资料为空")
	}
	return map[string]any{"profile": data}, nil
}
