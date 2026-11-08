#include "moyi_quickjs.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

static HuoyiFetchFunc g_fetch = NULL;

void huoyi_qjs_set_fetch(HuoyiFetchFunc fn) { g_fetch = fn; }

void huoyi_qjs_free(char *ptr) { free(ptr); }

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

typedef struct {
    long long deadline_ms;
    char *result_json;
} HuoyiQjsState;

static int interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    HuoyiQjsState *state = (HuoyiQjsState *)opaque;
    return now_ms() > state->deadline_ms;
}

static JSValue js_set_result(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    JSValue json = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) return JS_EXCEPTION;
    const char *str = JS_ToCString(ctx, json);
    if (str) {
        HuoyiQjsState *state = (HuoyiQjsState *)JS_GetContextOpaque(ctx);
        free(state->result_json);
        state->result_json = strdup(str);
        JS_FreeCString(ctx, str);
    }
    JS_FreeValue(ctx, json);
    return JS_UNDEFINED;
}

static JSValue js_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !g_fetch) {
        return JS_ThrowTypeError(ctx, "fetch not available");
    }
    const char *url = JS_ToCString(ctx, argv[0]);
    if (!url) return JS_EXCEPTION;
    char *body = g_fetch(url);
    JS_FreeCString(ctx, url);
    if (!body) {
        return JS_ThrowInternalError(ctx, "fetch failed");
    }
    JSValue result = JS_NewString(ctx, body);
    free(body);
    return result;
}

static char *json_escape(const char *s) {
    size_t len = strlen(s);
    char *out = (char *)malloc(len * 2 + 3);
    if (!out) return NULL;
    size_t j = 0;
    out[j++] = '"';
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; }
        else if (c == '\n') { out[j++] = '\\'; out[j++] = 'n'; }
        else if (c == '\r') { out[j++] = '\\'; out[j++] = 'r'; }
        else if (c == '\t') { out[j++] = '\\'; out[j++] = 't'; }
        else if (c < 0x20) { j += (size_t)snprintf(out + j, 16, "\\u%04x", c); }
        else out[j++] = (char)c;
    }
    out[j++] = '"';
    out[j] = '\0';
    return out;
}

char *huoyi_qjs_eval(const char *script, int timeout_ms) {
    if (!script) return strdup("{\"ok\":false,\"error\":\"empty script\"}");
    if (timeout_ms <= 0) timeout_ms = 10000;
    if (timeout_ms > 60000) timeout_ms = 60000;
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return strdup("{\"ok\":false,\"error\":\"cannot create runtime\"}");
    JS_SetMemoryLimit(rt, 32 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 256 * 1024);
    HuoyiQjsState state;
    state.deadline_ms = now_ms() + timeout_ms;
    state.result_json = NULL;
    JS_SetInterruptHandler(rt, interrupt_handler, &state);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        return strdup("{\"ok\":false,\"error\":\"cannot create context\"}");
    }
    JS_SetContextOpaque(ctx, &state);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "setResult", JS_NewCFunction(ctx, js_set_result, "setResult", 1));
    JS_SetPropertyStr(ctx, global, "fetch", JS_NewCFunction(ctx, js_fetch, "fetch", 1));
    JS_FreeValue(ctx, global);
    JSValue val = JS_Eval(ctx, script, strlen(script), "<huoyi>", JS_EVAL_TYPE_GLOBAL);
    char *out = NULL;
    if (JS_IsException(val)) {
        JSValue exc = JS_GetException(ctx);
        const char *msg = JS_ToCString(ctx, exc);
        char *escaped = msg ? json_escape(msg) : strdup("\"unknown error\"");
        size_t need = strlen(escaped) + 32;
        out = (char *)malloc(need);
        if (out) snprintf(out, need, "{\"ok\":false,\"error\":%s}", escaped);
        free(escaped);
        if (msg) JS_FreeCString(ctx, msg);
        JS_FreeValue(ctx, exc);
    } else {
        if (state.result_json) {
            size_t need = strlen(state.result_json) + 32;
            out = (char *)malloc(need);
            if (out) snprintf(out, need, "{\"ok\":true,\"result\":%s}", state.result_json);
        } else {
            JSValue json = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
            if (!JS_IsException(json)) {
                const char *str = JS_ToCString(ctx, json);
                if (str) {
                    size_t need = strlen(str) + 32;
                    out = (char *)malloc(need);
                    if (out) snprintf(out, need, "{\"ok\":true,\"result\":%s}", str);
                    JS_FreeCString(ctx, str);
                }
                JS_FreeValue(ctx, json);
            }
            if (!out) out = strdup("{\"ok\":true,\"result\":null}");
        }
    }
    JS_FreeValue(ctx, val);
    free(state.result_json);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    if (!out) out = strdup("{\"ok\":false,\"error\":\"out of memory\"}");
    return out;
}
