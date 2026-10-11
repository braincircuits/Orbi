import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {
  private func flutterController(in controller: NSViewController?) -> FlutterViewController? {
    if let flutter = controller as? FlutterViewController { return flutter }
    return controller?.children.compactMap { flutterController(in: $0) }.first
  }

  private func snapshot(_ channel: FlutterMethodChannel) -> [String: Any]? {
    let reply = expectation(description: "读取独立测试界面状态")
    var state: [String: Any]?
    channel.invokeMethod("snapshot", arguments: nil) { value in
      state = value as? [String: Any]
      reply.fulfill()
    }
    wait(for: [reply], timeout: 5)
    return state
  }

  func testSidebarReceivesCompleteClicks() throws {
    let window = try XCTUnwrap(NSApp.windows.first { flutterController(in: $0.contentViewController) != nil })
    let controller = try XCTUnwrap(flutterController(in: window.contentViewController))
    let channel = FlutterMethodChannel(name: "network_ui/sidebar_test", binaryMessenger: controller.engine.binaryMessenger)
    var state: [String: Any]?
    let deadline = Date().addingTimeInterval(10)
    repeat {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      state = snapshot(channel)
    } while state == nil && Date() < deadline
    guard state != nil else {
      XCTFail("请使用 test/fixtures/sidebar_host.dart 作为测试入口")
      return
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    for dark in [false, true] {
      if dark {
        let changed = expectation(description: "切换深色测试外观")
        channel.invokeMethod("dark", arguments: nil) { _ in changed.fulfill() }
        wait(for: [changed], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        state = snapshot(channel)
      }
      for (label, page) in [("连接配置", 1), ("添加连接", 1), ("路由规则", 2), ("设置…", 2), ("关闭设置（保留草稿）", 2)] {
        let positions = try XCTUnwrap(state?["positions"] as? [String: [Double]])
        let point = try XCTUnwrap(positions[label])
        let location = controller.view.convert(NSPoint(x: point[0], y: controller.view.bounds.height - point[1]), to: nil)
        let previousDown = state?["down"] as? Int ?? 0
        let previousUp = state?["up"] as? Int ?? 0
        let previousConnections = state?["connections"] as? Int ?? 0
        // 只向测试窗口投递事件，不移动或点击系统鼠标。
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
          window.sendEvent(event)
          RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        state = snapshot(channel)
        XCTAssertEqual(state?["down"] as? Int, previousDown + 1, "\(label)：按下事件应传入 Flutter")
        XCTAssertEqual(state?["up"] as? Int, previousUp + 1, "\(label)：松开事件应传入 Flutter")
        XCTAssertEqual(state?["page"] as? Int, page, "\(label)：点击后应切换页面")
        if label == "添加连接" {
          XCTAssertEqual(state?["connections"] as? Int, previousConnections + 1, "正文按钮应添加连接草稿")
        }
        if label == "设置…" {
          XCTAssertNotNil((state?["positions"] as? [String: [Double]])?["外观"], "点击设置后应打开外观设置")
        }
        if label == "关闭设置（保留草稿）" {
          XCTAssertNil((state?["positions"] as? [String: [Double]])?["外观"], "点击关闭后应退出设置")
        }
      }
    }
  }
}
