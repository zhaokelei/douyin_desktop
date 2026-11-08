#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <imm.h>
#include <windows.h>

#include <memory>
#include <unordered_map>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
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
  // Detach/restore the IME context (Chinese input-method guard).
  //
  // The keyboard focus lives on the Flutter *view* child HWND
  // (Win32Window::SetChildContent calls SetFocus(child_content_)), so only
  // detaching the top-level HWND leaves the input method attached to the
  // window that actually receives WM_KEYDOWN. Enumerate every child HWND.
  void DisableIme();
  void RestoreIme();

  // Subclass the Flutter view HWND: while IME is disabled, swallow all
  // composition messages (no candidate window / composition text) and turn
  // VK_PROCESSKEY back into the real virtual key using the scan code, so the
  // Dart side still receives LogicalKeyboardKey.keyX / keyZ.
  void InstallViewHook();
  void RemoveViewHook();
  static LRESULT CALLBACK ViewWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept;
  LRESULT HandleViewMessage(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam) noexcept;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Mirrors lib/core/ime_guard.dart: methods "disable" / "restore".
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ime_channel_;

  // Original IME context of every HWND we detached, restored on "restore".
  std::unordered_map<HWND, HIMC> saved_ime_contexts_;
  HWND view_hwnd_ = nullptr;
  WNDPROC original_view_wndproc_ = nullptr;
  bool ime_disabled_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
