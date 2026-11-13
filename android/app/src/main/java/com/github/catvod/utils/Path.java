package com.github.catvod.utils;

import com.github.catvod.spider.Init;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class Path {

    public static List list(File dir) {
        if (dir == null) return new ArrayList();
        File[] children = dir.listFiles();
        if (children == null || children.length == 0) return new ArrayList();
        return Arrays.asList(children);
    }

    public static void clear(File file) {
        if (file == null || !file.exists()) return;
        if (file.isFile()) {
            file.delete();
            return;
        }
        File[] children = file.listFiles();
        if (children == null) return;
        for (File child : children) {
            if (child.isDirectory()) {
                clear(child);
                child.delete();
            } else {
                child.delete();
            }
        }
    }

    public static void copy(File src, File dst) {
        if (src == null || dst == null || !src.isFile()) return;
        File parent = dst.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        try {
            InputStream input = new FileInputStream(src);
            try {
                OutputStream output = new FileOutputStream(dst);
                try {
                    byte[] buffer = new byte[8192];
                    int read;
                    while ((read = input.read(buffer)) > 0) {
                        output.write(buffer, 0, read);
                    }
                } finally {
                    output.close();
                }
            } finally {
                input.close();
            }
        } catch (Exception e) {
            // 拷任务文件失败不崩调用方，静默返回
        }
    }

    public static File root() {
        return Init.context().getFilesDir();
    }

    public static File cache() {
        File dir = Init.context().getCacheDir();
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File cache(String name) {
        File file = new File(cache(), name);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        return file;
    }

    public static File files() {
        File dir = Init.context().getFilesDir();
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File files(String name) {
        File file = new File(files(), name);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        return file;
    }

    public static File download() {
        File dir = new File(files(), "download");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File jar() {
        throw new UnsupportedOperationException(
                "catvod 兼容层未实现 Path.jar()：本 App 不提供壳内 jar 目录");
    }

    public static File tv() {
        throw new UnsupportedOperationException(
                "catvod 兼容层未实现 Path.tv()：本 App 不提供壳内电视目录");
    }
}
