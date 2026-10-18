#include "desktop_bridge.h"
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shellapi.h>
#include <dwmapi.h>
#include <windowsx.h>
#include <sddl.h>
#include <aclapi.h>
#include <filesystem>
#include <fstream>
#include <thread>
#include <vector>
#include "resource.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kTrayMessage = WM_APP + 40, kTunExited = WM_APP + 41;
constexpr UINT kShow = 1001, kToggle = 1002, kApply = 1003, kQuit = 1004;
constexpr UINT kSystemQuit = 0x1f00;
struct TunExit { std::string ticket; DWORD code; };

std::wstring Wide(const std::string& text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(count, L'\0');
  if (count) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), count);
  return result;
}
std::string Utf8(const std::wstring& text) {
  int count = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  if (count) WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), count, nullptr, nullptr);
  return result;
}
std::string Text(const Map& map, const char* key) {
  auto found = map.find(Value(key));
  if (found == map.end()) return "";
  auto text = std::get_if<std::string>(&found->second);
  return text ? *text : "";
}
bool Flag(const Map& map, const char* key) {
  auto found = map.find(Value(key));
  return found != map.end() && std::holds_alternative<bool>(found->second) && std::get<bool>(found->second);
}
double Number(const Map& map, const char* key) {
  auto found = map.find(Value(key));
  if (found == map.end()) return 0;
  if (auto value = std::get_if<double>(&found->second)) return *value;
  if (auto value = std::get_if<int32_t>(&found->second)) return *value;
  if (auto value = std::get_if<int64_t>(&found->second)) return static_cast<double>(*value);
  return 0;
}
std::filesystem::path Resources() {
  std::vector<wchar_t> path(32768);
  DWORD count = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!count || count == path.size()) throw std::runtime_error("无法定位应用目录");
  return std::filesystem::path(std::wstring(path.data(), count)).parent_path();
}
// 文件只允许当前用户访问；凭据导出不会继承目标目录的公开读取权限。
void Restrict(const std::filesystem::path& path, bool directory) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("无法读取用户身份");
  DWORD length = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  std::vector<BYTE> data(length);
  BOOL read = GetTokenInformation(token, TokenUser, data.data(), length, &length);
  CloseHandle(token);
  if (!read) throw std::runtime_error("无法读取用户身份");
  EXPLICIT_ACCESSW access{};
  access.grfAccessPermissions = GENERIC_ALL;
  access.grfAccessMode = SET_ACCESS;
  access.grfInheritance = directory ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE;
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  access.Trustee.ptstrName = reinterpret_cast<LPWSTR>(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid);
  PACL acl = nullptr;
  DWORD code = SetEntriesInAclW(1, &access, nullptr, &acl);
  if (code == ERROR_SUCCESS) code = SetNamedSecurityInfoW(const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, acl, nullptr);
  if (acl) LocalFree(acl);
  if (code != ERROR_SUCCESS) throw std::runtime_error("无法保护文件访问权限");
}
std::optional<std::filesystem::path> Choose(HWND owner, bool save, const std::string& name) {
  IFileDialog* dialog = nullptr;
  HRESULT created = save ? CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog))
                           : CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(created)) throw std::runtime_error("无法打开系统文件选择器");
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | (save ? FOS_OVERWRITEPROMPT : FOS_FILEMUSTEXIST));
  if (!name.empty()) dialog->SetFileName(Wide(name).c_str());
  HRESULT selected = dialog->Show(owner);
  if (selected == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { dialog->Release(); return std::nullopt; }
  IShellItem* item = nullptr;
  PWSTR path = nullptr;
  if (FAILED(selected) || FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
    if (item) item->Release(); dialog->Release(); throw std::runtime_error("读取所选文件失败");
  }
  std::filesystem::path result(path);
  CoTaskMemFree(path); item->Release(); dialog->Release();
  return result;
}
void Export(const std::filesystem::path& path, const std::string& text) {
  GUID id{}; CoCreateGuid(&id);
  wchar_t guid[40]; StringFromGUID2(id, guid, 40);
  auto temporary = path.parent_path() / (std::wstring(L".orbi-export-") + guid);
  try {
    { std::ofstream file(temporary, std::ios::binary); if (!file) throw std::runtime_error("创建导出文件失败"); }
    Restrict(temporary, false);
    { std::ofstream file(temporary, std::ios::binary); file.write(text.data(), static_cast<std::streamsize>(text.size()));
      file.flush(); if (!file) throw std::runtime_error("写入导出文件失败"); }
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
      throw std::runtime_error("保存导出文件失败");
  } catch (...) { std::filesystem::remove(temporary); throw; }
}
std::wstring Quote(const std::wstring& value) {
  // Windows 命令行规则：引号前和末尾的反斜杠需要加倍。
  std::wstring result = L"\""; size_t slashes = 0;
  for (wchar_t ch : value) {
    if (ch == L'\\') { ++slashes; continue; }
    result.append(slashes * (ch == L'"' ? 2 : 1), L'\\'); slashes = 0;
    if (ch == L'"') result += L'\\'; result += ch;
  }
  result.append(slashes * 2, L'\\'); return result + L'"';
}
}

DesktopBridge::DesktopBridge(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger, "network_ui/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    try {
      const Map empty;
      const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const Map& args = arguments ? *arguments : empty;
      const auto& method = call.method_name();
      if (method == "environment") {
        auto support = Resources() / L"data";
        std::error_code error;
        std::filesystem::create_directories(support, error);
        if (error) throw std::runtime_error("无法创建程序同级的 data 目录，请将整个程序文件夹放到可写位置");
        Restrict(support, true);
        GUID id{}; CoCreateGuid(&id);
        wchar_t guid[40]; StringFromGUID2(id, guid, 40);
        auto probe = support / (std::wstring(L".write-check-") + guid);
        { std::ofstream file(probe, std::ios::binary);
          if (!file) throw std::runtime_error("程序同级的 data 目录不可写，请检查目录权限"); }
        std::filesystem::remove(probe, error);
        if (error) throw std::runtime_error("无法清理 data 目录中的写入检查文件，请检查目录权限");
        result->Success(Value(Map{{Value("support"), Value(Utf8(support.wstring()))}, {Value("resources"), Value(Utf8(Resources().wstring()))}, {Value("sidebarMaterial"), Value("false")}}));
      } else if (method == "desktopState") {
        running_ = Flag(args, "running"); busy_ = Flag(args, "busy"); can_apply_ = Flag(args, "canApply");
        EnableMenuItem(GetSystemMenu(window_, FALSE), kSystemQuit,
            MF_BYCOMMAND | (busy_ ? MF_GRAYED : MF_ENABLED));
        result->Success();
      } else if (method == "showWindow") {
        ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); result->Success();
      } else if (method == "configureTitlebar") {
        drag_right_ = Number(args, "right"); drag_top_ = Number(args, "top"); drag_height_ = Number(args, "height");
        auto color = static_cast<uint32_t>(Number(args, "backgroundColor"));
        background_ = RGB((color >> 16) & 255, (color >> 8) & 255, color & 255);
        BOOL dark = Text(args, "brightness") == "dark";
        DwmSetWindowAttribute(window_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
        DwmSetWindowAttribute(window_, DWMWA_CAPTION_COLOR, &background_, sizeof(background_));
        COLORREF foreground = dark ? RGB(242, 242, 242) : RGB(36, 36, 36);
        DwmSetWindowAttribute(window_, DWMWA_TEXT_COLOR, &foreground, sizeof(foreground));
        InvalidateRect(window_, nullptr, TRUE);
        result->Success();
      } else if (method == "tunServiceInstalled") { result->Success(Value(false));
      } else if (method == "removeTunService") { result->Error("tun", "Windows 使用每次会话授权，无需卸载常驻服务");
      } else if (method == "chooseFile" || method == "exportDocument" || method == "exportLogs") {
        bool save = method != "chooseFile";
        auto path = Choose(window_, save, method == "exportLogs" ? "Orbi-日志.txt" : Text(args, "name"));
        if (!path) { result->Success(); return; }
        if (save) {
          const auto* text = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
          Export(*path, method == "exportLogs" && text ? *text : Text(args, "text"));
        }
        result->Success(Value(Utf8(path->wstring())));
      } else if (method == "startTun") {
        auto helper = Resources() / L"proxy/network-tun.exe";
#ifdef _DEBUG
        if (!Text(args, "helper").empty()) helper = Wide(Text(args, "helper"));
#endif
        const auto endpoint = Wide(Text(args, "endpoint")); const auto ticket = Text(args, "ticket");
        if (!std::filesystem::exists(helper) || !std::filesystem::path(endpoint).is_absolute() || ticket.empty())
          throw std::runtime_error("缺少虚拟网卡辅助程序或启动参数无效");
        std::wstring parameters = L"--control-file " + Quote(endpoint) + L" --ticket " + Quote(Wide(ticket)) + L" --owner-pid " + std::to_wstring(GetCurrentProcessId());
        SHELLEXECUTEINFOW request{sizeof(request)}; request.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        request.hwnd = window_; request.lpVerb = L"runas"; request.lpFile = helper.c_str(); request.lpParameters = parameters.c_str(); request.nShow = SW_HIDE;
        if (!ShellExecuteExW(&request)) { result->Error("tun", GetLastError() == ERROR_CANCELLED ? "已取消管理员授权" : "虚拟网卡启动授权失败"); return; }
        HWND target = window_; HANDLE process = request.hProcess;
        std::thread([target, process, ticket]() {
          WaitForSingleObject(process, INFINITE); DWORD code = 1; GetExitCodeProcess(process, &code); CloseHandle(process);
          auto event = new TunExit{ticket, code};
          if (!PostMessageW(target, kTunExited, 0, reinterpret_cast<LPARAM>(event))) delete event;
        }).detach();
        result->Success();
      } else { result->NotImplemented(); }
    } catch (const std::exception& failure) { result->Error("desktop", failure.what()); }
  });
  auto system_menu = GetSystemMenu(window_, FALSE);
  AppendMenuW(system_menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(system_menu, MF_STRING | MF_GRAYED, kSystemQuit, L"退出 Orbi");
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTray();
}
void DesktopBridge::AddTray() {
  NOTIFYICONDATAW tray{sizeof(tray)}; tray.hWnd = window_; tray.uID = 1;
  tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP; tray.uCallbackMessage = kTrayMessage;
  tray.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON)); wcscpy_s(tray.szTip, L"Orbi");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE;
}
DesktopBridge::~DesktopBridge() {
  channel_->SetMethodCallHandler(nullptr);
  NOTIFYICONDATAW tray{sizeof(tray)}; tray.hWnd = window_; tray.uID = 1; Shell_NotifyIconW(NIM_DELETE, &tray);
}
std::optional<LRESULT> DesktopBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  // 真实窗口按钮优先交给系统，包括 Windows 11 最大化按钮的贴靠布局。
  LRESULT native = 0;
  if (DwmDefWindowProc(window_, message, wparam, lparam, &native)) return native;
  if (message == WM_NCHITTEST) {
    POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(window_, &point);
    const double scale = GetDpiForWindow(window_) / 96.0;
    if (!IsZoomed(window_)) {
      RECT area{}; GetClientRect(window_, &area);
      const int border = MulDiv(6, GetDpiForWindow(window_), 96);
      const bool left = point.x < border, right = point.x >= area.right - border;
      const bool top = point.y < border, bottom = point.y >= area.bottom - border;
      if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
      if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
    }
    auto hit = DefWindowProc(window_, message, wparam, lparam);
    if (hit != HTCLIENT && hit != HTCAPTION) return hit;
    if (point.y >= drag_top_ * scale && point.y < (drag_top_ + drag_height_) * scale && point.x < drag_right_ * scale) return HTCAPTION;
    return HTCLIENT;
  }
  if (message == WM_ERASEBKGND) {
    RECT area{}; GetClientRect(window_, &area);
    // 扩展框架下方必须为零透明像素，避免 GDI 底色盖住 DWM 按钮。
    FillRect(reinterpret_cast<HDC>(wparam), &area, reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    return 1;
  }
  if (taskbar_created_ && message == taskbar_created_) { AddTray(); return 0; }
  if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == kSystemQuit) {
    channel_->InvokeMethod("requestExit", nullptr); return 0;
  }
  if (message == WM_GETMINMAXINFO) {
    auto info = reinterpret_cast<MINMAXINFO*>(lparam); UINT dpi = GetDpiForWindow(window_);
    RECT area{0, 0, MulDiv(860, dpi, 96), MulDiv(640, dpi, 96)};
    AdjustWindowRectExForDpi(&area, static_cast<DWORD>(GetWindowLongPtrW(window_, GWL_STYLE)), FALSE,
        static_cast<DWORD>(GetWindowLongPtrW(window_, GWL_EXSTYLE)), dpi);
    info->ptMinTrackSize = {area.right - area.left, area.bottom - area.top}; return 0;
  }
  if (message == WM_CLOSE) {
    if (tray_added_) ShowWindow(window_, SW_HIDE);
    else channel_->InvokeMethod("requestExit", nullptr);
    return 0;
  }
  if (message == kTunExited) {
    std::unique_ptr<TunExit> event(reinterpret_cast<TunExit*>(lparam));
    channel_->InvokeMethod("tunExited", std::make_unique<Value>(Map{{Value("ticket"), Value(event->ticket)},
        {Value("error"), Value(event->code == 0 ? "" : "Windows 虚拟网卡进程异常退出，错误码：" + std::to_string(event->code))}})); return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP) { ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); }
    if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kShow, L"显示窗口");
      AppendMenuW(menu, MF_STRING | (busy_ ? MF_GRAYED : 0), kToggle, running_ ? L"停止代理" : L"启动代理");
      AppendMenuW(menu, MF_STRING | (can_apply_ ? 0 : MF_GRAYED), kApply, L"应用并保存配置");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING | (busy_ ? MF_GRAYED : 0), kQuit, L"退出 Orbi");
      POINT point; GetCursorPos(&point); SetForegroundWindow(window_);
      UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window_, nullptr); DestroyMenu(menu);
      if (selected == kShow) { ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); }
      if (selected == kToggle) channel_->InvokeMethod("toggleProxy", nullptr);
      if (selected == kApply) channel_->InvokeMethod("applyConfiguration", nullptr);
      if (selected == kQuit) channel_->InvokeMethod("requestExit", nullptr);
    }
    return 0;
  }
  return std::nullopt;
}
