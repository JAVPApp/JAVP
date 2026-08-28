#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that hosts a Flutter view and forwards protocol relaunches.
class FlutterWindow : public Win32Window {
 public:
  // Creates a FlutterWindow. When |sync_worker| is true the HWND stays hidden
  // (catalog SyncEngine child process).
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool sync_worker = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void DispatchDeepLink(const std::string& link);
  void FocusSelf();

  // The project to run.
  flutter::DartProject project_;

  // Headless SyncEngine — never Show() the HWND.
  bool sync_worker_ = false;

  // The Flutter instance hosted in this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Mirrors Android MainActivity's javp/deep_links channel for warm opens.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      deep_link_channel_;

  // Cold-start link from argv, also exposed via getInitialLink.
  std::string initial_link_;

  // WM_COPYDATA may arrive while the engine/channel is still starting.
  std::string pending_link_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
