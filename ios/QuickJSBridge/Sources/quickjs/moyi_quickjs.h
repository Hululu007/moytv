#ifndef HUOYI_QUICKJS_H
#define HUOYI_QUICKJS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef char *(*HuoyiFetchFunc)(const char *url);

void huoyi_qjs_set_fetch(HuoyiFetchFunc fn);
char *huoyi_qjs_eval(const char *script, int timeout_ms);
void huoyi_qjs_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
