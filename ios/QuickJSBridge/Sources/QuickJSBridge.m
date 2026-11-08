#import "QuickJSBridge.h"
#import "moyi_quickjs.h"
#import <Foundation/Foundation.h>

static char *objc_fetch(const char *url) {
    if (!url) return NULL;
    NSString *urlString = [NSString stringWithUTF8String:url];
    NSURL *nsUrl = [NSURL URLWithString:urlString];
    if (!nsUrl) return NULL;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:nsUrl];
    request.timeoutInterval = 15;
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    __block NSData *resultData = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) resultData = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (!resultData) return NULL;
    char *copy = (char *)malloc(resultData.length + 1);
    if (!copy) return NULL;
    memcpy(copy, resultData.bytes, resultData.length);
    copy[resultData.length] = '\0';
    return copy;
}

@implementation QuickJSBridge

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"moyi/quickjs" binaryMessenger:[registrar messenger]];
    QuickJSBridge *instance = [[QuickJSBridge alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"status"]) {
        result(@"{\"available\":true,\"engine\":\"QuickJS 2024-01-13\"}");
        return;
    }
    if ([call.method isEqualToString:@"eval"]) {
        NSDictionary *args = (NSDictionary *)call.arguments;
        NSString *script = args[@"script"];
        if (![script isKindOfClass:[NSString class]]) {
            result([FlutterError errorWithCode:@"invalid_argument" message:@"缺少 JS 脚本" details:nil]);
            return;
        }
        NSNumber *timeout = args[@"timeoutMs"];
        int timeoutMs = timeout ? (int)[timeout intValue] : 10000;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            huoyi_qjs_set_fetch(objc_fetch);
            char *out = huoyi_qjs_eval([script UTF8String], timeoutMs);
            NSString *json = out ? [NSString stringWithUTF8String:out] : @"{\"ok\":false,\"error\":\"out of memory\"}";
            if (out) huoyi_qjs_free(out);
            dispatch_async(dispatch_get_main_queue(), ^{ result(json); });
        });
        return;
    }
    result(FlutterMethodNotImplemented);
}

@end
