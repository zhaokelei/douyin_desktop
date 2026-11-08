#include "flutter_window.h"

#include <imm.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// VK_PROCESSKEY: Windows replaces the real virtual key with this value when
// an IME decides to consume the keystroke for composition.
constexpr WPARAM kImeProcessKey = 0xE5;

// Window property used to map the subclassed view HWND back to its owner.
const wchar_t* kViewHookProp = L"DouyinImeGuardWindow";

// ImmAssociateContext returns the context that was attached before the call;
// keep it so "restore" can put the exact same HIMC back (preserving the
// user's Chinese/English mode).
BOOL CALLBACK DetachImeChild(HWND hwnd, LPARAM lparam) {
  auto* saved =
      reinterpret_cast<std::unordered_map<HWND, HIMC>*>(lparam);
  HIMC previous = ImmAssociateContext(hwnd, nullptr);
  if (previous != nullptr && saved->find(hwnd) == saved->end()) {
    saved->emplace(hwnd, previous);
  }
  return TRUE;
}

}  // namespace

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

  // IME context switch: Dart calls "disable" while focus is not in a text
  // field, and "restore" when a comment/reply box is focused
  // (see lib/core/ime_guard.dart).
  ime_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "douyin/ime",
      &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "disable") {
          DisableIme();
          result->Success();
        } else if (call.method_name() == "restore") {
          RestoreIme();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // The view HWND owns the keyboard focus and therefore the IME messages.
  // Subclass it so composition can be blocked even if a third-party IME
  // re-attaches its context behind our back.
  InstallViewHook();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::DisableIme() {
  HWND root = GetHandle();
  if (!root) {
    return;
  }
  // Re-run on every "disable" call: the system or a third-party IME may have
  // attached a fresh context since the last one. Already-saved HIMCs are kept
  // so a later RestoreIme still restores the original context.
  HIMC previous = ImmAssociateContext(root, nullptr);
  if (previous != nullptr &&
      saved_ime_contexts_.find(root) == saved_ime_contexts_.end()) {
    saved_ime_contexts_.emplace(root, previous);
  }
  // Critical: focus is on the Flutter view *child* HWND. A top-level-only
  // detach leaves Microsoft Pinyin composing X/Z/S/Space there.
  EnumChildWindows(root, DetachImeChild,
                   reinterpret_cast<LPARAM>(&saved_ime_contexts_));
  ime_disabled_ = true;
}

void FlutterWindow::RestoreIme() {
  HWND root = GetHandle();
  if (!root || !ime_disabled_) {
    return;
  }
  // Unblock the view WndProc first, otherwise the IME messages emitted while
  // re-attaching the contexts would be swallowed again.
  ime_disabled_ = false;
  for (const auto& entry : saved_ime_contexts_) {
    if (IsWindow(entry.first)) {
      ImmAssociateContext(entry.first, entry.second);
    }
  }
  saved_ime_contexts_.clear();

  // A window created after DisableIme has no original context. Give the
  // focused one a default IME so comment/login text fields can type CJK.
  HWND focused = GetFocus();
  if (focused != nullptr && IsWindow(focused)) {
    HIMC current = ImmGetContext(focused);
    if (current == nullptr) {
      ImmAssociateContextEx(focused, nullptr, IACE_DEFAULT);
    } else {
      ImmReleaseContext(focused, current);
    }
  }
}

void FlutterWindow::InstallViewHook() {
  if (!flutter_controller_ || !flutter_controller_->view()) {
    return;
  }
  HWND view = flutter_controller_->view()->GetNativeWindow();
  if (view == nullptr || original_view_wndproc_ != nullptr) {
    return;
  }
  view_hwnd_ = view;
  SetPropW(view, kViewHookProp, reinterpret_cast<HANDLE>(this));
  original_view_wndproc_ = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      view, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(&FlutterWindow::ViewWndProc)));
  if (original_view_wndproc_ == nullptr) {
    RemovePropW(view, kViewHookProp);
    view_hwnd_ = nullptr;
  }
}

void FlutterWindow::RemoveViewHook() {
  if (view_hwnd_ != nullptr && original_view_wndproc_ != nullptr) {
    SetWindowLongPtrW(view_hwnd_, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(original_view_wndproc_));
    RemovePropW(view_hwnd_, kViewHookProp);
  }
  view_hwnd_ = nullptr;
  original_view_wndproc_ = nullptr;
}

LRESULT CALLBACK FlutterWindow::ViewWndProc(HWND hwnd, UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  auto* self =
      reinterpret_cast<FlutterWindow*>(GetPropW(hwnd, kViewHookProp));
  if (self != nullptr && self->original_view_wndproc_ != nullptr) {
    return self->HandleViewMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT FlutterWindow::HandleViewMessage(HWND hwnd, UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam) noexcept {
  if (ime_disabled_) {
    switch (message) {
      case WM_IME_SETCONTEXT:
        // The system wants to (re)show the IME UI. Detach again and swallow
        // the message so no candidate/composition window ever appears.
        ImmAssociateContext(hwnd, nullptr);
        return 0;
      case WM_IME_STARTCOMPOSITION:
      case WM_IME_COMPOSITION:
      case WM_IME_ENDCOMPOSITION:
      case WM_IME_NOTIFY:
      case WM_IME_CHAR:
        // Never show composition text or candidate windows in shortcut mode.
        return 0;
      case WM_KEYDOWN:
      case WM_SYSKEYDOWN:
        if (wparam == kImeProcessKey) {
          // The scan code survives IME rewriting; recover the real key so the
          // Flutter engine dispatches keyX / keyZ / space / etc. to Dart.
          const UINT scan = static_cast<UINT>((lparam >> 16) & 0xFF);
          const UINT vk = MapVirtualKeyW(scan, MAPVK_VSC_TO_VK_EX);
          const WPARAM restored = static_cast<WPARAM>(vk);
          if (restored != 0 && restored != kImeProcessKey) {
            wparam = restored;
          }
        }
        break;
      default:
        break;
    }
  }
  return CallWindowProcW(original_view_wndproc_, hwnd, message, wparam,
                         lparam);
}

void FlutterWindow::OnDestroy() {
  RemoveViewHook();
  // Give the IME context back before the window dies.
  RestoreIme();
  if (flutter_controller_) {
    ime_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
