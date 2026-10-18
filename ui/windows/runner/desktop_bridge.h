#ifndef ORBI_DESKTOP_BRIDGE_H_
#define ORBI_DESKTOP_BRIDGE_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>

// 桌面宿主只提供文件、窗口、托盘和提权启动，不持有代理业务状态。
class DesktopBridge {
 public:
  DesktopBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  HWND window_;
  bool tray_added_ = false;
  UINT taskbar_created_ = 0;
  void AddTray();
  bool running_ = false, busy_ = true, can_apply_ = false;
  double drag_right_ = 0, drag_top_ = 0, drag_height_ = 56;
  COLORREF background_ = RGB(245, 245, 245);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
