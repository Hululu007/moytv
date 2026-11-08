import Foundation

enum PythonRuntimeError: Error {
  case frameworkMissing
  case initializeFailed
  case hostModuleMissing
  case hostFunctionMissing(String)
  case pythonError(String)
  case badReturnType

  var message: String {
    switch self {
    case .frameworkMissing: return "未找到 Python.framework（请先跑 scripts/prepare_ios_python.py）"
    case .initializeFailed: return "CPython 初始化失败"
    case .hostModuleMissing: return "宿主脚本 py_spider_host 未能导入"
    case .hostFunctionMissing(let name): return "宿主脚本缺少函数：\(name)"
    case .pythonError(let detail): return detail
    case .badReturnType: return "宿主脚本返回值不是字符串"
    }
  }
}

/// 进程内单例 CPython 运行时：一次性初始化，串行队列独占解释器，
/// 对外只暴露与安卓宿主脚本同名的三个入口。全部 PyObject 操作在
/// JHPyBridge.c 垫片内完成（Swift 无法 import 无模块图的 Python.framework）。
final class PythonRuntime {
  static let shared = PythonRuntime()

  let queue = DispatchQueue(label: "huoyi.pybridge.python")
  private var started = false

  private init() {}

  // PYTHONHOME 布局依据（BeeWare Python-Apple-support iOS 包，PEP 730 框架布局）：
  // 发布包内 Python.xcframework 的每个切片即一个 Python.framework，其根目录下
  // 有 lib/python3.12/（stdlib 本体，含 os.py 里程碑文件），框架根目录本身即
  // 可作 PYTHONHOME；个别版本把 stdlib 放在 Resources/ 下，故按候选顺序实地
  // 探测 lib/python3.12/os.py，命中哪个用哪个；都不命中即判定运行时缺失，
  // 绝不用无标准库的主目录硬启解释器（Py_Initialize 对坏主目录会直接致命退出，错误无从捕获）。
  private func locatePythonHome() -> String? {
    guard let frameworks = Bundle.main.privateFrameworksPath else { return nil }
    let framework = (frameworks as NSString).appendingPathComponent("Python.framework")
    guard FileManager.default.fileExists(atPath: framework) else { return nil }
    let candidates = [framework, (framework as NSString).appendingPathComponent("Resources")]
    for candidate in candidates {
      let landmark = (candidate as NSString).appendingPathComponent("lib/python3.12/os.py")
      if FileManager.default.fileExists(atPath: landmark) { return candidate }
    }
    return nil
  }

  func probeAvailable() -> Bool {
    locatePythonHome() != nil && locateHostScriptDirectory() != nil
  }

  private func locateHostScriptDirectory() -> String? {
    let bundles = [Bundle(for: PythonBridge.self), Bundle.main]
    for bundle in bundles {
      if let path = bundle.path(forResource: "py_spider_host", ofType: "py") {
        return (path as NSString).deletingLastPathComponent
      }
    }
    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(atPath: Bundle.main.bundlePath) else {
      return nil
    }
    for entry in contents where entry.hasSuffix(".bundle") {
      let candidate = (Bundle.main.bundlePath as NSString).appendingPathComponent(entry)
      let script = (candidate as NSString).appendingPathComponent("py_spider_host.py")
      if fileManager.fileExists(atPath: script) {
        return candidate
      }
    }
    return nil
  }

  private func locateVendorBundle() -> String? {
    Bundle.main.path(forResource: "PythonVendor", ofType: "bundle")
  }

  func ensureStarted() throws {
    if started { return }
    guard let home = locatePythonHome() else { throw PythonRuntimeError.frameworkMissing }
    setenv("PYTHONHOME", home, 1)
    setenv("PYTHONNOUSERSITE", "1", 1)
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
    var errbuf = [CChar](repeating: 0, count: 1024)
    let directory = locateHostScriptDirectory()
    let vendor = locateVendorBundle()
    let rc: Int32
    if let directory = directory, let vendor = vendor {
      rc = directory.withCString { host in
        vendor.withCString { vend in
          jhpy_start(host, vend, &errbuf, 1024)
        }
      }
    } else if let directory = directory {
      rc = directory.withCString { jhpy_start($0, nil, &errbuf, 1024) }
    } else {
      rc = jhpy_start(nil, nil, &errbuf, 1024)
    }
    if rc == -2 { throw PythonRuntimeError.initializeFailed }
    if rc != 0 {
      let detail = String(cString: errbuf)
      throw PythonRuntimeError.pythonError(detail.isEmpty ? "导入 py_spider_host 失败" : detail)
    }
    started = true
  }

  /// 在串行队列内、持 GIL 调用宿主函数；宿主函数签名均为 (字符串...) -> 字符串。
  func callHost(_ function: String, arguments: [String]) throws -> String {
    try ensureStarted()
    var cArgs: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
    defer { for pointer in cArgs { if let pointer = pointer { free(UnsafeMutablePointer(mutating: pointer)) } } }
    var errbuf = [CChar](repeating: 0, count: 1024)
    var errKind: Int32 = 1
    let result = jhpy_call(function, &cArgs, Int32(cArgs.count), &errbuf, 1024, &errKind)
    guard let result = result else {
      switch errKind {
      case 2: throw PythonRuntimeError.hostFunctionMissing(function)
      case 3: throw PythonRuntimeError.badReturnType
      default:
        let detail = String(cString: errbuf)
        throw PythonRuntimeError.pythonError(detail.isEmpty ? "宿主调用失败：\(function)" : detail)
      }
    }
    defer { jhpy_free(UnsafeMutablePointer(mutating: result)) }
    return String(cString: result)
  }

  func isInitialized() -> Bool { started && jhpy_is_initialized() != 0 }

  func version() -> String {
    guard let raw = jhpy_version() else { return "" }
    return String(cString: raw).split(separator: "\n").first.map(String.init) ?? ""
  }

  /// 探活第三方模块（如 requests）是否可用，结果只用于 status 的 detail 字段。
  func moduleAvailable(_ name: String) -> Bool {
    guard isInitialized() else { return false }
    return name.withCString { jhpy_module_available($0) } != 0
  }
}
