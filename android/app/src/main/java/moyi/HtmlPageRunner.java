package moyi;

import android.content.Context;

import com.github.catvod.crawler.HtmlPageEngine;
import com.github.catvod.crawler.HtmlRequest;
import com.github.catvod.crawler.HtmlResult;
import com.github.catvod.spider.Init;

import org.json.JSONObject;

import java.lang.reflect.Method;

/**
 * Python 核心 HTML 取页入口：Chaquopy 直调的同步 runner。
 * <p>
 * 只有一个公开静态方法 {@link #fetch}（单签名，避免 Chaquopy
 * 重载解析歧义），JSON 进、JSON 出，永不抛异常。
 * py 侧调用发生在 PyBridge 的缓存线程池上（非主线程），
 * 引擎内部的主线程守卫与并发上限照常生效。
 * <p>
 * Context 解析：{@link #init} 显式注入 &gt; Init.context()
 * （JarBridge 注册时已初始化）&gt; ActivityThread 反射兜底。
 * init 目前未接线，留给以后宿主显式注入用。
 */
public final class HtmlPageRunner {
    private static volatile Context overrideContext;

    private HtmlPageRunner() {
    }

    /** 显式注入 Context（可选；不调则走 Init / 反射兜底）。 */
    public static void init(Context context) {
        overrideContext = context == null ? null : context.getApplicationContext();
    }

    /** 同步取页：入参为 HtmlRequest 的 JSON，结果为 HtmlResult 的 JSON。永不抛异常。 */
    public static String fetch(String requestJson) {
        try {
            JSONObject json = new JSONObject(requestJson == null ? "{}" : requestJson);
            HtmlRequest request = HtmlRequest.fromJson(json);
            Context context = resolveContext();
            if (context == null) {
                HtmlResult failure = HtmlResult.failure(
                        "no_webview", "Context 不可用，无法创建 WebView");
                failure.url = request.url;
                return failure.toJson().toString();
            }
            return HtmlPageEngine.load(context, request).toJson().toString();
        } catch (Throwable t) {
            try {
                return HtmlResult.failure("network", "请求解析失败：" + t).toJson().toString();
            } catch (Throwable ignored) {
                return "{\"ok\":false,\"error\":\"network\",\"message\":\"internal error\"}";
            }
        }
    }

    private static Context resolveContext() {
        Context context = overrideContext;
        if (context != null) return context;
        try {
            if (Init.isInitialized()) return Init.context();
        } catch (Throwable ignored) {
        }
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Method currentApplication = activityThread.getMethod("currentApplication");
            Object application = currentApplication.invoke(null);
            if (application instanceof Context) return (Context) application;
        } catch (Throwable ignored) {
        }
        return null;
    }
}
