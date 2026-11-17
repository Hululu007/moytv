package com.github.catvod.crawler;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * HTML 取页请求：py 核心与 Java 核心共用同一份语义（见 DESIGN.md §1）。
 * 字段全部公开，调用方按需填写，未填的按默认值走。
 */
public class HtmlRequest {
    /** 目标地址（必填，必须是 http/https）。 */
    public String url;
    /** 附加请求头（发给 loadUrl；Referer 也可放这里，[referer] 优先）。 */
    public Map<String, String> headers;
    /** Referer 请求头（优先于 headers 里的 Referer）。 */
    public String referer;
    /** 自定义 UA；空则用 WebView 默认 UA。 */
    public String userAgent;
    /** 预置 Cookie（`k=v; k2=v2` 形，加载前写进 CookieManager）。 */
    public String cookies;
    /** 等页 JS 谓词表达式：求值为真即认为页面就绪（如 `!!document.querySelector('.play')`）。 */
    public String waitJs;
    /** 等页 CSS 选择器：命中即认为页面就绪。与 [waitJs] 二选一，waitJs 优先。 */
    public String waitSelector;
    /** 加载完成后的固定等待毫秒（无 waitJs/waitSelector 时用；<=0 时默认 800ms）。 */
    public long waitDelayMs;
    /** 就绪后执行的 JS 表达式，结果经 JSON.stringify 回传到 [HtmlResult.eval]；空则不执行。 */
    public String script;
    /** 是否嗅探媒体地址（默认 true）。 */
    public boolean sniff = true;
    /** 总超时毫秒（默认 30000，上限 120000，超限按上限算）。 */
    public long timeoutMs = HtmlPageEngine.DEFAULT_TIMEOUT_MS;

    public HtmlRequest() {
    }

    public HtmlRequest(String url) {
        this.url = url;
    }

    /** 从 JSON 请求体解析（py 侧 HtmlPageRunner 入口用）。 */
    public static HtmlRequest fromJson(JSONObject json) {
        HtmlRequest request = new HtmlRequest();
        if (json == null) return request;
        request.url = json.optString("url", "");
        JSONObject headersJson = json.optJSONObject("headers");
        if (headersJson != null) {
            request.headers = new HashMap<>();
            Iterator<String> keys = headersJson.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                request.headers.put(key, headersJson.optString(key, ""));
            }
        }
        request.referer = json.optString("referer", "");
        request.userAgent = json.optString("userAgent", "");
        request.cookies = json.optString("cookies", "");
        JSONObject wait = json.optJSONObject("wait");
        if (wait != null) {
            request.waitJs = wait.optString("js", "");
            request.waitSelector = wait.optString("selector", "");
            request.waitDelayMs = wait.optLong("delayMs", 0);
        }
        if (json.has("waitDelayMs")) request.waitDelayMs = json.optLong("waitDelayMs", 0);
        request.script = json.optString("script", "");
        if (json.has("sniff")) request.sniff = json.optBoolean("sniff", true);
        if (json.has("timeoutMs")) request.timeoutMs = json.optLong("timeoutMs", request.timeoutMs);
        return request;
    }

    /** 从蜘蛛传来的 options Map 解析（Java 侧 HtmlPage 入口用）。 */
    @SuppressWarnings("unchecked")
    public static HtmlRequest fromOptions(String url, Map<String, Object> options) {
        HtmlRequest request = new HtmlRequest(url);
        if (options == null) return request;
        Object headers = options.get("headers");
        if (headers instanceof Map) {
            request.headers = new HashMap<>();
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) headers).entrySet()) {
                if (entry.getKey() != null && entry.getValue() != null) {
                    request.headers.put(entry.getKey().toString(), entry.getValue().toString());
                }
            }
        }
        request.referer = stringOption(options, "referer");
        request.userAgent = stringOption(options, "userAgent");
        request.cookies = stringOption(options, "cookies");
        request.waitJs = stringOption(options, "waitJs");
        request.waitSelector = stringOption(options, "waitSelector");
        request.script = stringOption(options, "script");
        Object delay = options.get("waitDelayMs");
        if (delay instanceof Number) request.waitDelayMs = ((Number) delay).longValue();
        Object wait = options.get("wait");
        if (wait instanceof Map) {
            Map<?, ?> waitMap = (Map<?, ?>) wait;
            if (isEmpty(request.waitJs)) request.waitJs = toStringOrEmpty(waitMap.get("js"));
            if (isEmpty(request.waitSelector)) {
                request.waitSelector = toStringOrEmpty(waitMap.get("selector"));
            }
            Object delayMs = waitMap.get("delayMs");
            if (delayMs instanceof Number) request.waitDelayMs = ((Number) delayMs).longValue();
        }
        Object sniff = options.get("sniff");
        if (sniff instanceof Boolean) request.sniff = (Boolean) sniff;
        Object timeout = options.get("timeoutMs");
        if (timeout instanceof Number) request.timeoutMs = ((Number) timeout).longValue();
        return request;
    }

    private static String stringOption(Map<String, Object> options, String key) {
        return toStringOrEmpty(options.get(key));
    }

    private static String toStringOrEmpty(Object value) {
        return value == null ? "" : value.toString();
    }

    static boolean isEmpty(String value) {
        return value == null || value.isEmpty();
    }

    /** 生效的总超时：夹在 1 秒与上限之间。 */
    public long effectiveTimeoutMs() {
        if (timeoutMs <= 0) return HtmlPageEngine.DEFAULT_TIMEOUT_MS;
        return Math.min(timeoutMs, HtmlPageEngine.MAX_TIMEOUT_MS);
    }
}
