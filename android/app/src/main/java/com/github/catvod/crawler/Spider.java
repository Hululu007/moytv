package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Spider {

    /** init 时存下的应用 Context，供 htmlPage 用；不用的蜘蛛不受影响。 */
    protected Context htmlContext;

    public void init(Context context) throws Exception {
        htmlContext = context == null ? null : context.getApplicationContext();
    }

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    /** HTML 取页：显式调用才生效，走共享引擎；Context 取 init 时存下的，缺失时回落 Init。 */
    protected HtmlResult htmlPage(String url) {
        return htmlPage(url, null);
    }

    protected HtmlResult htmlPage(String url, Map<String, Object> options) {
        return HtmlPage.load(url, options, htmlContext);
    }

    public String getName() {
        return "";
    }

    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    public String homeVideoContent() throws Exception {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        return "";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return searchContent(key, quick);
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "";
    }

    public String liveContent(String url) throws Exception {
        return "";
    }

    public String action(String action) throws Exception {
        return "";
    }

    public boolean isVideoFormat(String url) {
        return false;
    }

    public boolean manualVideoCheck() {
        return false;
    }

    public Object[] proxy(Map<String, String> params) {
        return null;
    }

    public void destroy() {
    }
}
