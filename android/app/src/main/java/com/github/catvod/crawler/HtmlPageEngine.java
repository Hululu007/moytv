package com.github.catvod.crawler;

import android.content.Context;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.webkit.CookieManager;
import android.webkit.ValueCallback;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * HTML 取页引擎：py 核心与 Java 核心共用的 WebView 实现。
 * <p>
 * 每次调用一个全新 WebView，跑完即销毁；调用线程阻塞等结果，
 * WebView 的一切操作都在一条专用 HandlerThread 上完成。
 * 线程模型与收尾方式照 ZakaBreaker 的成熟写法，等待条件、
 * 通用 JS 求值与媒体嗅探是新增的通用能力，与破盾链无关。
 * <p>
 * 约束：禁止在主线程调用；全局最多 2 个并发（公平信号量）；
 * 总超时默认 30 秒、上限 120 秒，超时/盾页时已取到的数据仍附上。
 */
public final class HtmlPageEngine {
    public static final long DEFAULT_TIMEOUT_MS = 30000L;
    public static final long MAX_TIMEOUT_MS = 120000L;
    public static final int MAX_HTML_CHARS = 2_000_000;
    public static final int MAX_SNIFFED = 200;

    private static final int MAX_CONCURRENT = 2;
    private static final long POLL_INTERVAL_MS = 250L;
    private static final long SETTLE_MS = 800L;
    private static final long COLLECT_GRACE_MS = 3000L;
    private static final Semaphore SLOTS = new Semaphore(MAX_CONCURRENT, true);
    private static final Pattern MEDIA_URL = Pattern.compile(
            "\\.(m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(\\?|#|$)",
            Pattern.CASE_INSENSITIVE);
    private static final String[] CHALLENGE_MARKERS = {
            "Just a moment", "challenge-platform", "cf-chl-",
            "cf_challenge", "Attention Required",
    };

    /**
     * 媒体嗅探探针：与壳侧 {@code MediaSniffer.probeScript} 同源同义
     * （同后缀表、同 {@code window.__sniffedMedia/__sniffedAux} 槽位）。
     * 两边分处 Dart 资产与 Java 运行时，无法共用一份文件，故此处内嵌
     * 一份改编副本；改后缀表时两边必须同步（JVM 校验测试守后缀齐全）。
     */
    static final String PROBE_SCRIPT = """
(function () {
  if (window.__snifferInstalled) return;
  window.__snifferInstalled = true;
  window.__sniffedMedia = [];
  window.__sniffedAux = [];
  var pattern = /\\.(m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(\\?|#|$)/i;
  var auxPattern = /\\.(vtt|ass|srt)(\\?|#|$)/i;
  var textPattern = /https?:\\/\\/[^\\s"'<>\\\\]+?\\.(?:m3u8|mpd|mp4|m4v|mov|flv|m4s|webm|m4a|aac|mp3|wav|ogg)(?:\\?[^\\s"'<>\\\\]*)?/gi;
  var auxTextPattern = /https?:\\/\\/[^\\s"'<>\\\\]+?\\.(?:vtt|ass|srt)(?:\\?[^\\s"'<>\\\\]*)?/gi;
  function report(url) {
    if (typeof url !== 'string' || !pattern.test(url)) return;
    if (window.__sniffedMedia.indexOf(url) < 0) window.__sniffedMedia.push(url);
  }
  function reportAux(url) {
    if (typeof url !== 'string' || !auxPattern.test(url)) return;
    if (window.__sniffedAux.indexOf(url) < 0) window.__sniffedAux.push(url);
  }
  function reportText(text) {
    if (typeof text !== 'string') return;
    var found = text.match(textPattern);
    if (found) found.forEach(report);
    var auxFound = text.match(auxTextPattern);
    if (auxFound) auxFound.forEach(reportAux);
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    report(url);
    reportAux(url);
    return open.apply(this, arguments);
  };
  var xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    try {
      xhr.addEventListener('load', function () {
        try { reportText(xhr.responseText); } catch (e) {}
      });
    } catch (e) {}
    return xhrSend.apply(this, arguments);
  };
  var fetchOriginal = window.fetch;
  if (fetchOriginal) {
    window.fetch = function (input) {
      report(typeof input === 'string' ? input : input && input.url);
      reportAux(typeof input === 'string' ? input : input && input.url);
      var result = fetchOriginal.apply(this, arguments);
      try {
        result.then(function (response) {
          try {
            response.clone().text().then(reportText).catch(function () {});
          } catch (e) {}
          return response;
        });
      } catch (e) {}
      return result;
    };
  }
  var wsOriginal = window.WebSocket;
  if (wsOriginal) {
    window.WebSocket = function (url, protocols) {
      var ws = protocols ? new wsOriginal(url, protocols) : new wsOriginal(url);
      try {
        ws.addEventListener('message', function (event) {
          try { reportText(typeof event.data === 'string' ? event.data : ''); } catch (e) {}
        });
      } catch (e) {}
      return ws;
    };
    window.WebSocket.prototype = wsOriginal.prototype;
  }
  function scanDom() {
    document.querySelectorAll('video, audio, source, embed, object').forEach(function (node) {
      report(node.currentSrc || node.src || node.data);
    });
    document.querySelectorAll('track, link[rel="stylesheet"]').forEach(function (node) {
      reportAux(node.src || node.href);
    });
    document.querySelectorAll('iframe').forEach(function (node) {
      report(node.src);
      try {
        var inner = node.contentDocument;
        if (inner) {
          inner.querySelectorAll('video, audio, source').forEach(function (n) {
            report(n.currentSrc || n.src);
          });
          reportText(inner.documentElement ? inner.documentElement.innerHTML : '');
        }
      } catch (e) {}
    });
    document.querySelectorAll('script').forEach(function (node) {
      reportText(node.textContent);
    });
    reportText(document.documentElement ? document.documentElement.innerHTML : '');
    if (window.performance && performance.getEntriesByType) {
      performance.getEntriesByType('resource').forEach(function (entry) {
        report(entry.name);
      });
    }
  }
  new MutationObserver(scanDom).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src'],
  });
  scanDom();
})();
""";

    private HtmlPageEngine() {
    }

    public static boolean webViewAvailable() {
        try {
            Class.forName("android.webkit.WebView");
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static boolean isMainThread() {
        return Looper.myLooper() == Looper.getMainLooper();
    }

    /** evaluateJavascript 回的 JSON 引文解开；"null"/"undefined" 视为无值。 */
    static String unquoteJsString(String raw) {
        if (raw == null) return null;
        String value = raw.trim();
        if (value.isEmpty() || "null".equals(value) || "undefined".equals(value)) return null;
        if (value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
            try {
                return new JSONObject("{\"v\":" + value + "}").optString("v", null);
            } catch (Exception ignored) {
            }
            String inner = value.substring(1, value.length() - 1);
            return inner.replace("\\\"", "\"")
                    .replace("\\\\", "\\")
                    .replace("\\n", "\n")
                    .replace("\\t", "\t")
                    .replace("\\/", "/");
        }
        return value;
    }

    static boolean looksChallenged(String html) {
        if (html == null || html.isEmpty()) return false;
        for (String marker : CHALLENGE_MARKERS) {
            if (html.contains(marker)) return true;
        }
        return false;
    }

    /**
     * 同步取页：永不抛异常，失败以 {@link HtmlResult} 的 error 字段表达。
     * 调用方不得在主线程调用；request 只读，不改调用方对象。
     */
    public static HtmlResult load(Context context, HtmlRequest request) {
        if (request == null || HtmlRequest.isEmpty(request.url)) {
            return HtmlResult.failure("network", "地址为空");
        }
        String url = request.url.trim();
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            return HtmlResult.failure("network", "仅支持 http/https 地址");
        }
        if (context == null) {
            return HtmlResult.failure("no_webview", "Context 不可用，无法创建 WebView");
        }
        if (isMainThread()) {
            return HtmlResult.failure("no_webview", "禁止在主线程调用 HTML 取页");
        }
        if (!webViewAvailable()) {
            return HtmlResult.failure("no_webview", "WebView 内核不可用");
        }
        HtmlRequest effective = copyRequest(request, url);
        long budgetMs = effective.effectiveTimeoutMs();
        long startMs = SystemClock.uptimeMillis();
        boolean acquired;
        try {
            acquired = SLOTS.tryAcquire(budgetMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return HtmlResult.failure("timeout", "等待并发名额被中断");
        }
        if (!acquired) {
            return HtmlResult.failure("timeout", "等待并发名额超时");
        }
        try {
            long remaining = budgetMs - (SystemClock.uptimeMillis() - startMs);
            if (remaining < 1000) {
                return HtmlResult.failure("timeout", "等待并发名额耗尽时间预算");
            }
            Session session = new Session(
                    context.getApplicationContext(), effective, remaining);
            session.start();
            boolean done;
            try {
                done = session.latch.await(
                        remaining + COLLECT_GRACE_MS + 5000, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                session.finish(HtmlResult.failure("timeout", "等待被中断"));
                return HtmlResult.failure("timeout", "等待被中断");
            }
            if (!done || session.result == null) {
                session.finish(HtmlResult.failure("timeout", "等待页面超时"));
                return HtmlResult.failure("timeout", "等待页面超时");
            }
            return session.result;
        } finally {
            SLOTS.release();
        }
    }

    private static HtmlRequest copyRequest(HtmlRequest source, String url) {
        HtmlRequest copy = new HtmlRequest(url);
        copy.headers = source.headers == null ? null : new HashMap<>(source.headers);
        copy.referer = source.referer;
        copy.userAgent = source.userAgent;
        copy.cookies = source.cookies;
        copy.waitJs = source.waitJs;
        copy.waitSelector = source.waitSelector;
        copy.waitDelayMs = source.waitDelayMs;
        copy.script = source.script;
        copy.sniff = source.sniff;
        copy.timeoutMs = source.timeoutMs;
        return copy;
    }

    /** 一次取页的会话：全部 WebView 操作都在自己的 HandlerThread 上。 */
    private static final class Session {
        final Context appContext;
        final HtmlRequest request;
        final long deadlineMs;
        final long collectDeadlineMs;
        final CountDownLatch latch = new CountDownLatch(1);
        final LinkedHashSet<String> intercepted = new LinkedHashSet<>();

        HandlerThread thread;
        Handler handler;
        WebView webView;
        HtmlResult result;
        boolean finished;
        boolean collecting;
        boolean evalPending;
        boolean pageFinished;
        long finishedAtMs;
        boolean probeInjected;
        boolean timedOut;
        String lastError = "";
        String html = "";
        String title = "";
        String sniffedJson;
        String evalJson;

        Session(Context appContext, HtmlRequest request, long budgetMs) {
            this.appContext = appContext;
            this.request = request;
            long startMs = SystemClock.uptimeMillis();
            this.deadlineMs = startMs + budgetMs;
            this.collectDeadlineMs = deadlineMs + COLLECT_GRACE_MS;
        }

        void start() {
            thread = new HandlerThread("moyi-html");
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(this::onThreadStart);
        }

        void onThreadStart() {
            try {
                webView = new WebView(appContext);
                WebSettings settings = webView.getSettings();
                settings.setJavaScriptEnabled(true);
                settings.setDomStorageEnabled(true);
                settings.setDatabaseEnabled(true);
                settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
                settings.setMediaPlaybackRequiresUserGesture(false);
                if (!HtmlRequest.isEmpty(request.userAgent)) {
                    settings.setUserAgentString(request.userAgent);
                }
                CookieManager cookies = CookieManager.getInstance();
                cookies.setAcceptCookie(true);
                cookies.setAcceptThirdPartyCookies(webView, true);
                if (!HtmlRequest.isEmpty(request.cookies)) {
                    for (String part : request.cookies.split(";")) {
                        String cookie = part.trim();
                        if (!cookie.isEmpty()) cookies.setCookie(request.url, cookie);
                    }
                    cookies.flush();
                }
                webView.setWebViewClient(new Client());
                Map<String, String> headers = new HashMap<>();
                if (request.headers != null) headers.putAll(request.headers);
                if (!HtmlRequest.isEmpty(request.referer)) {
                    headers.put("Referer", request.referer);
                }
                webView.loadUrl(request.url, headers);
                handler.postDelayed(this::tick, POLL_INTERVAL_MS);
            } catch (Throwable t) {
                finish(HtmlResult.failure("no_webview", "WebView 创建失败：" + t));
            }
        }

        void evalJs(String script, ValueCallback<String> callback) {
            try {
                webView.evaluateJavascript(script, callback);
            } catch (Throwable t) {
                callback.onReceiveValue(null);
            }
        }

        void tick() {
            if (finished) return;
            long now = SystemClock.uptimeMillis();
            if (collecting) {
                if (now >= collectDeadlineMs) {
                    finishCollected(true);
                } else {
                    handler.postDelayed(this::tick, POLL_INTERVAL_MS);
                }
                return;
            }
            if (now >= deadlineMs) {
                timedOut = true;
                beginCollect();
                return;
            }
            if (evalPending) {
                handler.postDelayed(this::tick, POLL_INTERVAL_MS);
                return;
            }
            if (!HtmlRequest.isEmpty(request.waitJs)) {
                evalPending = true;
                evalJs("JSON.stringify((function(){try{return !!(" + request.waitJs
                        + ");}catch(e){return false;}})())", value -> {
                    evalPending = false;
                    if (finished) return;
                    if ("true".equals(unquoteJsString(value))) beginCollect();
                });
            } else if (!HtmlRequest.isEmpty(request.waitSelector)) {
                evalPending = true;
                evalJs("JSON.stringify(document.querySelector("
                        + JSONObject.quote(request.waitSelector) + ")!==null)", value -> {
                    evalPending = false;
                    if (finished) return;
                    if ("true".equals(unquoteJsString(value))) beginCollect();
                });
            } else if (pageFinished) {
                long delay = request.waitDelayMs > 0 ? request.waitDelayMs : SETTLE_MS;
                if (now >= finishedAtMs + delay) {
                    beginCollect();
                    return;
                }
            }
            if (!finished) handler.postDelayed(this::tick, POLL_INTERVAL_MS);
        }

        void beginCollect() {
            if (finished || collecting) return;
            collecting = true;
            collectHtml();
        }

        void collectHtml() {
            if (finished) return;
            if (SystemClock.uptimeMillis() >= collectDeadlineMs) {
                finishCollected(true);
                return;
            }
            evalJs("document.documentElement.outerHTML", value -> {
                if (finished) return;
                String decoded = unquoteJsString(value);
                html = decoded == null ? "" : decoded;
                collectTitle();
            });
        }

        void collectTitle() {
            if (finished) return;
            evalJs("document.title", value -> {
                if (finished) return;
                String decoded = unquoteJsString(value);
                title = decoded == null ? "" : decoded;
                collectSniffed();
            });
        }

        void collectSniffed() {
            if (finished) return;
            if (!request.sniff) {
                collectScript();
                return;
            }
            evalJs("JSON.stringify(window.__sniffedMedia||[])", value -> {
                if (finished) return;
                sniffedJson = unquoteJsString(value);
                collectScript();
            });
        }

        void collectScript() {
            if (finished) return;
            if (HtmlRequest.isEmpty(request.script)) {
                finishCollected(false);
                return;
            }
            evalJs("JSON.stringify((function(){try{return (" + request.script
                    + ");}catch(e){return {__moyiError:String(e&&e.message||e)};}})())", value -> {
                if (finished) return;
                evalJson = unquoteJsString(value);
                finishCollected(false);
            });
        }

        void finishCollected(boolean graceExpired) {
            if (finished) return;
            HtmlResult collected = new HtmlResult();
            if (html.length() > MAX_HTML_CHARS) {
                collected.html = html.substring(0, MAX_HTML_CHARS);
                collected.truncated = true;
            } else {
                collected.html = html;
            }
            collected.title = title;
            collected.url = currentUrl();
            collected.ua = currentUa();
            collected.cookies = currentCookies();
            collected.eval = evalJson;
            LinkedHashSet<String> merged = new LinkedHashSet<>();
            if (sniffedJson != null) {
                try {
                    JSONArray array = new JSONArray(sniffedJson);
                    for (int i = 0; i < array.length(); i++) {
                        String item = array.optString(i, "");
                        if (!item.isEmpty()) merged.add(item);
                    }
                } catch (Exception ignored) {
                }
            }
            synchronized (intercepted) {
                merged.addAll(intercepted);
            }
            ArrayList<String> capped = new ArrayList<>();
            for (String item : merged) {
                if (capped.size() >= MAX_SNIFFED) break;
                capped.add(item);
            }
            collected.sniffed = capped;
            if (looksChallenged(collected.html)) {
                collected.ok = false;
                collected.error = "challenge";
                collected.message = "页面疑似验证/盾页";
            } else if (timedOut || graceExpired) {
                collected.ok = false;
                collected.error = "timeout";
                collected.message = "等待页面超时";
            } else if (!pageFinished && !lastError.isEmpty()) {
                collected.ok = false;
                collected.error = "network";
                collected.message = lastError;
            } else {
                collected.ok = true;
            }
            finish(collected);
        }

        String currentUrl() {
            try {
                if (webView != null && webView.getUrl() != null) return webView.getUrl();
            } catch (Throwable ignored) {
            }
            return request.url;
        }

        String currentUa() {
            try {
                if (webView != null) return webView.getSettings().getUserAgentString();
            } catch (Throwable ignored) {
            }
            return request.userAgent == null ? "" : request.userAgent;
        }

        String currentCookies() {
            try {
                String value = CookieManager.getInstance().getCookie(request.url);
                return value == null ? "" : value;
            } catch (Throwable ignored) {
                return "";
            }
        }

        void recordIntercept(String url) {
            if (url == null || url.isEmpty()) return;
            if (!MEDIA_URL.matcher(url).find()) return;
            synchronized (intercepted) {
                if (intercepted.size() < MAX_SNIFFED) intercepted.add(url);
            }
        }

        void finish(HtmlResult outcome) {
            if (finished) return;
            finished = true;
            result = outcome;
            Runnable teardown = () -> {
                try {
                    if (handler != null) handler.removeCallbacksAndMessages(null);
                } catch (Throwable ignored) {
                }
                try {
                    if (webView != null) {
                        try {
                            webView.stopLoading();
                        } catch (Throwable ignored) {
                        }
                        try {
                            webView.loadUrl("about:blank");
                        } catch (Throwable ignored) {
                        }
                        try {
                            webView.destroy();
                        } catch (Throwable ignored) {
                        }
                        webView = null;
                    }
                } finally {
                    try {
                        if (thread != null) thread.quitSafely();
                    } catch (Throwable ignored) {
                    }
                    latch.countDown();
                }
            };
            try {
                if (thread != null && Looper.myLooper() == thread.getLooper()) {
                    teardown.run();
                } else if (handler != null) {
                    handler.post(teardown);
                } else {
                    latch.countDown();
                }
            } catch (Throwable ignored) {
                latch.countDown();
            }
        }

        final class Client extends WebViewClient {
            @Override
            public void onPageFinished(WebView view, String url) {
                pageFinished = true;
                finishedAtMs = SystemClock.uptimeMillis();
                if (request.sniff && !probeInjected) {
                    probeInjected = true;
                    try {
                        view.evaluateJavascript(PROBE_SCRIPT, null);
                    } catch (Throwable ignored) {
                    }
                }
            }

            @Override
            public void onReceivedError(
                    WebView view, WebResourceRequest request, WebResourceError error) {
                if (request != null && request.isForMainFrame()) {
                    lastError = String.valueOf(error.getDescription());
                }
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onReceivedError(
                    WebView view, int errorCode, String description, String failingUrl) {
                lastError = description == null ? ("error " + errorCode) : description;
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(
                    WebView view, WebResourceRequest request) {
                if (request != null && Session.this.request.sniff) {
                    recordIntercept(
                            request.getUrl() == null ? "" : request.getUrl().toString());
                }
                return null;
            }
        }
    }
}
