#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"

// A window that hosts a Flutter view and implements the "xiaoli/window"
// platform channel (always-on-top / mini window / background-run / block-quit).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Handles a call on the "xiaoli/window" channel.
  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 小窗播放：缩成右下角置顶悬浮小窗 / 还原。
  void SetMini(bool on);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "xiaoli/window" platform channel.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Window-feature state.
  bool background_run_ = false;  // 关窗时最小化而非退出
  bool block_quit_ = false;      // 禁止退出
  bool mini_ = false;            // 当前是否小窗
  RECT saved_frame_ = {0, 0, 0, 0};  // 进小窗前的窗口矩形
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
