import Flutter
import UIKit

final class PyImportInbox {
  static let shared = PyImportInbox()
  private init() {}
  private var pending: [[String: Any]] = []
  private var channel: FlutterMethodChannel?

  func bind(_ messenger: FlutterBinaryMessenger) {
    if channel != nil { return }
    let created = FlutterMethodChannel(name: "moyi/pyimport", binaryMessenger: messenger)
    created.setMethodCallHandler { [weak self] call, result in
      if call.method == "takePending" {
        result(self?.takeAll() ?? [])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = created
  }

  func stage(_ url: URL) {
    guard url.pathExtension.lowercased() == "py" else { return }
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyimport", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let target = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 0...9999)).py")
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.copyItem(at: url, to: target)
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
      pending.append(["path": target.path, "name": url.lastPathComponent, "size": size])
    } catch {
    }
  }

  func takeAll() -> [[String: Any]] {
    let items = pending
    pending.removeAll()
    return items
  }
}

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      PyImportInbox.shared.stage(context.url)
    }
    bindIfPossible(scene)
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    if super.responds(to: #selector(UIWindowSceneDelegate.scene(_:openURLContexts:))) {
      super.scene(scene, openURLContexts: urlContexts)
    }
    for context in urlContexts {
      PyImportInbox.shared.stage(context.url)
    }
    bindIfPossible(scene)
  }

  private func bindIfPossible(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene else { return }
    for window in windowScene.windows {
      if let controller = window.rootViewController as? FlutterViewController {
        PyImportInbox.shared.bind(controller.binaryMessenger)
        return
      }
    }
  }
}
