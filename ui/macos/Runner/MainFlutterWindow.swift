import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?
  private let titleDragView = WindowTitleDragView()
  private let windowButtonsView = WindowButtonsView()
  private var titleDragWidth: NSLayoutConstraint?
  private var titlebarTopConstraints: [NSLayoutConstraint] = []
  private var titlebarHeightConstraints: [NSLayoutConstraint] = []
  private var statusItem: NSStatusItem?
  private let statusMenu = NSMenu()
  private let proxyStatus = NSMenuItem(title: "代理未运行", action: nil, keyEquivalent: "")
  private let toggleItem = NSMenuItem(title: "启动代理", action: #selector(toggleProxy), keyEquivalent: "")
  private let applyItem = NSMenuItem(title: "应用并保存配置", action: #selector(applyConfiguration), keyEquivalent: "s")

  override func awakeFromNib() {
    applyItem.isEnabled = false
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1120, height: 780))
    minSize = NSSize(width: 860, height: 640)
    title = "Network"
    // Flutter 顶栏延伸到窗口顶部，原生只保留真实的窗口按钮。
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    toolbar = nil
    isMovableByWindowBackground = false
    backgroundColor = .windowBackgroundColor
    setFrameAutosaveName("NetworkMainWindow")
    if !setFrameUsingName("NetworkMainWindow") { center() }
    RegisterGeneratedPlugins(registry: controller)
    desktopChannel = FlutterMethodChannel(name: "network_ui/desktop", binaryMessenger: controller.engine.binaryMessenger)
    desktopChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "desktopState":
          let state = call.arguments as? [String: Any] ?? [:]
          let running = state["running"] as? Bool ?? false
          let busy = state["busy"] as? Bool ?? true
          self.proxyStatus.title = busy ? "正在处理…" : (running ? "代理运行中" : "代理未运行")
          self.toggleItem.title = running ? "停止代理" : "启动代理"
          self.toggleItem.isEnabled = !busy
          self.applyItem.isEnabled = state["canApply"] as? Bool ?? false
          self.statusItem?.button?.toolTip = "Network · " + self.proxyStatus.title
          result(nil)
        case "showWindow":
          self.showMainWindow()
          result(nil)
        case "configureTitlebar":
          if let geometry = call.arguments as? [String: Double],
             let right = geometry["right"], let top = geometry["top"], let height = geometry["height"] {
            self.titleDragWidth?.constant = max(0, right - 78)
            self.titlebarTopConstraints.forEach { $0.constant = top }
            self.titlebarHeightConstraints.forEach { $0.constant = height }
            self.layoutWindowButtons()
          }
          result(nil)
        case "environment":
          let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          result(["support": root.appendingPathComponent("NetworkUI").path, "resources": Bundle.main.resourcePath ?? ""])
        case "chooseFile":
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          panel.message = ["certificate": "选择 PEM 格式的信任证书", "rules": "选择直连规则文本文件", "jar": "选择客户端 JAR 文件", "java": "选择 Java 25 可执行文件"][call.arguments as? String ?? ""] ?? "选择文件"
          panel.beginSheetModal(for: self) { response in
            result(response == .OK ? panel.url?.path : nil)
          }
        case "exportLogs":
          let panel = NSSavePanel()
          panel.nameFieldStringValue = "network-日志.txt"
          panel.beginSheetModal(for: self) { response in
            guard response == .OK, let url = panel.url else { result(nil); return }
            do {
              try (call.arguments as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
              result(url.path)
            } catch { result(FlutterError(code: "file", message: "导出日志失败", details: nil)) }
          }
        default: result(FlutterMethodNotImplemented)
        }
      } catch { result(FlutterError(code: "desktop", message: "访问应用目录失败", details: nil)) }
    }
    super.awakeFromNib()
    NotificationCenter.default.addObserver(self, selector: #selector(layoutWindowButtons), name: NSWindow.didResizeNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(layoutWindowButtons), name: NSWindow.didExitFullScreenNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(layoutWindowButtons), name: NSWindow.didEnterFullScreenNotification, object: self)
    installTitlebarViews(in: controller.view)
    layoutWindowButtons()
    configureMenuBar()
    // 等待主菜单完成 NIB 装载后，再接入应用操作。
    DispatchQueue.main.async { [weak self] in self?.configureApplicationMenu() }
  }

  // 原生顶栏只负责拖动和窗口按钮，布局独立于 Flutter 绘制及窗口缩放通知。
  func installTitlebarViews(in view: NSView) {
    // 直接约束到实际父视图顶部，避免缩放通知和自动调整框架重复移动按钮。
    titleDragView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleDragView)
    titleDragWidth = titleDragView.widthAnchor.constraint(equalToConstant: 0)
    titlebarTopConstraints = [
      titleDragView.topAnchor.constraint(equalTo: view.topAnchor),
      windowButtonsView.topAnchor.constraint(equalTo: view.topAnchor)
    ]
    titlebarHeightConstraints = [
      titleDragView.heightAnchor.constraint(equalToConstant: 56),
      windowButtonsView.heightAnchor.constraint(equalToConstant: 56)
    ]
    NSLayoutConstraint.activate([
      titleDragView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 78),
      titleDragWidth!
    ])
    windowButtonsView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(windowButtonsView)
    NSLayoutConstraint.activate([
      windowButtonsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      windowButtonsView.widthAnchor.constraint(equalToConstant: 78)
    ] + titlebarTopConstraints + titlebarHeightConstraints)
    // 保留真实的系统按钮，关闭按钮统一收起窗口，其余按钮沿用原生动作。
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      if let button = standardWindowButton(type) {
        if type == .closeButton {
          button.target = self
          button.action = #selector(performClose(_:))
        }
        windowButtonsView.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.autoresizingMask = [.minYMargin, .maxYMargin]
      }
    }
  }

  @objc private func layoutWindowButtons() {
    let fullScreen = styleMask.contains(.fullScreen)
    titleDragView.isHidden = fullScreen
    windowButtonsView.isHidden = fullScreen
    // 等待宿主完成本轮窗口布局后，重新将系统按钮居中，避免 AppKit 的按钮布局覆盖位置。
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.contentView?.layoutSubtreeIfNeeded()
      self.windowButtonsView.needsLayout = true
      self.windowButtonsView.layoutSubtreeIfNeeded()
    }
  }

  fileprivate func titlebarDoubleClick() {
    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    if action == "Minimize" { miniaturize(nil) }
    else if action != "None" { performZoom(nil) }
  }

  // 关闭按钮和 Command-W 收起窗口及 Dock 图标，保留菜单栏和内核。
  override func performClose(_ sender: Any?) {
    close()
  }

  override func close() {
    // 原生关闭按钮与直接关闭请求共用此入口，不销毁 Flutter 窗口或内核。
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  private func configureMenuBar() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "network", accessibilityDescription: "Network 代理")
    image?.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = "Network · 代理未运行"
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    let menu = statusMenu
    menu.autoenablesItems = false
    proxyStatus.isEnabled = false
    menu.addItem(proxyStatus)
    menu.addItem(.separator())
    let show = NSMenuItem(title: "显示窗口", action: #selector(showMainWindow), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    toggleItem.target = self
    toggleItem.isEnabled = false
    menu.addItem(toggleItem)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "退出 Network", action: #selector(quitApplication), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    statusItem = item
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    if let event = NSApp.currentEvent, event.type == .rightMouseUp {
      sender.highlight(true)
      defer { sender.highlight(false) }
      NSMenu.popUpContextMenu(statusMenu, with: event, for: sender)
    } else {
      showMainWindow()
    }
  }

  private func configureApplicationMenu() {
    guard let menu = NSApp.mainMenu else { return }
    if let viewMenu = menu.items.first(where: { $0.title == "显示" })?.submenu {
      for (index, page) in [(0, "概览"), (1, "连接配置"), (4, "活跃隧道"), (2, "路由规则"), (5, "连接诊断"), (3, "运行日志")].enumerated() {
        let item = NSMenuItem(title: page.1, action: #selector(navigatePage), keyEquivalent: String(index + 1))
        item.target = self
        item.tag = page.0
        viewMenu.insertItem(item, at: index)
      }
      viewMenu.insertItem(.separator(), at: 6)
    }
    let configuration = NSMenuItem(title: "配置", action: nil, keyEquivalent: "")
    let configurationMenu = NSMenu(title: "配置")
    configurationMenu.autoenablesItems = false
    applyItem.target = self
    configurationMenu.addItem(applyItem)
    configuration.submenu = configurationMenu
    menu.insertItem(configuration, at: 1)
  }

  @objc private func navigatePage(_ sender: NSMenuItem) {
    showMainWindow()
    desktopChannel?.invokeMethod("navigate", arguments: sender.tag)
  }

  @objc private func applyConfiguration() {
    desktopChannel?.invokeMethod("applyConfiguration", arguments: nil)
  }

  @objc func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func toggleProxy() {
    toggleItem.isEnabled = false
    desktopChannel?.invokeMethod("toggleProxy", arguments: nil)
  }

  @objc func openSettings(_ sender: Any?) {
    showMainWindow()
    desktopChannel?.invokeMethod("showSettings", arguments: nil)
  }

  @objc private func quitApplication() {
    // 与 Command-Q 共用 Flutter 退出请求，等待内核结束后再退出客户端。
    NSApp.terminate(nil)
  }

}

// 系统按钮集中在自己的区域布局，使用真实尺寸，随顶栏高度保持居中。
private final class WindowButtonsView: NSView {
  override func layout() {
    super.layout()
    let buttons = subviews.compactMap { $0 as? NSButton }
    guard !buttons.isEmpty else { return }
    let spacing: CGFloat = 6
    let width = buttons.reduce(CGFloat.zero) { $0 + $1.frame.width } + spacing * CGFloat(buttons.count - 1)
    var x = (bounds.width - width) / 2
    for button in buttons {
      button.setFrameOrigin(NSPoint(x: x, y: (bounds.height - button.frame.height) / 2))
      x += button.frame.width + spacing
    }
  }
}

// 透明区域直接使用原始鼠标事件，避免跨异步通道后丢失原生拖动时序。
private final class WindowTitleDragView: NSView {
  override func mouseDown(with event: NSEvent) {
    guard let window = window as? MainFlutterWindow else { return }
    if event.clickCount == 2 { window.titlebarDoubleClick() }
    else { window.performDrag(with: event) }
  }
}
