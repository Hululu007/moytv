import Flutter
import UIKit
import MoyiCore
import PythonBridge
import QuickJSBridge
import CFNetwork

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PythonBridge") {
      PythonBridge.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QuickJSBridge") {
      QuickJSBridge.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppUpdate") {
      let channel = FlutterMethodChannel(name: "moyi/appupdate", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "appInfo":
          let info = Bundle.main.infoDictionary ?? [:]
          let name = info["CFBundleShortVersionString"] as? String ?? ""
          let code = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
          result(["versionName": name, "versionCode": code])
        case "openUrl":
          guard let arguments = call.arguments as? [String: Any],
                let raw = arguments["url"] as? String,
                let url = URL(string: raw) else {
            result(false)
            return
          }
          UIApplication.shared.open(url, options: [:]) { opened in
            result(opened)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "moyi/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PyImport") {
      let channel = FlutterMethodChannel(name: "moyi/pyimport", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "takePending" {
          result(PyImportInbox.shared.takeAll())
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
