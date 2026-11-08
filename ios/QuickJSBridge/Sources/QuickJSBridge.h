#import <Flutter/Flutter.h>

@interface QuickJSBridge : NSObject <FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;
@end
