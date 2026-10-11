import Cocoa
import FlutterMacOS

/// 首次安装或辅助程序更新时授权；日常会话通过受限本机套接字交给系统服务。
final class TunLauncher {
  private var process: Process?

  func start(endpoint: String, ticket: String, developmentHelper: String,
             completion: @escaping (String?) -> Void) throws {
    guard process == nil else {
      throw NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "虚拟网卡辅助进程仍在运行"])
    }
    let executable = try helperPath(developmentHelper)
    guard endpoint.hasPrefix("/") else {
      throw NSError(domain: "Network", code: 2, userInfo: [NSLocalizedDescriptionKey: "虚拟网卡内核路径无效"])
    }
    let launchSession = { [weak self] in
      guard let self = self else { return }
      do {
        try self.launch(executable, ["--client", "--control-file", endpoint, "--ticket", ticket,
                                    "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]) { code, detail in
          completion(code == 0 ? nil : "虚拟网卡启动或运行失败：" + detail)
        }
      } catch { completion(error.localizedDescription) }
    }
    try launch(executable, ["--service-status"]) { [weak self] code, detail in
      guard let self = self else { return }
      if code == 0 { launchSession(); return }
      guard code == 78 else { completion("检查虚拟网卡系统辅助服务失败：" + detail); return }
      do {
        try self.authorize([executable, "--install-service", "--owner-uid", String(getuid())]) { installed, message in
          if installed == 0 { launchSession() }
          else { completion(message.contains("-128") ? "已取消管理员授权" : "安装虚拟网卡系统辅助服务失败：" + message) }
        }
      } catch { completion(error.localizedDescription) }
    }
  }

  var serviceInstalled: Bool {
    FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.blacicada.network-tun/network-tun") ||
      FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.blacicada.network-tun.plist")
  }

  func remove(developmentHelper: String, completion: @escaping (String?) -> Void) throws {
    guard process == nil else {
      throw NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先关闭虚拟网卡或完成当前授权，再卸载辅助服务"])
    }
    if !serviceInstalled { completion(nil); return }
    let helper = try helperPath(developmentHelper)
    try authorize([helper, "--remove-service"]) { code, detail in
      completion(code == 0 ? nil : (detail.contains("-128") ? "已取消卸载授权" : "卸载系统辅助服务失败：" + detail))
    }
  }

  private func helperPath(_ developmentHelper: String) throws -> String {
    var helper = (Bundle.main.resourcePath ?? "") + "/proxy/network-tun"
    #if DEBUG
    if !developmentHelper.isEmpty { helper = developmentHelper }
    #endif
    guard FileManager.default.isExecutableFile(atPath: helper) else {
      throw NSError(domain: "Network", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少虚拟网卡辅助程序，请重新构建应用"])
    }
    return helper
  }

  private func authorize(_ arguments: [String], completion: @escaping (Int32, String) -> Void) throws {
    // 仅在安装、更新或卸载系统服务时提权，不保存管理员密码。
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let command = arguments.map(quote).joined(separator: " ")
    let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = "with timeout of 120 seconds\n do shell script \"" + literal + "\" with administrator privileges\nend timeout\n"
    try launch("/usr/bin/osascript", ["-"], input: Data(script.utf8), completion: completion)
  }

  private func launch(_ executable: String, _ arguments: [String], input: Data? = nil,
                      completion: @escaping (Int32, String) -> Void) throws {
    let child = Process()
    let errors = Pipe()
    let source = input == nil ? nil : Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.standardInput = source as Any? ?? FileHandle.nullDevice
    child.standardError = errors
    child.standardOutput = FileHandle.nullDevice
    child.terminationHandler = { [weak self] finished in
      let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        self?.process = nil
        completion(finished.terminationStatus, detail.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    try child.run()
    process = child
    if let data = input, let pipe = source {
      pipe.fileHandleForWriting.write(data)
      try pipe.fileHandleForWriting.close()
    }
  }
}
