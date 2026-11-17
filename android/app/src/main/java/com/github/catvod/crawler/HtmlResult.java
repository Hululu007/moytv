package com.github.catvod.crawler;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * HTML 取页结果：py 核心与 Java 核心共用同一份语义（见 DESIGN.md §1）。
 * 失败时 [ok] 为 false，[error] 为五类可读错误之一：
 * timeout（超时）、challenge（验证/盾页）、no_webview（内核不可用）、
 * network（网络失败）、unsupported（本平台无此能力）。
 * 失败不抛异常、不静默空回；超时/盾页时已取到的 html/title/cookies
 * 仍附上，调用方可自行判断。
 */
public class HtmlResult {
    public boolean ok;
    /** 页面 HTML（documentElement.outerHTML；超长时截断并置 [truncated]）。 */
    public String html = "";
    /** 本次加载后 CookieManager 里该地址的 Cookie（只回传调用方）。 */
    public String cookies = "";
    /** 实际使用的 UA。 */
    public String ua = "";
    /** 嗅探到的媒体地址（去重，文档序/发现序）。 */
    public List<String> sniffed = new ArrayList<>();
    /** script 求值结果的 JSON 文本；未传 script 时为 null。 */
    public String eval;
    /** 失败类别（ok 时为空）。 */
    public String error = "";
    /** 可读失败说明（ok 时为空）。 */
    public String message = "";
    /** 页面标题（挑战页判断用）。 */
    public String title = "";
    /** 最终地址（跳转后）。 */
    public String url = "";
    /** html 是否因超长被截断。 */
    public boolean truncated;

    public HtmlResult() {
    }

    public static HtmlResult failure(String error, String message) {
        HtmlResult result = new HtmlResult();
        result.ok = false;
        result.error = error == null ? "" : error;
        result.message = message == null ? "" : message;
        return result;
    }

    public JSONObject toJson() {
        JSONObject json = new JSONObject();
        try {
            json.put("ok", ok);
            json.put("html", html == null ? "" : html);
            json.put("cookies", cookies == null ? "" : cookies);
            json.put("ua", ua == null ? "" : ua);
            JSONArray array = new JSONArray();
            if (sniffed != null) {
                for (String item : sniffed) array.put(item);
            }
            json.put("sniffed", array);
            if (eval != null) json.put("eval", eval);
            json.put("error", error == null ? "" : error);
            json.put("message", message == null ? "" : message);
            json.put("title", title == null ? "" : title);
            json.put("url", url == null ? "" : url);
            json.put("truncated", truncated);
        } catch (Exception ignored) {
        }
        return json;
    }

    public static HtmlResult fromJson(JSONObject json) {
        HtmlResult result = new HtmlResult();
        if (json == null) return result;
        result.ok = json.optBoolean("ok", false);
        result.html = json.optString("html", "");
        result.cookies = json.optString("cookies", "");
        result.ua = json.optString("ua", "");
        JSONArray array = json.optJSONArray("sniffed");
        if (array != null) {
            for (int i = 0; i < array.length(); i++) {
                result.sniffed.add(array.optString(i, ""));
            }
        }
        if (json.has("eval") && !json.isNull("eval")) result.eval = json.optString("eval", null);
        result.error = json.optString("error", "");
        result.message = json.optString("message", "");
        result.title = json.optString("title", "");
        result.url = json.optString("url", "");
        result.truncated = json.optBoolean("truncated", false);
        return result;
    }
}
