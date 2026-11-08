#include "moyi_quickjs.h"
#include <jni.h>
#include <stdlib.h>
#include <string.h>

static JavaVM *g_vm = NULL;
static jclass g_fetch_class = NULL;
static jmethodID g_fetch_method = NULL;

static char *jni_fetch(const char *url) {
    if (!g_vm || !g_fetch_class || !g_fetch_method) return NULL;
    JNIEnv *env = NULL;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0 || !env) return NULL;
    jstring jurl = (*env)->NewStringUTF(env, url);
    if (!jurl) return NULL;
    jstring jbody = (jstring)(*env)->CallStaticObjectMethod(env, g_fetch_class, g_fetch_method, jurl);
    (*env)->DeleteLocalRef(env, jurl);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NULL;
    }
    if (!jbody) return NULL;
    const char *body = (*env)->GetStringUTFChars(env, jbody, NULL);
    if (!body) {
        (*env)->DeleteLocalRef(env, jbody);
        return NULL;
    }
    char *copy = strdup(body);
    (*env)->ReleaseStringUTFChars(env, jbody, body);
    (*env)->DeleteLocalRef(env, jbody);
    return copy;
}

JNIEXPORT jstring JNICALL
Java_com_seku_huoyi_QuickJSBridge_nativeEval(JNIEnv *env, jclass clazz, jstring script, jint timeoutMs) {
    if ((*env)->GetJavaVM(env, &g_vm) == 0 && g_fetch_class == NULL) {
        jclass local = (*env)->FindClass(env, "moyi/QuickJSBridge");
        if (local) {
            g_fetch_class = (jclass)(*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
            g_fetch_method = (*env)->GetStaticMethodID(env, g_fetch_class, "fetch", "(Ljava/lang/String;)Ljava/lang/String;");
        }
        huoyi_qjs_set_fetch(jni_fetch);
    }
    (void)clazz;
    const char *text = script ? (*env)->GetStringUTFChars(env, script, NULL) : NULL;
    if (!text) return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"empty script\"}");
    char *out = huoyi_qjs_eval(text, (int)timeoutMs);
    (*env)->ReleaseStringUTFChars(env, script, text);
    jstring result = (*env)->NewStringUTF(env, out ? out : "{\"ok\":false,\"error\":\"out of memory\"}");
    huoyi_qjs_free(out);
    return result;
}
