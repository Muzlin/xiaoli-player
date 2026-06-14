#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // "xiaoli/window" 平台通道：窗口置顶 / 小窗 / 后台运行 / 禁止退出。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "xiaoli/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        this->HandleWindowCall(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetMini(bool on) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (on) {
    if (!mini_) {
      GetWindowRect(hwnd, &saved_frame_);
      mini_ = true;
    }
    RECT work;
    SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
    const int w = 480, h = 300;
    const int x = work.right - w - 24;
    const int y = work.bottom - h - 24;
    SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_SHOWWINDOW);
  } else if (mini_) {
    SetWindowPos(hwnd, HWND_NOTOPMOST, saved_frame_.left, saved_frame_.top,
                 saved_frame_.right - saved_frame_.left,
                 saved_frame_.bottom - saved_frame_.top, SWP_SHOWWINDOW);
    mini_ = false;
  }
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  HWND hwnd = GetHandle();

  // 取出 {"on": bool} 参数。
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  auto get_bool = [&](const char* key) -> bool {
    if (!args) return false;
    auto it = args->find(flutter::EncodableValue(std::string(key)));
    if (it != args->end()) {
      if (const bool* b = std::get_if<bool>(&it->second)) return *b;
    }
    return false;
  };

  if (method == "setAlwaysOnTop") {
    bool on = get_bool("on");
    if (hwnd) {
      SetWindowPos(hwnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE);
    }
    result->Success();
  } else if (method == "setMini") {
    SetMini(get_bool("on"));
    result->Success();
  } else if (method == "setBackgroundRun") {
    background_run_ = get_bool("on");
    result->Success();
  } else if (method == "backgroundRunEnabled") {
    result->Success(flutter::EncodableValue(background_run_));
  } else if (method == "setBlockQuit") {
    block_quit_ = get_bool("on");
    result->Success();
  } else if (method == "blockQuitEnabled") {
    result->Success(flutter::EncodableValue(block_quit_));
  } else if (method == "hotkeyEnabled" || method == "hideHotkeyEnabled") {
    // 全局热键在 Windows 端暂未实现（macOS Carbon 键码不通用）。
    result->Success(flutter::EncodableValue(false));
  } else {
    // setHotkey / setHideHotkey / setQuitPassword 等：静默接受，避免 Dart 端异常。
    result->Success();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      // 禁止退出：拦截关闭，提示去设置关闭开关。
      if (block_quit_) {
        MessageBoxW(hwnd, L"如需退出，请到设置里关闭「禁止退出」。",
                    L"已禁止退出", MB_OK | MB_ICONINFORMATION);
        return 0;
      }
      // 后台运行：关窗只最小化，应用留在任务栏。
      if (background_run_) {
        ShowWindow(hwnd, SW_MINIMIZE);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
