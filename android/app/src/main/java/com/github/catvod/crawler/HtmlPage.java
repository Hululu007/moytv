package com.github.catvod.crawler;

import android.content.Context;

import com.github.catvod.spider.Init;

import java.util.Map;

/**
 * Java 蜘蛛侧 HTML 取页助手：与壳同包（父优先对所有 jar 可见），
 * jar 蜘蛛显式调用才生效，不用的蜘蛛行为一字不动。
 * <p>
 * Context 解析顺序：显式参数 &gt; 调用方传来的 Context &gt; Init.context()。
 * 基类 {@link Spider#htmlPage} 会把 init 时存下的 Context 传进来。
 */
public final class HtmlPage {
    private HtmlPage() {
    }

    /** 本平台能否取页（WebView 内核是否存在）。主线程守卫等在 load 里另判。 */
    public static boolean supported() {
        return HtmlPageEngine.webViewAvailable();
    }

    public static HtmlResult load(String url) {
        return load(url, null, null);
    }

    public static HtmlResult load(String url, Map<String, Object> options) {
        return load(url, options, null);
    }

    public static HtmlResult load(String url, Map<String, Object> options, Context context) {
        HtmlRequest request = HtmlRequest.fromOptions(url, options);
        Context resolved = context;
        if (resolved == null) {
            try {
                if (Init.isInitialized()) resolved = Init.context();
            } catch (Throwable ignored) {
            }
        }
        if (resolved == null) {
            return HtmlResult.failure("no_webview", "Context 不可用，无法创建 WebView");
        }
        return HtmlPageEngine.load(resolved, request);
    }
}
