#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {
constexpr char kDeepLinkChannel[] = "javp/deep_links";
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool sync_worker)
    : project_(project), sync_worker_(sync_worker) {
  initial_link_ = GetLaunchLinkFromArguments(project.dart_entrypoint_arguments());
}

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

  deep_link_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kDeepLinkChannel,
          &flutter::StandardMethodCodec::GetInstance());
  deep_link_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialLink") {
          if (initial_link_.empty()) {
            result->Success(flutter::EncodableValue());
          } else {
            result->Success(flutter::EncodableValue(initial_link_));
            initial_link_.clear();
          }
          return;
        }
        result->NotImplemented();
      });

  if (!pending_link_.empty()) {
    DispatchDeepLink(pending_link_);
    pending_link_.clear();
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // SyncEngine children must stay invisible (and off the taskbar).
    if (!sync_worker_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  if (sync_worker_) {
    HWND hwnd = GetHandle();
    if (hwnd != nullptr) {
      // Keep out of Alt-Tab / taskbar even if something forces visibility.
      LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
      ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
                          ex | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
      ::ShowWindow(hwnd, SW_HIDE);
    }
  }

  return true;
}

void FlutterWindow::OnDestroy() {
  deep_link_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::DispatchDeepLink(const std::string& link) {
  if (link.empty()) {
    return;
  }
  if (deep_link_channel_ == nullptr) {
    pending_link_ = link;
    return;
  }
  deep_link_channel_->InvokeMethod(
      "onLink", std::make_unique<flutter::EncodableValue>(link));
}

void FlutterWindow::FocusSelf() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  FocusJavpWindow(hwnd);

  HWND child = nullptr;
  if (flutter_controller_ && flutter_controller_->view()) {
    child = flutter_controller_->view()->GetNativeWindow();
  }
  if (child != nullptr) {
    ::SetFocus(child);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // SyncEngine: never accept activation. CreateWindowEx(NOACTIVATE) is not
  // enough once Flutter's child view attaches — WM_MOUSEACTIVATE / WM_ACTIVATE
  // still bounced focus off the UI Synchroniser window.
  if (sync_worker_) {
    if (message == WM_MOUSEACTIVATE) {
      return MA_NOACTIVATE;
    }
    if (message == WM_ACTIVATE || message == WM_SETFOCUS ||
        message == WM_CHILDACTIVATE) {
      return 0;
    }
  }

  // Do not steal focus on every click. Windows is already activating on
  // WM_MOUSEACTIVATE. The old AttachThreadInput path joined this (Dart)
  // thread to Explorer/DWM during stalls and left the window unable to
  // come to the foreground. window_manager does not handle WM_MOUSEACTIVATE;
  // Win32Window already returns MA_ACTIVATE and focuses the Flutter child.

  if (message == WM_COPYDATA) {
    auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
    if (cds != nullptr && cds->dwData == kJavpCopyDataDeepLink &&
        cds->lpData != nullptr && cds->cbData > 0) {
      // Payload is a UTF-8 C string (includes trailing NUL in cbData).
      const auto* bytes = static_cast<const char*>(cds->lpData);
      size_t len = cds->cbData;
      if (len > 0 && bytes[len - 1] == '\0') {
        --len;
      }
      std::string link(bytes, len);
      FocusSelf();
      DispatchDeepLink(link);
      return TRUE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      if (message == WM_MOUSEACTIVATE) {
        return sync_worker_ ? MA_NOACTIVATE : MA_ACTIVATE;
      }
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
