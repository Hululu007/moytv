package com.github.catvod.utils;

import android.content.SharedPreferences;

import com.github.catvod.spider.Init;

/**
 * 偏好存取桩：只实现迅雷 aar 引用的两个方法。
 * getString 缺 key 必须回 "" 不能回 null：XLDownloadManager.getPeerId 拿到结果
 * 直接调 isEmpty()，没有判空，回 null 会空指针。
 */
public class Prefers {

    private static SharedPreferences prefs() {
        return Init.context().getSharedPreferences("catvod_prefers", 0);
    }

    public static String getString(String key) {
        try {
            return prefs().getString(key, "");
        } catch (ClassCastException e) {
            return "";
        }
    }

    public static void put(String key, Object value) {
        SharedPreferences.Editor editor = prefs().edit();
        if (value instanceof String) {
            editor.putString(key, (String) value);
        } else if (value instanceof Boolean) {
            editor.putBoolean(key, (Boolean) value);
        } else if (value instanceof Integer) {
            editor.putInt(key, (Integer) value);
        } else if (value instanceof Long) {
            editor.putLong(key, (Long) value);
        } else if (value instanceof Float) {
            editor.putFloat(key, (Float) value);
        } else if (value == null) {
            editor.remove(key);
        } else {
            editor.putString(key, String.valueOf(value));
        }
        editor.apply();
    }
}
