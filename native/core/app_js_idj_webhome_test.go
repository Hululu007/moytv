package core

// WebHome 对照补宿主测试（point1）：host.res / http responseType+
// ok/cookies / host.pan.check / host.history.list / 上下文三件套。
// 夹具是新写的迷你合成插件脚本，不粘贴任何真实插件或 easytv 代码。

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// idjWebhomeManifest 在通用测试 manifest 上加 permissions.pan。
func idjWebhomeManifest(t *testing.T, pan bool, httpDomains ...string) string {
	t.Helper()
	m := map[string]interface{}{
		"id":           "com.test.plugin",
		"name":         "测试插件",
		"version":      "1.0.0",
		"entry":        "main.js",
		"type":         "video",
		"capabilities": []string{"home", "category", "search", "detail", "play"},
		"permissions": map[string]interface{}{
			"http":       httpDomains,
			"media":      httpDomains,
			"storage":    true,
			"cloudflare": false,
			"login":      false,
			"pan":        pan,
		},
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("拼测试 manifest 失败: %v", err)
	}
	return string(b)
}

// TestIdjHostResProxy：第 1 项——host.res 同步返回本地代理 URL，
// 代理端点带上插件给的请求头取源、透传 Range、回源站状态与正文。
func TestIdjHostResProxy(t *testing.T) {
	idjEnableLoopback(t)
	var gotReferer, gotRange string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotReferer = r.Header.Get("Referer")
		gotRange = r.Header.Get("Range")
		if gotRange != "" {
			w.Header().Set("Content-Range", "bytes 2-5/11")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = io.WriteString(w, "llo ")
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = io.WriteString(w, "hello res!!")
	}))
	defer server.Close()
	manifest := idjTestManifest(t, "127.0.0.1")
	script := `
function home() {
  var proxied = host.res("` + server.URL + `/poster.jpg", { headers: { Referer: "https://example.com/" } });
  return { proxied: proxied, kind: typeof proxied };
}
`
	dir := t.TempDir()
	out, err := idjTestCall(t, dir, "com.test.plugin", script, manifest, "home", "{}")
	if err != nil {
		t.Fatalf("home 调用失败: %v", err)
	}
	if got := idjResultString(t, out, "kind"); got != "string" {
		t.Fatalf("host.res 应同步返回字符串，实际 typeof=%s", got)
	}
	proxied := idjResultString(t, out, "proxied")
	if !strings.HasPrefix(proxied, "http://127.0.0.1:") || !strings.Contains(proxied, "/idjres/") {
		t.Fatalf("代理 URL 形态不对: %s", proxied)
	}
	resp, err := http.Get(proxied)
	if err != nil {
		t.Fatalf("请求代理 URL 失败: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || string(body) != "hello res!!" {
		t.Fatalf("代理回源不对: status=%d body=%q", resp.StatusCode, body)
	}
	if gotReferer != "https://example.com/" {
		t.Fatalf("代理未带上插件请求头 Referer，实际 %q", gotReferer)
	}
	req, _ := http.NewRequest(http.MethodGet, proxied, nil)
	req.Header.Set("Range", "bytes=2-5")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Range 请求代理失败: %v", err)
	}
	body2, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusPartialContent || string(body2) != "llo " {
		t.Fatalf("Range 透传不对: status=%d body=%q", resp2.StatusCode, body2)
	}
	if gotRange != "bytes=2-5" {
		t.Fatalf("源站未收到透传的 Range，实际 %q", gotRange)
	}
}

// TestIdjHostResWhitelist：第 1 项——白名单外域名 host.res 同步抛
// E_PERMISSION，不许静默返回代理地址。
func TestIdjHostResWhitelist(t *testing.T) {
	manifest := idjTestManifest(t, "127.0.0.1")
	script := `
function home() {
  try {
    host.res("https://evil.example.com/poster.jpg");
    return { code: "" };
  } catch (e) {
    return { code: e.code || "" };
  }
}
`
	out, err := idjTestCall(t, t.TempDir(), "com.test.plugin", script, manifest, "home", "{}")
	if err != nil {
		t.Fatalf("home 调用失败: %v", err)
	}
	if got := idjResultString(t, out, "code"); got != "E_PERMISSION" {
		t.Fatalf("白名单外 host.res 应抛 E_PERMISSION，实际 %q", got)
	}
}

// TestIdjHTTPResponseTypeAndFields：第 2 项——responseType json /
// base64 与新增 ok/cookies 字段；默认 text 行为与旧字段不变；
// json 解析失败 reject E_PARSE；非法 responseType reject E_ARGS。
func TestIdjHTTPResponseTypeAndFields(t *testing.T) {
	idjEnableLoopback(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/json":
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Set-Cookie", "sid=abc123; Path=/")
			_, _ = io.WriteString(w, `{"a":1,"b":"x"}`)
		case "/bin":
			_, _ = w.Write([]byte{0x00, 0x01, 0xfe, 0xff})
		case "/text":
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, "plain-body")
		}
	}))
	defer server.Close()
	idjResetRate("com.test.plugin")
	manifest := idjTestManifest(t, "127.0.0.1")
	script := `
async function home() {
  var out = {};
  var rj = await host.http.request({ url: "` + server.URL + `/json", responseType: "json" });
  out.jsonA = rj.body.a;
  out.jsonB = rj.body.b;
  out.jsonOk = rj.ok;
  out.jsonStatus = rj.status;
  out.cookies = rj.cookies.join(",");
  var rb = await host.http.request({ url: "` + server.URL + `/bin", responseType: "base64" });
  out.bin64 = rb.body;
  var rt = await host.http.request({ url: "` + server.URL + `/text" });
  out.textBody = rt.body;
  out.textOk = rt.ok;
  out.textStatus = rt.status;
  try {
    await host.http.request({ url: "` + server.URL + `/text", responseType: "json" });
    out.parseCode = "";
  } catch (e) { out.parseCode = e.code || ""; }
  try {
    await host.http.request({ url: "` + server.URL + `/json", responseType: "xml" });
    out.typeCode = "";
  } catch (e) { out.typeCode = e.code || ""; }
  return out;
}
`
	out, err := idjTestCall(t, t.TempDir(), "com.test.plugin", script, manifest, "home", "{}")
	if err != nil {
		t.Fatalf("home 调用失败: %v", err)
	}
	if got := out["jsonA"]; got != float64(1) {
		t.Fatalf("responseType json 应解析出 body.a=1，实际 %v", got)
	}
	if got := idjResultString(t, out, "jsonB"); got != "x" {
		t.Fatalf("responseType json body.b 不对: %q", got)
	}
	if out["jsonOk"] != true || out["jsonStatus"] != float64(200) {
		t.Fatalf("json 响应 ok/status 不对: %v", out)
	}
	if got := idjResultString(t, out, "cookies"); got != "sid=abc123" {
		t.Fatalf("cookies 字段不对: %q", got)
	}
	want64 := base64.StdEncoding.EncodeToString([]byte{0x00, 0x01, 0xfe, 0xff})
	if got := idjResultString(t, out, "bin64"); got != want64 {
		t.Fatalf("responseType base64 不对: got %q want %q", got, want64)
	}
	if got := idjResultString(t, out, "textBody"); got != "plain-body" {
		t.Fatalf("默认 text body 不对: %q", got)
	}
	if out["textOk"] != false || out["textStatus"] != float64(404) {
		t.Fatalf("404 响应 ok 应为 false、status 应为 404: %v", out)
	}
	if got := idjResultString(t, out, "parseCode"); got != "E_PARSE" {
		t.Fatalf("json 解析失败应 reject E_PARSE，实际 %q", got)
	}
	if got := idjResultString(t, out, "typeCode"); got != "E_ARGS" {
		t.Fatalf("非法 responseType 应 reject E_ARGS，实际 %q", got)
	}
}

// TestIdjPanCheckGate：第 3 项——无 pan 权限 reject E_PERMISSION；
// 有权限但检测器未注入 reject E_UNSUPPORTED（不假实现）；注入
// 检测器后结果原样透传且 type 已归一（别名 alipan → aliyun）。
func TestIdjPanCheckGate(t *testing.T) {
	script := `
async function home() {
  try {
    var r = await host.pan.check([{ type: "alipan", url: "https://www.aliyundrive.com/s/xxxx", password: "1234" }]);
    return { code: "", state: r.results[0].state, typ: r.results[0].type };
  } catch (e) {
    return { code: e.code || "", state: "", typ: "" };
  }
}
`
	// 无权限。
	out, err := idjTestCall(t, t.TempDir(), "com.test.plugin", script, idjWebhomeManifest(t, false), "home", "{}")
	if err != nil {
		t.Fatalf("无权限调用失败: %v", err)
	}
	if got := idjResultString(t, out, "code"); got != "E_PERMISSION" {
		t.Fatalf("无 pan 权限应 reject E_PERMISSION，实际 %q", got)
	}
	// 有权限、未注入检测器。
	out, err = idjTestCall(t, t.TempDir(), "com.test.plugin", script, idjWebhomeManifest(t, true), "home", "{}")
	if err != nil {
		t.Fatalf("未注入调用失败: %v", err)
	}
	if got := idjResultString(t, out, "code"); got != "E_UNSUPPORTED" {
		t.Fatalf("检测器未注入应 reject E_UNSUPPORTED，实际 %q", got)
	}
	// 注入检测器后透传。
	var gotItems []idjPanItem
	old := idjPanChecker
	idjPanChecker = func(items []idjPanItem) ([]map[string]interface{}, error) {
		gotItems = items
		return []map[string]interface{}{{"type": items[0].Type, "url": items[0].URL, "state": "ok"}}, nil
	}
	t.Cleanup(func() { idjPanChecker = old })
	out, err = idjTestCall(t, t.TempDir(), "com.test.plugin", script, idjWebhomeManifest(t, true), "home", "{}")
	if err != nil {
		t.Fatalf("注入后调用失败: %v", err)
	}
	if got := idjResultString(t, out, "state"); got != "ok" {
		t.Fatalf("检测结果未透传: %v", out)
	}
	if len(gotItems) != 1 || gotItems[0].Type != "aliyun" || gotItems[0].Password != "1234" {
		t.Fatalf("检测器收到的条目未归一: %+v", gotItems)
	}
	if got := idjResultString(t, out, "typ"); got != "aliyun" {
		t.Fatalf("结果 type 应为归一后的 aliyun，实际 %q", got)
	}
}

// TestIdjPanParseItems：第 3 项——参数归一化纯函数：别名、超量、
// 未知类型、坏 URL 都如实报错。
func TestIdjPanParseItems(t *testing.T) {
	items, err := idjPanParseItems([]interface{}{
		map[string]interface{}{"type": "189", "url": "https://cloud.189.cn/t/xxxx"},
		map[string]interface{}{"type": "quark", "url": "https://pan.quark.cn/s/yyyy", "password": "ab"},
	})
	if err != nil {
		t.Fatalf("合法条目解析失败: %v", err)
	}
	if items[0].Type != "tianyi" || items[1].Type != "quark" || items[1].Password != "ab" {
		t.Fatalf("归一结果不对: %+v", items)
	}
	for name, raw := range map[string]interface{}{
		"未知类型": []interface{}{map[string]interface{}{"type": "dropbox", "url": "https://example.com/s/x"}},
		"坏地址":  []interface{}{map[string]interface{}{"type": "quark", "url": "ftp://example.com/x"}},
		"空数组":  []interface{}{},
	} {
		if _, err := idjPanParseItems(raw); err == nil {
			t.Fatalf("%s 应报错，实际成功", name)
		} else {
			var coded *idjError
			if !errors.As(err, &coded) || coded.code != "E_ARGS" {
				t.Fatalf("%s 应报 E_ARGS，实际 %v", name, err)
			}
		}
	}
	many := make([]interface{}, 0, idjPanMaxItems+1)
	for i := 0; i <= idjPanMaxItems; i++ {
		many = append(many, map[string]interface{}{"type": "quark", "url": "https://pan.quark.cn/s/x"})
	}
	if _, err := idjPanParseItems(many); err == nil {
		t.Fatal("超 20 条应报错，实际成功")
	}
}

// TestIdjHistoryListGate：第 4 项——provider 未注入 reject
// E_UNSUPPORTED；注入后按本站 siteKey 查询、limit 夹到上限 50、
// 结果原样透传。
func TestIdjHistoryListGate(t *testing.T) {
	script := `
async function home() {
  try {
    var rows = await host.history.list({ limit: 999 });
    return { code: "", n: rows.length, name: rows.length ? rows[0].vodName : "" };
  } catch (e) {
    return { code: e.code || "", n: -1, name: "" };
  }
}
`
	manifest := idjTestManifest(t)
	out, err := idjTestCall(t, t.TempDir(), "com.test.plugin", script, manifest, "home", "{}")
	if err != nil {
		t.Fatalf("未注入调用失败: %v", err)
	}
	if got := idjResultString(t, out, "code"); got != "E_UNSUPPORTED" {
		t.Fatalf("provider 未注入应 reject E_UNSUPPORTED，实际 %q", got)
	}
	var gotKey string
	var gotLimit int
	old := idjHistoryProvider
	idjHistoryProvider = func(siteKey string, limit int) ([]map[string]interface{}, error) {
		gotKey, gotLimit = siteKey, limit
		return []map[string]interface{}{{"vodId": "v1", "vodName": "片名一", "position": float64(120)}}, nil
	}
	t.Cleanup(func() { idjHistoryProvider = old })
	out, err = idjTestCall(t, t.TempDir(), "com.test.plugin", script, manifest, "home", "{}")
	if err != nil {
		t.Fatalf("注入后调用失败: %v", err)
	}
	if gotKey != "com.test.plugin" {
		t.Fatalf("provider 应收到本站 siteKey，实际 %q", gotKey)
	}
	if gotLimit != idjHistoryMaxLimit {
		t.Fatalf("limit 应夹到 %d，实际 %d", idjHistoryMaxLimit, gotLimit)
	}
	if got := idjResultString(t, out, "name"); got != "片名一" {
		t.Fatalf("历史结果未透传: %v", out)
	}
	if out["n"] != float64(1) {
		t.Fatalf("历史条数不对: %v", out)
	}
}

// TestIdjContextSync：第 5 项——site/config/device 同步只读返回；
// site 取 manifest 身份；config.driveCheck 默认 false（壳无此开关，
// 不编假值）；device 只给形态字段，绝无 uuid/serial/mac 类键。
func TestIdjContextSync(t *testing.T) {
	script := `
function home() {
  var site = host.site();
  var cfg = host.config();
  var dev = host.device();
  return {
    siteKey: site.key, siteName: site.name, siteType: site.type,
    cfgDrive: cfg.driveCheck, cfgHasSecret: ("secret" in cfg) || ("token" in cfg),
    form: dev.form, leanback: dev.leanback, os: dev.os,
    devKeys: Object.keys(dev).sort().join(","),
    hasCap: host.has("res") && host.has("pan.check") && host.has("history.list") && host.has("site")
  };
}
`
	out, err := idjTestCall(t, t.TempDir(), "com.test.plugin", script, idjTestManifest(t), "home", "{}")
	if err != nil {
		t.Fatalf("home 调用失败: %v", err)
	}
	if got := idjResultString(t, out, "siteKey"); got != "com.test.plugin" {
		t.Fatalf("site.key 不对: %q", got)
	}
	if got := idjResultString(t, out, "siteName"); got != "测试插件" {
		t.Fatalf("site.name 不对: %q", got)
	}
	if got := idjResultString(t, out, "siteType"); got != "video" {
		t.Fatalf("site.type 不对: %q", got)
	}
	if out["cfgDrive"] != false {
		t.Fatalf("config.driveCheck 默认应为 false，实际 %v", out["cfgDrive"])
	}
	if out["cfgHasSecret"] != false {
		t.Fatal("config 不许带 secret/token 字段")
	}
	if got := idjResultString(t, out, "form"); got != "mobile" {
		t.Fatalf("device.form 默认应为 mobile，实际 %q", got)
	}
	if got := idjResultString(t, out, "os"); got != "android" {
		t.Fatalf("device.os 默认应为 android，实际 %q", got)
	}
	keys := idjResultString(t, out, "devKeys")
	for _, banned := range []string{"uuid", "serial", "mac", "imei", "deviceId"} {
		if strings.Contains(strings.ToLower(keys), banned) {
			t.Fatalf("device 不许下发 %s，实际键: %s", banned, keys)
		}
	}
	if keys != "form,leanback,os,osVersion" {
		t.Fatalf("device 键集合不对: %s", keys)
	}
	if out["hasCap"] != true {
		t.Fatal("host.has 应报告新能力 res/pan.check/history.list/site 为 true")
	}
}
