package core

// iDuanJu 兼容层测试（设计 §8.2 的表 ①–⑧ + 第二阶段 host.*）。
// 夹具是新写的迷你合成插件脚本，绝不粘贴真实 main.js 片段；
// 真插件只在测试 ① 里读工作目录外的原文件（不存在时跳过），
// 绝不把插件文件提交进树。

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func idjTestManifest(t *testing.T, httpDomains ...string) string {
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
		},
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("拼测试 manifest 失败: %v", err)
	}
	return string(b)
}

func idjTestCall(t *testing.T, dir, pluginID, script, manifest, fn, args string) (map[string]interface{}, error) {
	t.Helper()
	return idjCallWithDirectory(dir, pluginID, script, manifest, fn, args)
}

// idjEnableLoopback：httptest 跑在 127.0.0.1 上，本机拦截与白名单
// 会拦它；测试内放行回环地址，用完恢复（生产恒 false）。
func idjEnableLoopback(t *testing.T) {
	t.Helper()
	old := idjAllowLoopback
	idjAllowLoopback = true
	t.Cleanup(func() { idjAllowLoopback = false; _ = old })
}

func idjAssertCode(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("期望错误 %s，实际调用成功", code)
	}
	var coded *idjError
	if !errors.As(err, &coded) {
		t.Fatalf("期望带码错误，实际 %T: %v", err, err)
	}
	if coded.code != code {
		t.Fatalf("期望码 %s，实际码 %s（%v）", code, coded.code, err)
	}
}

func idjResetRate(pluginID string) {
	idjRateMu.Lock()
	delete(idjRateWindows, pluginID)
	idjRateMu.Unlock()
}

func idjResultString(t *testing.T, m map[string]interface{}, key string) string {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("结果里没有 %q：%v", key, m)
	}
	s, ok := v.(string)
	if !ok {
		t.Fatalf("结果 %q 期望字符串，实际 %T %v", key, v, v)
	}
	return s
}

// TestIdjRealPluginLoad ①：加载器行级兜底——4 个真插件原文件加载 +
// 5 个入口全找到。先断言共享剥离器对其中 3 个确实没转出
// export default（兜底是被真实需要的），再走正式 idjCall 的
// __probe 断言 4 个全过。文件不存在时跳过。
func TestIdjRealPluginLoad(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("..", "..", "..", "idjplugin_adapt_20261124", "plugins", "*.idjplugin"))
	if err != nil || len(paths) == 0 {
		t.Skip("真插件文件不在工作目录外，跳过")
	}
	needFallback := 0
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读插件文件失败: %v", err)
		}
		var bundle struct {
			Manifest json.RawMessage   `json:"manifest"`
			Files    map[string]string `json:"files"`
		}
		if err := json.Unmarshal(raw, &bundle); err != nil {
			t.Fatalf("解析 .idjplugin 失败: %v", err)
		}
		script, ok := bundle.Files["main.js"]
		if !ok {
			t.Fatalf("%s 里没有 main.js", path)
		}
		var manifestDoc struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(bundle.Manifest, &manifestDoc); err != nil {
			t.Fatalf("解析 manifest 失败: %v", err)
		}
		if manifestDoc.ID == "" {
			t.Fatalf("%s 的 manifest 没有 id", path)
		}
		stripped := jsStripModuleSyntax(script)
		if !stripped.hadDefault {
			needFallback++
		}
		dir := t.TempDir()
		out, err := idjCallWithDirectory(dir, manifestDoc.ID, script, string(bundle.Manifest), "__probe", "{}")
		if err != nil {
			t.Fatalf("%s __probe 失败: %v", manifestDoc.ID, err)
		}
		foundJSON, _ := json.Marshal(out["found"])
		var found []string
		_ = json.Unmarshal(foundJSON, &found)
		if len(found) != 5 {
			t.Fatalf("%s 期望找到 5 个入口，实际 %v", manifestDoc.ID, out["found"])
		}
		t.Logf("%s：加载通过，5 个入口全找到（hadDefault=%v）", manifestDoc.ID, stripped.hadDefault)
	}
	if needFallback == 0 {
		t.Fatalf("期望至少一个真插件需要行级兜底（hadDefault=false），实际 0 个——兜底路径没被测到")
	}
	t.Logf("真插件加载汇总：%d 个文件，%d 个需要兜底改写", len(paths), needFallback)
}

type idjEchoCapture struct {
	mu       sync.Mutex
	method   string
	body     string
	cookie   string
	auth     string
	xOk      string
	seenHost string
}

// TestIdjHTTPRequest ②：host.http.request 对本地 httptest 发 GET/POST。
func TestIdjHTTPRequest(t *testing.T) {
	idjEnableLoopback(t)
	dir := t.TempDir()
	pluginID := "com.test.http"
	manifest := idjTestManifest(t, "127.0.0.1")
	cap := &idjEchoCapture{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cap.mu.Lock()
		defer cap.mu.Unlock()
		switch r.URL.Path {
		case "/echo":
			body, _ := io.ReadAll(r.Body)
			cap.method, cap.body = r.Method, string(body)
			cap.cookie = r.Header.Get("Cookie")
			cap.auth = r.Header.Get("Authorization")
			cap.xOk = r.Header.Get("X-Ok")
			cap.seenHost = r.Host
			w.Header().Set("X-Test-Value", "v1")
			w.Header().Set("X-Another", "v2")
			_, _ = w.Write([]byte("ok"))
		case "/slow":
			time.Sleep(2 * time.Second)
			_, _ = w.Write([]byte("slow-ok"))
		case "/big":
			_, _ = w.Write(bytes.Repeat([]byte("x"), 2048))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	base := server.URL

	reqScript := `
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status, url: r.url, headers: r.headers, body: r.body};
  },
  async chk(arg) { return {allowed: host.http.allowed(arg.url)}; }
};
`
	_ = reqScript

	t.Run("GET与POST", func(t *testing.T) {
		out, err := idjTestCall(t, dir, pluginID, strings.ReplaceAll(`
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status, headers: r.headers, body: r.body};
  }
};
`, "__BASE__", base), manifest, "req", `{"url": "`+base+`/echo", "headers": {"X-Ok": "yes"}}`)
		if err != nil {
			t.Fatalf("GET 调用失败: %v", err)
		}
		if out["status"] != float64(200) {
			t.Fatalf("期望 status 200，实际 %v", out["status"])
		}
		headers, _ := out["headers"].(map[string]interface{})
		if headers["x-test-value"] != "v1" || headers["x-another"] != "v2" {
			t.Fatalf("响应头键没有全小写：%v", out["headers"])
		}
		if _, ok := headers["X-Test-Value"]; ok {
			t.Fatalf("响应头里仍有大写键：%v", out["headers"])
		}
		cap.mu.Lock()
		method, cookie, auth, xOk := cap.method, cap.cookie, cap.auth, cap.xOk
		cap.mu.Unlock()
		if method != "GET" {
			t.Fatalf("method 省略时期望 GET，实际 %s", method)
		}
		if cookie != "" || auth != "" {
			t.Fatalf("禁发头没被剥离：Cookie=%q Authorization=%q", cookie, auth)
		}
		if xOk != "yes" {
			t.Fatalf("正常请求头没发过去：X-Ok=%q", xOk)
		}

		out, err = idjTestCall(t, dir, pluginID, strings.ReplaceAll(`
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status, body: r.body};
  }
};
`, "__BASE__", base), manifest, "req", `{"url": "`+base+`/echo", "method": "POST", "body": "a=1&b=2", "headers": {"Content-Type": "application/x-www-form-urlencoded"}}`)
		if err != nil {
			t.Fatalf("POST 调用失败: %v", err)
		}
		cap.mu.Lock()
		method, body := cap.method, cap.body
		cap.mu.Unlock()
		if method != "POST" || body != "a=1&b=2" {
			t.Fatalf("POST 没按预期发：method=%s body=%q", method, body)
		}
	})

	t.Run("禁发头剥离（Authorization 例外放行）", func(t *testing.T) {
		// 用户 2026-11-24 18:40 令：宿主放行 Authorization 头（只放这一个头）。
		// Cookie 等其余禁发头照旧剥离。
		script := `
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status};
  }
};
`
		_, err := idjTestCall(t, dir, pluginID, script, manifest, "req",
			`{"url": "`+base+`/echo", "headers": {"Cookie": "x=1", "Authorization": "Bearer z", "X-Ok": "yes"}}`)
		if err != nil {
			t.Fatalf("调用失败: %v", err)
		}
		cap.mu.Lock()
		cookie, auth, xOk := cap.cookie, cap.auth, cap.xOk
		cap.mu.Unlock()
		if cookie != "" {
			t.Fatalf("Cookie 请求头没被剥离，服务端收到 %q", cookie)
		}
		if auth != "Bearer z" {
			t.Fatalf("Authorization 请求头没放行，服务端收到 %q", auth)
		}
		if xOk != "yes" {
			t.Fatalf("正常请求头没发过去：X-Ok=%q", xOk)
		}
	})

	t.Run("timeout毫秒生效", func(t *testing.T) {
		script := `
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status};
  }
};
`
		_, err := idjTestCall(t, dir, pluginID, script, manifest, "req",
			`{"url": "`+base+`/slow", "timeout": 50}`)
		idjAssertCode(t, err, "E_TIMEOUT")
	})

	t.Run("超20MB报错", func(t *testing.T) {
		old := idjTestMaxBodyBytes
		idjTestMaxBodyBytes = 1024
		t.Cleanup(func() { idjTestMaxBodyBytes = old })
		script := `
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status};
  }
};
`
		_, err := idjTestCall(t, dir, pluginID, script, manifest, "req",
			`{"url": "`+base+`/big"}`)
		idjAssertCode(t, err, "E_INTERNAL")
	})

	t.Run("白名单外域名报E_PERMISSION", func(t *testing.T) {
		script := `
export default {
  async req(arg) {
    const r = await host.http.request(arg);
    return {status: r.status};
  },
  async chk(arg) { return {allowed: host.http.allowed(arg.url)}; }
};
`
		_, err := idjTestCall(t, dir, pluginID, script, manifest, "req",
			`{"url": "https://example.com/x"}`)
		idjAssertCode(t, err, "E_PERMISSION")
		out, err := idjTestCall(t, dir, pluginID, script, manifest, "chk",
			`{"url": "https://example.com/x"}`)
		if err != nil {
			t.Fatalf("allowed 调用失败: %v", err)
		}
		if out["allowed"] != false {
			t.Fatalf("白名单外域名 allowed 期望 false，实际 %v", out["allowed"])
		}
		out, err = idjTestCall(t, dir, pluginID, script, manifest, "chk",
			`{"url": "`+base+`/echo"}`)
		if err != nil {
			t.Fatalf("allowed 调用失败: %v", err)
		}
		if out["allowed"] != true {
			t.Fatalf("回环地址 allowed 期望 true，实际 %v", out["allowed"])
		}
	})
}

// TestIdjStorage ③：storage 跨 runtime 持久化、1MB 上限拒绝并回滚、
// 不同插件互不可见、未存过的 key 返回 null。
func TestIdjStorage(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t, "127.0.0.1")
	script := `
export default {
  async put(arg) { host.storage.set(arg.k, arg.v); return {ok: true}; },
  async get(arg) { return {v: host.storage.get(arg.k)}; },
  async del(arg) { host.storage.remove(arg.k); return {ok: true}; }
};
`
	pluginA := "com.test.storeA"
	pluginB := "com.test.storeB"

	if _, err := idjTestCall(t, dir, pluginA, script, manifest, "put", `{"k": "cg_last_v1", "v": "{\"id\":\"123\"}"}`); err != nil {
		t.Fatalf("set 失败: %v", err)
	}
	out, err := idjTestCall(t, dir, pluginA, script, manifest, "get", `{"k": "cg_last_v1"}`)
	if err != nil {
		t.Fatalf("跨调用 get 失败: %v", err)
	}
	if idjResultString(t, out, "v") != `{"id":"123"}` {
		t.Fatalf("跨 runtime 没读到持久化的值：%v", out)
	}
	out, err = idjTestCall(t, dir, pluginA, script, manifest, "get", `{"k": "no-such-key"}`)
	if err != nil {
		t.Fatalf("get 缺失键失败: %v", err)
	}
	if v, ok := out["v"]; !ok || v != nil {
		t.Fatalf("未存过的 key 期望 null，实际 %v", out)
	}
	out, err = idjTestCall(t, dir, pluginB, script, manifest, "get", `{"k": "cg_last_v1"}`)
	if err != nil {
		t.Fatalf("插件 B get 失败: %v", err)
	}
	if v, ok := out["v"]; !ok || v != nil {
		t.Fatalf("不同插件应互不可见，B 读到了 A 的值：%v", out)
	}
	if _, err := idjTestCall(t, dir, pluginA, script, manifest, "del", `{"k": "cg_last_v1"}`); err != nil {
		t.Fatalf("remove 失败: %v", err)
	}
	out, err = idjTestCall(t, dir, pluginA, script, manifest, "get", `{"k": "cg_last_v1"}`)
	if err != nil {
		t.Fatalf("删除后 get 失败: %v", err)
	}
	if v := out["v"]; v != nil {
		t.Fatalf("remove 后期望 null，实际 %v", out)
	}

	t.Run("1MB上限拒绝并回滚", func(t *testing.T) {
		old := idjTestMaxStorageBytes
		idjTestMaxStorageBytes = 64
		t.Cleanup(func() { idjTestMaxStorageBytes = old })
		if _, err := idjTestCall(t, dir, pluginA, script, manifest, "put", `{"k": "small", "v": "v1"}`); err != nil {
			t.Fatalf("小值 set 失败: %v", err)
		}
		big := strings.Repeat("x", 200)
		_, err := idjTestCall(t, dir, pluginA, script, manifest, "put", `{"k": "big", "v": "`+big+`"}`)
		idjAssertCode(t, err, "E_STORAGE_FULL")
		out, err := idjTestCall(t, dir, pluginA, script, manifest, "get", `{"k": "small"}`)
		if err != nil {
			t.Fatalf("回滚后 get 失败: %v", err)
		}
		if idjResultString(t, out, "v") != "v1" {
			t.Fatalf("超限写入没回滚，原值丢了：%v", out)
		}
		out, err = idjTestCall(t, dir, pluginA, script, manifest, "get", `{"k": "big"}`)
		if err != nil {
			t.Fatalf("get big 失败: %v", err)
		}
		if v := out["v"]; v != nil {
			t.Fatalf("超限的键不应写入，实际读到 %v", out)
		}
	})
}

// TestIdjErrorPassthrough ④：host.error 带 .code 回到 Go 侧，
// 规范码与插件自用规范外码都原样透传、不改写。
func TestIdjErrorPassthrough(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async boom() { throw host.error('E_PARSE', '解析失败'); },
  async boomNet() { throw host.error('E_NET', '网络炸了'); }
};
`
	_, err := idjTestCall(t, dir, "com.test.err", script, manifest, "boom", "{}")
	idjAssertCode(t, err, "E_PARSE")
	if !strings.Contains(err.Error(), "解析失败") {
		t.Fatalf("错误消息丢了原文：%v", err)
	}
	_, err = idjTestCall(t, dir, "com.test.err", script, manifest, "boomNet", "{}")
	idjAssertCode(t, err, "E_NET")
	if !strings.Contains(err.Error(), "网络炸了") {
		t.Fatalf("规范外码 E_NET 被改写或消息丢了：%v", err)
	}
}

// TestIdjPlayArgs ⑤：play 传参 4 站 fixture——插件收到的 id 必须是
// 分集键（episodeId），不是剧 id；line 是 flag 显示名。
func TestIdjPlayArgs(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async play(arg) { return {id: arg.id, episodeId: arg.episodeId, line: arg.line}; }
};
`
	cases := []struct {
		name     string
		fn       string
		args     string
		wantID   string
		wantLine string
	}{
		{"橙果：packId", "play", `{"id": "123", "episodeId": "123005", "line": "默认线路"}`, "123005", "默认线路"},
		{"爱果：集号字符串", "play", `{"id": "admin-drama-xyz", "episodeId": "7", "line": "默认线路"}`, "7", "默认线路"},
		{"潮流：线路键|视频id", "play", `{"id": "chinese_content/1/x", "episodeId": "key9|chinese_content/1/x", "line": "线路1 · 1080P"}`, "key9|chinese_content/1/x", "线路1 · 1080P"},
		{"2048：视频id", "play", `{"id": "98765", "episodeId": "98765", "line": "默认线路"}`, "98765", "默认线路"},
		{"Dart侧player名映射", "player", `{"id": "123", "episodeId": "123005", "line": "默认线路"}`, "123005", "默认线路"},
		{"只有id时不改写", "play", `{"id": "555"}`, "555", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, err := idjTestCall(t, dir, "com.test.play", script, manifest, tc.fn, tc.args)
			if err != nil {
				t.Fatalf("play 调用失败: %v", err)
			}
			if idjResultString(t, out, "id") != tc.wantID {
				t.Fatalf("插件收到的 id 期望 %q，实际 %v", tc.wantID, out)
			}
			if tc.wantLine != "" && idjResultString(t, out, "line") != tc.wantLine {
				t.Fatalf("插件收到的 line 期望 %q，实际 %v", tc.wantLine, out)
			}
			if tc.name == "橙果：packId" && out["id"] == "1" {
				t.Fatalf("橙果收到的 id 是第 1 集，传参修复没生效：%v", out)
			}
		})
	}
}

// TestIdjCookieJar ⑥：Cookie 罐两次调用间 Set-Cookie 能带到下次请求。
func TestIdjCookieJar(t *testing.T) {
	idjEnableLoopback(t)
	dir := t.TempDir()
	pluginID := "com.test.cookie"
	manifest := idjTestManifest(t, "127.0.0.1")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/set":
			w.Header().Set("Set-Cookie", "session=abc123; Path=/")
			_, _ = w.Write([]byte("set-ok"))
		case "/check":
			_, _ = w.Write([]byte("cookie:" + r.Header.Get("Cookie")))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	script := `
export default {
  async first(arg) {
    const r = await host.http.request({url: arg.base + "/set"});
    return {status: r.status};
  },
  async second(arg) {
    const r = await host.http.request({url: arg.base + "/check"});
    return {body: r.body};
  }
};
`
	args := `{"base": "` + server.URL + `"}`
	if _, err := idjTestCall(t, dir, pluginID, script, manifest, "first", args); err != nil {
		t.Fatalf("第一次调用失败: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "idj", pluginID, "cookies.json"))
	if err != nil {
		t.Fatalf("cookies.json 没落盘: %v", err)
	}
	if !strings.Contains(string(data), "abc123") {
		t.Fatalf("cookies.json 里没有这次的 Set-Cookie：%s", data)
	}
	out, err := idjTestCall(t, dir, pluginID, script, manifest, "second", args)
	if err != nil {
		t.Fatalf("第二次调用失败: %v", err)
	}
	if !strings.Contains(idjResultString(t, out, "body"), "session=abc123") {
		t.Fatalf("第二次请求没带上上次的 Cookie：%v", out)
	}
}

// TestIdjRateLimits ⑦：限额 60 次/调用、120 次/分钟。
func TestIdjRateLimits(t *testing.T) {
	idjEnableLoopback(t)
	dir := t.TempDir()
	manifest := idjTestManifest(t, "127.0.0.1")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()
	script := `
export default {
  async batch(arg) {
    let ok = 0, code = "", message = "";
    for (let i = 0; i < 65; i++) {
      try { await host.http.request({url: arg.base + "/echo"}); ok++; }
      catch (e) { code = e.code; message = e.message; break; }
    }
    return {ok: ok, code: code, message: message};
  }
};
`
	args := `{"base": "` + server.URL + `"}`

	t.Run("60次调用上限", func(t *testing.T) {
		pluginID := "com.test.rate-call"
		idjResetRate(pluginID)
		out, err := idjTestCall(t, dir, pluginID, script, manifest, "batch", args)
		if err != nil {
			t.Fatalf("batch 调用失败: %v", err)
		}
		if out["ok"] != float64(60) {
			t.Fatalf("单次调用期望放行 60 次，实际 %v", out)
		}
		if out["code"] != "E_RATE_LIMIT" {
			t.Fatalf("第 61 次期望 E_RATE_LIMIT，实际 %v", out)
		}
		msg, _ := out["message"].(string)
		if !strings.Contains(msg, "测试插件") || !strings.Contains(msg, "60") {
			t.Fatalf("限流报错信息应带插件名与已用次数，实际 %q", msg)
		}
	})

	t.Run("120次每分钟上限", func(t *testing.T) {
		pluginID := "com.test.rate-min"
		idjResetRate(pluginID)
		loop := `
export default {
  async batch(arg) {
    let ok = 0, code = "";
    for (let i = 0; i < 60; i++) {
      try { await host.http.request({url: arg.base + "/echo"}); ok++; }
      catch (e) { code = e.code; break; }
    }
    return {ok: ok, code: code};
  }
};
`
		out, err := idjTestCall(t, dir, pluginID, loop, manifest, "batch", args)
		if err != nil || out["ok"] != float64(60) {
			t.Fatalf("第 1 次 batch 期望 60 次全过，实际 %v err=%v", out, err)
		}
		out, err = idjTestCall(t, dir, pluginID, loop, manifest, "batch", args)
		if err != nil || out["ok"] != float64(60) {
			t.Fatalf("第 2 次 batch 期望 60 次全过（累计 120），实际 %v err=%v", out, err)
		}
		out, err = idjTestCall(t, dir, pluginID, loop, manifest, "batch", args)
		if err != nil {
			t.Fatalf("第 3 次 batch 调用失败: %v", err)
		}
		if out["ok"] != float64(0) || out["code"] != "E_RATE_LIMIT" {
			t.Fatalf("累计 120 次后第 121 次应被 E_RATE_LIMIT 拦住，实际 %v", out)
		}
	})
}

// TestIdjIntegrity ⑧：改过一个字节的脚本拒绝加载；
// 扁平串与对象形态的 integrity 都接受；没声明的不核对。
func TestIdjIntegrity(t *testing.T) {
	dir := t.TempDir()
	script := `
export default {
  async home() { return {categories: [{id: "c1", name: "分类一"}], items: [], hasMore: false}; }
};
`
	sum := sha256.Sum256([]byte(script))
	b64 := base64.StdEncoding.EncodeToString(sum[:])
	flatManifest := map[string]interface{}{
		"id": "com.test.integrity", "name": "完整性插件", "version": "1.0.0",
		"entry": "main.js", "type": "video",
		"capabilities": []string{"home"},
		"integrity":    "sha256-" + b64,
		"permissions":  map[string]interface{}{"http": []string{}, "storage": true},
	}
	flatJSON, _ := json.Marshal(flatManifest)
	if _, err := idjTestCall(t, dir, "com.test.integrity", script, string(flatJSON), "__probe", "{}"); err != nil {
		t.Fatalf("扁平串 integrity 一致时应通过，实际失败: %v", err)
	}
	objManifest := map[string]interface{}{
		"id": "com.test.integrity", "name": "完整性插件", "version": "1.0.0",
		"entry": "main.js", "type": "video",
		"capabilities": []string{"home"},
		"integrity":    map[string]interface{}{"files": map[string]string{"main.js": "sha256-" + b64}},
		"permissions":  map[string]interface{}{"http": []string{}, "storage": true},
	}
	objJSON, _ := json.Marshal(objManifest)
	if _, err := idjTestCall(t, dir, "com.test.integrity", script, string(objJSON), "__probe", "{}"); err != nil {
		t.Fatalf("对象形态 integrity 一致时应通过，实际失败: %v", err)
	}
	tampered := strings.Replace(script, "分类一", "分类二", 1)
	if tampered == script {
		t.Fatalf("测试夹具改字节失败")
	}
	_, err := idjTestCall(t, dir, "com.test.integrity", tampered, string(flatJSON), "__probe", "{}")
	if err == nil {
		t.Fatalf("改过一个字节的脚本应拒绝加载，实际通过了")
	}
	if !strings.Contains(err.Error(), "哈希") {
		t.Fatalf("拒绝原因应写明哈希不一致，实际：%v", err)
	}
	noIntegrity := map[string]interface{}{
		"id": "com.test.integrity", "name": "完整性插件", "version": "1.0.0",
		"entry": "main.js", "type": "video",
		"capabilities": []string{"home"},
		"permissions":  map[string]interface{}{"http": []string{}, "storage": true},
	}
	noJSON, _ := json.Marshal(noIntegrity)
	if _, err := idjTestCall(t, dir, "com.test.integrity", script, string(noJSON), "__probe", "{}"); err != nil {
		t.Fatalf("没声明 integrity 时不应核对，实际失败: %v", err)
	}
}

// TestIdjVersionHasSettings：host.version / host.has / host.settings。
func TestIdjVersionHasSettings(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async info() {
    return {
      v: host.version,
      hasHttp: host.has('http'),
      hasAes: host.has('crypto.aes'),
      hasStripes: host.has('image.stripes'),
      hasNope: host.has('no.such.cap'),
      settings: host.settings
    };
  },
  async has(arg) { return {has: host.has(arg.cap)}; }
};
`
	out, err := idjTestCall(t, dir, "com.test.meta", script, manifest, "info", "{}")
	if err != nil {
		t.Fatalf("info 调用失败: %v", err)
	}
	v, _ := out["v"].(map[string]interface{})
	if v["app"] != "1.5.2" || v["spec"] != "idj1" {
		t.Fatalf("host.version 期望 {app: 1.5.2, spec: idj1}，实际 %v", out["v"])
	}
	if out["hasHttp"] != true || out["hasAes"] != true {
		t.Fatalf("已实现的 capability 应返回 true：%v", out)
	}
	if out["hasStripes"] != false || out["hasNope"] != false {
		t.Fatalf("未实现的 capability 应诚实返回 false：%v", out)
	}
	settings, _ := out["settings"].(map[string]interface{})
	if settings == nil || len(settings) != 0 {
		t.Fatalf("host.settings v1 应返回 {}，实际 %v", out["settings"])
	}
}

// TestIdjCryptoCodec：第二阶段 crypto.* / codec.*。
func TestIdjCryptoCodec(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async run(arg) {
    const o = arg;
    let r = {};
    if (o.what === 'hash') {
      r.md5 = host.crypto.md5('abc');
      r.sha1 = host.crypto.sha1('abc');
      r.sha256 = host.crypto.sha256('abc');
      r.sha512 = host.crypto.sha512('abc');
      r.hmac = host.crypto.hmac('sha256', 'key', 'The quick brown fox jumps over the lazy dog');
    }
    if (o.what === 'aes') {
      const enc = host.crypto.aes({op: 'encrypt', mode: 'cbc', key: o.key, iv: o.iv, data: o.data});
      r.enc = enc;
      r.dec = host.crypto.aes({op: 'decrypt', mode: 'cbc', key: o.key, iv: o.iv, data: enc});
      r.ctr = host.crypto.aes({op: 'decrypt', mode: 'ctr', key: o.key, iv: o.iv,
        data: host.crypto.aes({op: 'encrypt', mode: 'ctr', key: o.key, iv: o.iv, data: o.data})});
      r.gcm = host.crypto.aes({op: 'decrypt', mode: 'gcm', key: o.key, iv: '123456789012',
        data: host.crypto.aes({op: 'encrypt', mode: 'gcm', key: o.key, iv: '123456789012', data: o.data})});
    }
    if (o.what === 'codec') {
      r.b64e = host.codec.base64Encode('hello');
      r.b64d = host.codec.base64Decode('aGVsbG8=');
      r.hex = host.codec.hexEncode('hi');
      r.conv = host.codec.convert('aGVsbG8=', 'base64', 'hex');
      r.gunzip = host.codec.gunzip(o.gz);
      r.unpacked = host.codec.unpackPacker(o.packed);
    }
    if (o.what === 'rand') {
      r.hex8 = host.crypto.randomHex(8);
      r.hexDef = host.crypto.randomHex();
    }
    return r;
  }
};
`
	t.Run("哈希与HMAC", func(t *testing.T) {
		out, err := idjTestCall(t, dir, "com.test.crypto", script, manifest, "run", `{"what": "hash"}`)
		if err != nil {
			t.Fatalf("哈希调用失败: %v", err)
		}
		want := map[string]string{
			"md5":    "900150983cd24fb0d6963f7d28e17f72",
			"sha1":   "a9993e364706816aba3e25717850c26c9cd0d89d",
			"sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			"sha512": "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
			"hmac":   "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
		}
		for k, v := range want {
			if out[k] != v {
				t.Fatalf("%s 期望 %s，实际 %v", k, v, out[k])
			}
		}
	})

	t.Run("AES与标准库对照", func(t *testing.T) {
		key := "0123456789abcdef"
		iv := "abcdef0123456789"
		plain := "hello world, hello!"
		// 标准库算一遍期望密文（CBC + PKCS7），与宿主实现对照。
		block, err := aes.NewCipher([]byte(key))
		if err != nil {
			t.Fatalf("建 AES 失败: %v", err)
		}
		padded := pkcs7Pad([]byte(plain), aes.BlockSize)
		want := make([]byte, len(padded))
		cipher.NewCBCEncrypter(block, []byte(iv)).CryptBlocks(want, padded)
		wantB64 := base64.StdEncoding.EncodeToString(want)
		args, _ := json.Marshal(map[string]string{"what": "aes", "key": key, "iv": iv, "data": plain})
		out, err := idjTestCall(t, dir, "com.test.crypto", script, manifest, "run", string(args))
		if err != nil {
			t.Fatalf("AES 调用失败: %v", err)
		}
		if out["enc"] != wantB64 {
			t.Fatalf("AES-CBC 密文与标准库不一致：期望 %s，实际 %v", wantB64, out["enc"])
		}
		if out["dec"] != plain || out["ctr"] != plain || out["gcm"] != plain {
			t.Fatalf("AES 解密/CTR/GCM 回合失败：%v", out)
		}
	})

	t.Run("编解码与解包", func(t *testing.T) {
		var gzBuf bytes.Buffer
		gz := gzip.NewWriter(&gzBuf)
		_, _ = gz.Write([]byte("hello world"))
		_ = gz.Close()
		packed := `eval(function(p,a,c,k,e,d){e=function(c){return c};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}('0 2 1',3,3,'x|y|z'.split('|')))`
		args, _ := json.Marshal(map[string]string{
			"what": "codec", "gz": base64.StdEncoding.EncodeToString(gzBuf.Bytes()), "packed": packed,
		})
		out, err := idjTestCall(t, dir, "com.test.crypto", script, manifest, "run", string(args))
		if err != nil {
			t.Fatalf("codec 调用失败: %v", err)
		}
		if out["b64e"] != "aGVsbG8=" || out["b64d"] != "hello" || out["hex"] != "6869" || out["conv"] != "68656c6c6f" {
			t.Fatalf("base64/hex/convert 不对：%v", out)
		}
		if out["gunzip"] != "hello world" {
			t.Fatalf("gunzip 期望 hello world，实际 %v", out["gunzip"])
		}
		if out["unpacked"] != "x z y" {
			t.Fatalf("unpackPacker 期望 'x z y'，实际 %v", out["unpacked"])
		}
	})

	t.Run("随机数", func(t *testing.T) {
		out, err := idjTestCall(t, dir, "com.test.crypto", script, manifest, "run", `{"what": "rand"}`)
		if err != nil {
			t.Fatalf("randomHex 调用失败: %v", err)
		}
		hex8, _ := out["hex8"].(string)
		hexDef, _ := out["hexDef"].(string)
		if len(hex8) != 16 || len(hexDef) != 32 {
			t.Fatalf("randomHex 长度不对：8字节=%q 默认=%q", hex8, hexDef)
		}
	})

	t.Run("RSA加密验签", func(t *testing.T) {
		priv, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatalf("生成 RSA 密钥失败: %v", err)
		}
		der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
		if err != nil {
			t.Fatalf("编码公钥失败: %v", err)
		}
		pemText := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
		rsaScript := `
export default {
  async run(arg) {
    if (arg.what === 'enc') {
      return {enc: host.crypto.rsa({op: 'encrypt', publicKeyPem: arg.pem, data: arg.data})};
    }
    return {ok: host.crypto.rsa({op: 'verify', publicKeyPem: arg.pem, data: arg.data, signature: arg.sig, hash: 'sha256'})};
  }
};
`
		args, _ := json.Marshal(map[string]string{"what": "enc", "pem": pemText, "data": "hello rsa"})
		out, err := idjTestCall(t, dir, "com.test.crypto", rsaScript, manifest, "run", string(args))
		if err != nil {
			t.Fatalf("RSA 加密调用失败: %v", err)
		}
		encB64, _ := out["enc"].(string)
		encBytes, err := base64.StdEncoding.DecodeString(encB64)
		if err != nil {
			t.Fatalf("RSA 密文不是合法 base64: %v", err)
		}
		plain, err := rsa.DecryptPKCS1v15(rand.Reader, priv, encBytes)
		if err != nil || string(plain) != "hello rsa" {
			t.Fatalf("RSA 密文用私钥解不开：%v %v", plain, err)
		}
		digest := sha256.Sum256([]byte("hello rsa"))
		sig, err := rsa.SignPKCS1v15(rand.Reader, priv, 5, digest[:])
		if err != nil {
			t.Fatalf("签名失败: %v", err)
		}
		args, _ = json.Marshal(map[string]string{
			"what": "verify", "pem": pemText, "data": "hello rsa",
			"sig": base64.StdEncoding.EncodeToString(sig),
		})
		out, err = idjTestCall(t, dir, "com.test.crypto", rsaScript, manifest, "run", string(args))
		if err != nil {
			t.Fatalf("RSA 验签调用失败: %v", err)
		}
		if out["ok"] != true {
			t.Fatalf("真签名验签期望 true，实际 %v", out)
		}
		sig[0] ^= 0xff
		args, _ = json.Marshal(map[string]string{
			"what": "verify", "pem": pemText, "data": "hello rsa",
			"sig": base64.StdEncoding.EncodeToString(sig),
		})
		out, err = idjTestCall(t, dir, "com.test.crypto", rsaScript, manifest, "run", string(args))
		if err != nil {
			t.Fatalf("RSA 验签调用失败: %v", err)
		}
		if out["ok"] != false {
			t.Fatalf("假签名验签期望 false，实际 %v", out)
		}
	})
}

// TestIdjHTMLM3U8URL：第二阶段 html.parse / m3u8.parse / url.*。
func TestIdjHTMLM3U8URL(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async run(arg) {
    let r = {};
    if (arg.what === 'html') {
      const doc = host.html.parse('<div class="wrap"><p id="t">你好</p><a href="/x">链</a></div>');
      const ps = doc.select('p');
      r.pText = ps.length ? ps[0].text() : '';
      r.pId = doc.selectFirst('#t').attr('id');
      r.aHref = doc.selectFirst('a').attr('href');
      r.nth = doc.select('p:nth-child(1)').length;
      r.comma = doc.select('p, a').length;
      r.child = doc.select('div > p').length;
    }
    if (arg.what === 'm3u8') {
      r.master = host.m3u8.parse('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,NAME="360P"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\nmid.m3u8\n', 'https://cdn.example.com/v/');
      r.media = host.m3u8.parse('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1234\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:8.5,\nseg2.ts\n', 'https://cdn.example.com/v/');
    }
    if (arg.what === 'url') {
      r.resolved = host.url.resolve('https://a.com/x/y', '../z');
      r.form = host.url.encodeForm({a: '1', b: 'x y'});
    }
    return r;
  }
};
`
	out, err := idjTestCall(t, dir, "com.test.parse", script, manifest, "run", `{"what": "html"}`)
	if err != nil {
		t.Fatalf("html.parse 调用失败: %v", err)
	}
	if out["pText"] != "你好" || out["pId"] != "t" || out["aHref"] != "/x" {
		t.Fatalf("html.parse 结果不对：%v", out)
	}
	if out["comma"] != float64(2) || out["child"] != float64(1) {
		t.Fatalf("逗号分组/子代选择器不对：%v", out)
	}
	if out["nth"] != float64(0) {
		t.Fatalf("不支持的 :nth-child 应返回空结果，实际 %v", out)
	}

	out, err = idjTestCall(t, dir, "com.test.parse", script, manifest, "run", `{"what": "m3u8"}`)
	if err != nil {
		t.Fatalf("m3u8.parse 调用失败: %v", err)
	}
	master, _ := out["master"].(map[string]interface{})
	variants, _ := master["variants"].([]interface{})
	if len(variants) != 2 {
		t.Fatalf("master 期望 2 个 variant，实际 %v", master)
	}
	v0, _ := variants[0].(map[string]interface{})
	if v0["url"] != "https://cdn.example.com/v/low.m3u8" || v0["bandwidth"] != float64(800000) ||
		v0["resolution"] != "640x360" || v0["name"] != "360P" {
		t.Fatalf("variant 0 不对：%v", v0)
	}
	media, _ := out["media"].(map[string]interface{})
	segments, _ := media["segments"].([]interface{})
	if len(segments) != 2 {
		t.Fatalf("media 期望 2 个 segment，实际 %v", media)
	}
	s0, _ := segments[0].(map[string]interface{})
	if s0["url"] != "https://cdn.example.com/v/seg1.ts" || s0["duration"] != float64(10) {
		t.Fatalf("segment 0 不对：%v", s0)
	}
	key, _ := media["key"].(map[string]interface{})
	if key["method"] != "AES-128" || key["uri"] != "https://cdn.example.com/v/key.bin" || key["iv"] != "0x1234" {
		t.Fatalf("#EXT-X-KEY 没解析对：%v", key)
	}

	out, err = idjTestCall(t, dir, "com.test.parse", script, manifest, "run", `{"what": "url"}`)
	if err != nil {
		t.Fatalf("url 调用失败: %v", err)
	}
	if out["resolved"] != "https://a.com/z" {
		t.Fatalf("url.resolve 期望 https://a.com/z，实际 %v", out["resolved"])
	}
	if out["form"] != "a=1&b=x+y" {
		t.Fatalf("url.encodeForm 期望 a=1&b=x+y，实际 %v", out["form"])
	}
}

// TestIdjCallTimeout：调用预算超时即废弃 runtime，抛 E_TIMEOUT。
func TestIdjCallTimeout(t *testing.T) {
	idjEnableLoopback(t)
	old := idjCallTimeout
	idjCallTimeout = 300 * time.Millisecond
	t.Cleanup(func() { idjCallTimeout = old })
	dir := t.TempDir()
	manifest := idjTestManifest(t, "127.0.0.1")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Second)
		_, _ = w.Write([]byte("slow-ok"))
	}))
	defer server.Close()
	script := `
export default {
  async req(arg) {
    const r = await host.http.request({url: arg.base + "/slow", timeout: 20000});
    return {status: r.status};
  }
};
`
	_, err := idjTestCall(t, dir, "com.test.timeout", script, manifest, "req", `{"base": "`+server.URL+`"}`)
	idjAssertCode(t, err, "E_TIMEOUT")
}

// TestIdjPlayCallTimeout：播放（player）走单独的 idjPlayTimeout 预算，
// 不受普通调用 idjCallTimeout 约束；普通函数仍受普通预算约束。
func TestIdjPlayCallTimeout(t *testing.T) {
	idjEnableLoopback(t)
	oldCall, oldPlay := idjCallTimeout, idjPlayTimeout
	idjCallTimeout = 300 * time.Millisecond
	idjPlayTimeout = 5 * time.Second
	t.Cleanup(func() { idjCallTimeout, idjPlayTimeout = oldCall, oldPlay })
	dir := t.TempDir()
	manifest := idjTestManifest(t, "127.0.0.1")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(800 * time.Millisecond)
		_, _ = w.Write([]byte("slow-ok"))
	}))
	defer server.Close()
	script := `
export default {
  async play(arg) {
    const r = await host.http.request({url: arg.base + "/slow", timeout: 20000});
    return {streams: [{url: "https://a.com/x.m3u8", format: "hls"}]};
  },
  async home(arg) {
    const r = await host.http.request({url: arg.base + "/slow", timeout: 20000});
    return {categories: [], items: [], hasMore: false};
  }
};
`
	args := `{"base": "` + server.URL + `", "playId": "ep1", "flag": ""}`
	// 播放：800ms 慢请求在普通预算（300ms）下必超时，播放预算（5s）下成功。
	out, err := idjTestCall(t, dir, "com.test.playtimeout", script, manifest, "player", args)
	if err != nil {
		t.Fatalf("player 调用失败: %v", err)
	}
	if out == nil {
		t.Fatalf("player 调用无结果")
	}
	// 普通函数：同样的慢请求仍被普通预算掐掉。
	_, err = idjTestCall(t, dir, "com.test.playtimeout", script, manifest, "home", args)
	idjAssertCode(t, err, "E_TIMEOUT")
}

// TestIdjHas：__has 探查函数是否存在。
func TestIdjHas(t *testing.T) {
	dir := t.TempDir()
	manifest := idjTestManifest(t)
	script := `
export default {
  async home() { return {categories: [], items: [], hasMore: false}; }
};
`
	out, err := idjTestCall(t, dir, "com.test.has", script, manifest, "__has", `{"fn": "home"}`)
	if err != nil {
		t.Fatalf("__has 调用失败: %v", err)
	}
	if out["has"] != true {
		t.Fatalf("__has home 期望 true，实际 %v", out)
	}
	out, err = idjTestCall(t, dir, "com.test.has", script, manifest, "__has", `{"fn": "play"}`)
	if err != nil {
		t.Fatalf("__has 调用失败: %v", err)
	}
	if out["has"] != false {
		t.Fatalf("__has play 期望 false，实际 %v", out)
	}
}

// TestIdjDispatch：nativeDispatch 的 "idjCall" action 接线。
func TestIdjDispatch(t *testing.T) {
	idjEnableLoopback(t)
	dir := t.TempDir()
	nativeState.Lock()
	oldEngine := nativeState.engine
	nativeState.engine = &nativeEngine{directory: dir}
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = oldEngine
		nativeState.Unlock()
	})
	script := `
export default {
  async home() { return {categories: [{id: "c1", name: "分类一"}], items: [], hasMore: false}; }
};
`
	manifest := idjTestManifest(t, "127.0.0.1")
	input := map[string]interface{}{
		"action":   "idjCall",
		"pluginId": "com.test.dispatch",
		"content":  script,
		"manifest": manifest,
		"fn":       "home",
		"args":     "{}",
	}
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatalf("拼请求失败: %v", err)
	}
	respText := NativeRequest(string(raw))
	var envelope struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		Data  struct {
			Result map[string]interface{} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(respText), &envelope); err != nil {
		t.Fatalf("解析 NativeRequest 信封失败: %v (%s)", err, respText)
	}
	if !envelope.OK {
		t.Fatalf("idjCall action 应成功，实际 error=%s", envelope.Error)
	}
	cats, _ := envelope.Data.Result["categories"].([]interface{})
	if len(cats) != 1 {
		t.Fatalf("dispatch 回来的 categories 期望 1 个，实际 %v", envelope.Data.Result)
	}
}
