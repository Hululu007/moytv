package com.github.catvod;

import android.content.Context;

/**
 * 顶层 Init 委托：迅雷 aar（XLDownloadManager）引用的是 com.github.catvod.Init，
 * 实际状态只存在 spider.Init 一处，这里只做转发，不另立 Context holder。
 * 注意：本类与 spider.Init 同名，必须用全限定名调用，否则会递归调自己。
 */
public class Init {

    public static void init(Context context) {
        com.github.catvod.spider.Init.init(context);
    }

    public static Context context() {
        return com.github.catvod.spider.Init.context();
    }

    public static boolean isInitialized() {
        return com.github.catvod.spider.Init.isInitialized();
    }
}
