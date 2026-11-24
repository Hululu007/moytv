package core

// iDuanJu P0 探针：验证本树 goja 版本能不能跑 async/await + Promise。
// 背景：4 个 .idjplugin 的入口全是 async 函数，host.http.request 也须返回
// Promise；goja 本身没有内置事件循环，探针要先定下来 Promise 怎么结算。
// 本文件只做探针，不改任何现有文件；结论见
// ~/workspace/idjplugin_adapt_20261124/probe_report.md。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dop251/goja"
)

// idjProbeHost 装一个最小 host 桩：http.request 返回 Promise，
// storage 同步读写内存 map，error 返回带 code 的 Error。
type idjProbeHost struct {
	rt          *goja.Runtime
	requests    []string
	resolveMode string // "sync"：回调内立即 resolve；"deferred"：回调返回 pending Promise，由外部 resolve
	pending     map[*goja.Promise]func(interface{}) error
	store       map[string]string
}

func newIdjProbeHost(rt *goja.Runtime, mode string) *idjProbeHost {
	h := &idjProbeHost{rt: rt, resolveMode: mode, pending: map[*goja.Promise]func(interface{}) error{}, store: map[string]string{}}
	httpObj := rt.NewObject()
	_ = httpObj.Set("request", func(call goja.FunctionCall) goja.Value {
		url := ""
		if len(call.Arguments) > 0 {
			if arg := call.Arguments[0].ToObject(rt); arg != nil {
				url = jsValueString(arg.Get("url"))
			}
		}
		h.requests = append(h.requests, url)
		resp := rt.NewObject()
		_ = resp.Set("status", 200)
		_ = resp.Set("url", url)
		_ = resp.Set("body", `{"ok":true}`)
		items := rt.NewArray()
		item := rt.NewObject()
		_ = item.Set("id", "1")
		_ = item.Set("title", "片A")
		_ = items.Set("0", item)
		_ = resp.Set("items", items)
		promise, resolve, _ := rt.NewPromise()
		switch h.resolveMode {
		case "sync":
			// 回调内同步 resolve：发请求（此处用假数据代替真 HTTP）
			// 完成后立即结算，Promise 反应任务由 goja 在顶层返回时排空。
			_ = resolve(resp)
		default:
			h.pending[promise] = resolve
		}
		// *Promise 本身不是 goja.Value，要经 rt.ToValue 转成 JS 可见的
		// Promise 值（goja 自身测试同款写法）。
		return rt.ToValue(promise)
	})
	hostObj := rt.NewObject()
	_ = hostObj.Set("http", httpObj)
	_ = hostObj.Set("error", func(call goja.FunctionCall) goja.Value {
		code, msg := "", ""
		if len(call.Arguments) > 0 {
			code = jsValueString(call.Arguments[0])
		}
		if len(call.Arguments) > 1 {
			msg = jsValueString(call.Arguments[1])
		}
		errObj := rt.NewObject()
		_ = errObj.Set("code", code)
		_ = errObj.Set("message", msg)
		return errObj
	})
	storageObj := rt.NewObject()
	_ = storageObj.Set("get", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 {
			return goja.Undefined()
		}
		if v, ok := h.store[jsValueString(call.Arguments[0])]; ok {
			return rt.ToValue(v)
		}
		return goja.Undefined()
	})
	_ = storageObj.Set("set", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) >= 2 {
			h.store[jsValueString(call.Arguments[0])] = jsValueString(call.Arguments[1])
		}
		return goja.Undefined()
	})
	_ = hostObj.Set("storage", storageObj)
	_ = hostObj.Set("version", map[string]interface{}{"app": "probe", "spec": "idj1"})
	rt.Set("host", hostObj)
	return h
}

// idjProbeLoad 按兼容层路线加载一段 export default 插件脚本：
// jsStripModuleSyntax 转 ESM -> 运行 -> 在 module.exports 里找函数。
func idjProbeLoad(t *testing.T, rt *goja.Runtime, script string) {
	t.Helper()
	script = jsStripModuleSyntax(script).script
	if _, err := rt.RunString(script); err != nil {
		t.Fatalf("加载插件脚本失败: %v", err)
	}
}

// idjProbePromise 从 async 函数返回值里取出 *goja.Promise。
func idjProbePromise(t *testing.T, v goja.Value) *goja.Promise {
	t.Helper()
	if v == nil || goja.IsUndefined(v) {
		t.Fatalf("async 函数返回了 undefined，不是 Promise")
	}
	p, ok := v.Export().(*goja.Promise)
	if !ok {
		t.Fatalf("async 函数返回值不是 Promise，实际类型 %T（值 %v）", v.Export(), v.Export())
	}
	return p
}

// idjProbePump 泵一次 goja 的 Promise 任务队列：一次空的顶层 RunString
// 返回时 goja 的 leave() 会把已排队的 Promise 反应任务全部跑完。
func idjProbePump(t *testing.T, rt *goja.Runtime) {
	t.Helper()
	if _, err := rt.RunString("0;"); err != nil {
		t.Fatalf("泵 job 队列失败: %v", err)
	}
}

const idjProbePluginScript = `
export default {
  async home() {
    const r = await host.http.request({url: "https://example.invalid/api", method: "GET"});
    return {categories: [{id: "line:1", name: "线路一"}, {id: "tag:a", name: "标签A"}], items: r.items, hasMore: false};
  },
  async category(arg) {
    const r = await host.http.request({url: "https://example.invalid/cat"});
    return {items: r.items, hasMore: true, page: arg.page};
  },
  async play(arg) {
    const r = await host.http.request({url: "https://example.invalid/play"});
    return {streams: [{url: "https://example.invalid/1.m3u8", format: "hls"}], id: arg.id};
  }
};
`

// TestIdjProbeAsyncAwaitSyncResolve：最小 async 插件形态。
// host.http.request 在 Go 回调内同步 resolve（发真 HTTP 时同理：回调内
// 同步做完请求再 resolve，不另起事件循环）。
func TestIdjProbeAsyncAwaitSyncResolve(t *testing.T) {
	rt := goja.New()
	host := newIdjProbeHost(rt, "sync")
	// module/exports 预定义（照 app_js_spider.go runtime() 的做法）。
	moduleObj := rt.NewObject()
	exportsObj := rt.NewObject()
	_ = moduleObj.Set("exports", exportsObj)
	rt.Set("module", moduleObj)
	rt.Set("exports", exportsObj)

	idjProbeLoad(t, rt, idjProbePluginScript)
	home, found := jsFindFunction(rt, "home")
	if !found {
		t.Fatalf("export default 对象里找不到 home")
	}
	out, err := home(goja.Undefined(), rt.ToValue(map[string]interface{}{}))
	if err != nil {
		t.Fatalf("调用 home() 失败: %v", err)
	}
	p := idjProbePromise(t, out)
	t.Logf("调用 home() 刚返回时 Promise 状态: %v（0=pending 1=fulfilled 2=rejected）", p.State())
	// 同步 resolve 的 Promise：goja 在顶层调用返回时已排空反应任务，
	// async 函数应已结算。
	if p.State() != goja.PromiseStateFulfilled {
		idjProbePump(t, rt)
		t.Logf("泵一次后 Promise 状态: %v", p.State())
	}
	if p.State() != goja.PromiseStateFulfilled {
		t.Fatalf("home() 返回的 Promise 未结算，状态 %v", p.State())
	}
	decoded, err := jsExportValue(rt, p.Result())
	if err != nil {
		t.Fatalf("导出 home() 结果失败: %v", err)
	}
	m, ok := decoded.(map[string]interface{})
	if !ok {
		t.Fatalf("home() 结果不是对象：%T %v", decoded, decoded)
	}
	cats, _ := m["categories"].([]interface{})
	if len(cats) != 2 {
		t.Fatalf("categories 期望 2 个，实际 %v", m["categories"])
	}
	items, _ := m["items"].([]interface{})
	if len(items) != 1 {
		t.Fatalf("items 期望 1 个，实际 %v", m["items"])
	}
	if len(host.requests) != 1 || host.requests[0] != "https://example.invalid/api" {
		t.Fatalf("host.http.request 调用记录不对：%v", host.requests)
	}
	t.Logf("home() 结果 categories=%d items=%d，已过", len(cats), len(items))

	// 再测带参的 async category({id, page})。
	category, found := jsFindFunction(rt, "category")
	if !found {
		t.Fatalf("export default 对象里找不到 category")
	}
	out, err = category(goja.Undefined(), rt.ToValue(map[string]interface{}{"id": "line:1", "page": 2}))
	if err != nil {
		t.Fatalf("调用 category() 失败: %v", err)
	}
	p = idjProbePromise(t, out)
	if p.State() != goja.PromiseStateFulfilled {
		idjProbePump(t, rt)
	}
	if p.State() != goja.PromiseStateFulfilled {
		t.Fatalf("category() 返回的 Promise 未结算，状态 %v", p.State())
	}
	decoded, err = jsExportValue(rt, p.Result())
	if err != nil {
		t.Fatalf("导出 category() 结果失败: %v", err)
	}
	m, _ = decoded.(map[string]interface{})
	if m["hasMore"] != true {
		t.Fatalf("category() hasMore 期望 true，实际 %v", m["hasMore"])
	}
	t.Logf("category({id:line:1, page:2}) 结果 hasMore=%v，已过", m["hasMore"])
}

// TestIdjProbeAsyncAwaitDeferredResolve：host.http.request 返回时先不结算，
// 由另一个 goroutine（模拟真 HTTP）算出结果后，主 goroutine 在 runtime
// 所在 goroutine 上调 resolve，再泵一次空 RunString 排空反应任务。
// 这是“不用事件循环 goroutine、只靠 resolve + 泵”的最小可用机制。
func TestIdjProbeAsyncAwaitDeferredResolve(t *testing.T) {
	rt := goja.New()
	host := newIdjProbeHost(rt, "deferred")
	moduleObj := rt.NewObject()
	exportsObj := rt.NewObject()
	_ = moduleObj.Set("exports", exportsObj)
	rt.Set("module", moduleObj)
	rt.Set("exports", exportsObj)

	idjProbeLoad(t, rt, idjProbePluginScript)
	home, found := jsFindFunction(rt, "home")
	if !found {
		t.Fatalf("export default 对象里找不到 home")
	}
	// 模拟异步 HTTP：另一个 goroutine 50ms 后把“完成”信号送到 channel；
	// 它绝不碰 rt（goja Runtime 不是 goroutine 安全的），只发一个字符串。
	done := make(chan string, 1)
	go func() {
		time.Sleep(50 * time.Millisecond)
		done <- "async-http-done"
	}()
	out, err := home(goja.Undefined(), rt.ToValue(map[string]interface{}{}))
	if err != nil {
		t.Fatalf("调用 home() 失败: %v", err)
	}
	p := idjProbePromise(t, out)
	if p.State() != goja.PromiseStatePending {
		t.Fatalf("deferred 模式下 home() 刚返回时期望 pending，实际 %v", p.State())
	}
	if len(host.pending) != 1 {
		t.Fatalf("期望 1 个待结算 Promise，实际 %d 个", len(host.pending))
	}
	t.Logf("deferred：home() 返回后 Promise 为 pending，待外部 resolve，已过")

	// 等异步结果（5 秒硬上限，防测试挂死），再在 runtime 所在 goroutine 上结算。
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatalf("等异步 HTTP 超时 5 秒")
	}
	for promise, resolve := range host.pending {
		resp := rt.NewObject()
		_ = resp.Set("status", 200)
		_ = resp.Set("url", "https://example.invalid/api")
		_ = resp.Set("body", `{"ok":true}`)
		items := rt.NewArray()
		item := rt.NewObject()
		_ = item.Set("id", "1")
		_ = item.Set("title", "片A")
		_ = items.Set("0", item)
		_ = resp.Set("items", items)
		if err := resolve(resp); err != nil {
			t.Fatalf("resolve 失败: %v", err)
		}
		_ = promise
	}
	t.Logf("resolve() 刚调完时 Promise 状态: %v", p.State())
	if p.State() != goja.PromiseStateFulfilled {
		// resolve 只把反应任务排进队列，跑完它们要一次顶层返回。
		idjProbePump(t, rt)
		t.Logf("泵一次后 Promise 状态: %v", p.State())
	}
	if p.State() != goja.PromiseStateFulfilled {
		t.Fatalf("resolve + 泵一次后 Promise 仍未结算，状态 %v", p.State())
	}
	decoded, err := jsExportValue(rt, p.Result())
	if err != nil {
		t.Fatalf("导出 home() 结果失败: %v", err)
	}
	m, _ := decoded.(map[string]interface{})
	cats, _ := m["categories"].([]interface{})
	if len(cats) != 2 {
		t.Fatalf("categories 期望 2 个，实际 %v", m["categories"])
	}
	t.Logf("deferred resolve + 泵一次后 home() 已结算，categories=%d，已过", len(cats))
}

// TestIdjProbeSetTimeoutLoop：手写最小 setTimeout + 驱动循环。
// 证明“没有内置事件循环”也能跑定时器驱动的 Promise：Go 侧记下回调与
// 到期时间，主 goroutine 轮询、到时在 runtime 所在 goroutine 上调回调，
// 再泵一次排空反应任务。
func TestIdjProbeSetTimeoutLoop(t *testing.T) {
	rt := goja.New()
	type timer struct {
		deadline time.Time
		fn       goja.Callable
	}
	var timers []timer
	rt.Set("setTimeout", func(call goja.FunctionCall) goja.Value {
		fn, ok := goja.AssertFunction(call.Arguments[0])
		if !ok {
			return goja.Undefined()
		}
		ms := int64(0)
		if len(call.Arguments) > 1 {
			ms = call.Arguments[1].ToInteger()
		}
		timers = append(timers, timer{deadline: time.Now().Add(time.Duration(ms) * time.Millisecond), fn: fn})
		return goja.Undefined()
	})
	script := `
var __probeV = null;
(async function() {
  const v = await new Promise(function(res) { setTimeout(function() { res(42); }, 20); });
  __probeV = v;
})();
`
	if _, err := rt.RunString(script); err != nil {
		t.Fatalf("运行 setTimeout 脚本失败: %v", err)
	}
	// 驱动循环：5 秒硬上限；每次到时调回调 + 泵一次。
	deadline := time.Now().Add(5 * time.Second)
	for {
		if v := rt.Get("__probeV"); v != nil && !goja.IsNull(v) && !goja.IsUndefined(v) {
			if v.ToInteger() == 42 {
				t.Logf("setTimeout 驱动循环跑通，await 到 42，已过")
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("__probeV 5 秒内仍不是 42，当前值 %v", rt.Get("__probeV"))
		}
		now := time.Now()
		remaining := timers[:0]
		for _, tm := range timers {
			if now.After(tm.deadline) || now.Equal(tm.deadline) {
				if _, err := tm.fn(goja.Undefined()); err != nil {
					t.Fatalf("调 setTimeout 回调失败: %v", err)
				}
				idjProbePump(t, rt)
			} else {
				remaining = append(remaining, tm)
			}
		}
		timers = remaining
		time.Sleep(2 * time.Millisecond)
	}
}

// TestIdjProbeSyntaxBoundary：R6 语法边界。每个用例都是全新 runtime，
// 记录通过/报错原文。
func TestIdjProbeSyntaxBoundary(t *testing.T) {
	cases := []struct {
		name   string
		script string
		check  func(t *testing.T, rt *goja.Runtime, v goja.Value)
	}{
		{
			name:   "可选链 ?.",
			script: `var o = {a: {b: 7}}; var r1 = o?.a?.b; var r2 = o?.x?.y; r1;`,
			check: func(t *testing.T, rt *goja.Runtime, v goja.Value) {
				if v.ToInteger() != 7 {
					t.Fatalf("期望 7，实际 %v", v)
				}
				if r2 := rt.Get("r2"); !goja.IsUndefined(r2) {
					t.Fatalf("o?.x?.y 期望 undefined，实际 %v", r2)
				}
			},
		},
		{
			name:   "对象展开 {...o}",
			script: `var o = {a: 1}; var p = {...o, b: 2}; p.a + p.b;`,
			check: func(t *testing.T, rt *goja.Runtime, v goja.Value) {
				if v.ToInteger() != 3 {
					t.Fatalf("期望 3，实际 %v", v)
				}
			},
		},
		{
			name:   "Promise.all",
			script: `var r = null; (async function() { r = await Promise.all([Promise.resolve(1), Promise.resolve(2)]); })(); 0;`,
			check: func(t *testing.T, rt *goja.Runtime, v goja.Value) {
				got := rt.Get("r")
				if got == nil || goja.IsNull(got) || goja.IsUndefined(got) {
					t.Fatalf("Promise.all 结算后 r 仍为空：%v", got)
				}
				exported := got.Export()
				list, ok := exported.([]interface{})
				if !ok || len(list) != 2 {
					t.Fatalf("期望 [1 2]，实际 %T %v", exported, exported)
				}
			},
		},
		{
			name:   "模板字符串",
			script: "var n = 1 + 1; `a${n}b`;",
			check: func(t *testing.T, rt *goja.Runtime, v goja.Value) {
				if v.String() != "a2b" {
					t.Fatalf("期望 a2b，实际 %v", v)
				}
			},
		},
		{
			name:   "async 箭头函数",
			script: `var r = null; var f = async (x) => x + 1; (async function() { r = await f(41); })(); 0;`,
			check: func(t *testing.T, rt *goja.Runtime, v goja.Value) {
				if got := rt.Get("r"); got == nil || got.ToInteger() != 42 {
					t.Fatalf("期望 42，实际 %v", got)
				}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rt := goja.New()
			v, err := rt.RunString(tc.script)
			if err != nil {
				t.Fatalf("语法/运行失败: %v", err)
			}
			tc.check(t, rt, v)
			t.Logf("%s：通过", tc.name)
		})
	}
}

// TestIdjProbeRealPluginLoad：R6 补充——4 个 main.js 原文件能不能被
// jsStripModuleSyntax 加载、5 个入口函数能不能找到、home() 的 async 链
// 能不能跑通（host 全假桩，不联网）。
//
// 实测结论（2026-11-24）：只用 jsStripModuleSyntax 时 4 个里只有橙果能
// 加载，潮流/爱果/2048 全在第 2 行报
// "SyntaxError: (anonymous): Line 2:1 Unexpected reserved word"，
// 根因是 jsStripModuleSyntax 不识别正则字面量（详见 probe_report.md §4）。
// 本测试先记下“是否需要兜底”，再对需要兜底的做行级改写（顶层
// "export default X;" 行 -> "module.exports = X;"，混淆器把它放在独立行，
// 改写是安全的），验证“有条件能跑”的那个条件本身成立：
// 改写后 4 个全能加载、5 个函数全找到、home() 的 Promise 都有结算。
// 假数据下 home() 被拒绝是预期的（桩返回的不是真站数据），
// 结算本身（fulfilled 或 rejected）就是 async 链跑通的证据。
// 兜底改写只是探针内的验证手段，正式兼容层修 loader 时再落到
// app_js_idj.go 里，届时本测试应改回“无兜底直接加载”的严格断言。
func TestIdjProbeRealPluginLoad(t *testing.T) {
	plugins := []struct{ file, id string }{
		{"chengguo_9_rs5v.idjplugin", "com.idj.ext.chengguo"},
		{"chaoliu_10_lued.idjplugin", "com.idj.ext.chaoliu"},
		{"aiguo_11_e1mf.idjplugin", "com.idj.ext.aiguo"},
		{"ai2048_12_k7ld.idjplugin", "com.idj.ext.ai2048"},
	}
	needFallback := 0
	for _, p := range plugins {
		t.Run(p.id, func(t *testing.T) {
			path := filepath.Join("..", "..", "..", "idjplugin_adapt_20261124", "plugins", p.file)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Skipf("插件文件不在 %s，跳过：%v", path, err)
			}
			var bundle struct {
				Files map[string]string `json:"files"`
			}
			if err := json.Unmarshal(raw, &bundle); err != nil {
				t.Fatalf("解析 .idjplugin 失败: %v", err)
			}
			script, ok := bundle.Files["main.js"]
			if !ok {
				t.Fatalf("bundle 里没有 main.js")
			}
			stripped := jsStripModuleSyntax(script)
			patched := stripped.script
			if !stripped.hadDefault {
				needFallback++
				t.Logf("注意：jsStripModuleSyntax 未转换 export default（hadExport=%v，见 probe_report.md §4），改用行级兜底改写", stripped.hadExport)
				lines := strings.Split(patched, "\n")
				fixed := 0
				for i, ln := range lines {
					trimmed := strings.TrimSpace(ln)
					if strings.HasPrefix(trimmed, "export default ") || strings.HasPrefix(trimmed, "export default\t") {
						lines[i] = "module.exports =" + trimmed[len("export default"):]
						fixed++
					}
				}
				if fixed == 0 {
					t.Fatalf("兜底改写没找到 export default 行")
				}
				patched = strings.Join(lines, "\n")
			}
			rt := goja.New()
			_ = newIdjProbeHost(rt, "sync")
			moduleObj := rt.NewObject()
			exportsObj := rt.NewObject()
			_ = moduleObj.Set("exports", exportsObj)
			rt.Set("module", moduleObj)
			rt.Set("exports", exportsObj)
			if _, err := rt.RunString(patched); err != nil {
				msg := err.Error()
				if len(msg) > 500 {
					msg = msg[:500] + "…（已截断）"
				}
				t.Fatalf("加载 main.js 失败: %s", msg)
			}
			for _, fn := range []string{"home", "category", "search", "detail", "play"} {
				if _, found := jsFindFunction(rt, fn); !found {
					t.Fatalf("export default 里找不到 %s", fn)
				}
			}
			t.Logf("%s：加载通过，5 个入口函数均找到", p.id)
			// 跑 home()：只断言 Promise 有结算（fulfilled 或 rejected），
			// 不断言业务结果（桩返回的是假数据）。
			home, _ := jsFindFunction(rt, "home")
			out, err := home(goja.Undefined(), rt.ToValue(map[string]interface{}{}))
			if err != nil {
				t.Fatalf("调用 home() 返回 Go 错误: %v", err)
			}
			pr := idjProbePromise(t, out)
			if pr.State() == goja.PromiseStatePending {
				t.Fatalf("home() 的 Promise 在同步桩下仍是 pending，未结算")
			}
			if pr.State() == goja.PromiseStateRejected {
				if decoded, err := jsExportValue(rt, pr.Result()); err == nil {
					t.Logf("home() 被拒绝（假数据下预期），原因: %v", decoded)
				} else {
					t.Logf("home() 被拒绝（假数据下预期），原因: %v", pr.Result())
				}
			} else {
				t.Logf("home() 结算成功")
			}
		})
	}
	t.Logf("真插件加载汇总：4 个中 %d 个需要兜底改写才能加载（橙果不需要）", needFallback)
}
