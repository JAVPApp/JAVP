#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // Exit before COM / single-instance mutex so package probes stay cheap.
  if (TryHandleVersionFlag(command_line_arguments)) {
    return EXIT_SUCCESS;
  }

  // Match flutter_local_notifications WindowsInitializationSettings AUMID.
  ::SetCurrentProcessExplicitAppUserModelID(L"com.javp.javp");

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::string launch_link =
      GetLaunchLinkFromArguments(command_line_arguments);
  const bool javp_sync = HasJavpSyncFlag(command_line_arguments);

  // SyncEngine must not starve the UI process — body-hash / SQL write on a
  // second Flutter instance made hover/clicks feel laggy across the shell.
  if (javp_sync) {
    ::SetPriorityClass(::GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
  }

  // Protocol / "Open with" relaunches must activate the running window instead
  // of creating a second process (which just looks like "JAVP opened again").
  // SyncEngine children must never steal or yield to that mutex.
  if (!javp_sync && ActivateExistingInstance(launch_link)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  // Dart UI tasks run on this same Win32 thread. A sync/catalog stall of a
  // few seconds makes Windows swap our HWND for a DWM ghost. Clicks then hit
  // the ghost (not us), so the app looks like it is blocking itself and
  // cannot be foregrounded even after Dart yields. Ghosting also breaks the
  // Flutter compositor on recovery. Yields in Dart still matter for jank;
  // this stops the ghost from stealing the window.
  using DisableGhostingFn = void(WINAPI*)();
  HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
  if (user32 != nullptr) {
    auto disable_ghosting = reinterpret_cast<DisableGhostingFn>(
        ::GetProcAddress(user32, "DisableProcessWindowsGhosting"));
    if (disable_ghosting != nullptr) {
      disable_ghosting();
    }
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, /*sync_worker=*/javp_sync);
  Win32Window::Point origin(10, 10);
  // Sync workers still need a Flutter view host; keep it tiny and never Show().
  Win32Window::Size size = javp_sync ? Win32Window::Size(1, 1)
                                     : Win32Window::Size(1280, 720);
  if (!window.Create(javp_sync ? L"JAVP Sync" : L"JAVP", origin, size,
                     /*no_activate=*/javp_sync)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
