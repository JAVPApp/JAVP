#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <cctype>
#include <iostream>

namespace {

bool LooksLikeLaunchLink(const std::string& value) {
  if (value.empty()) {
    return false;
  }
  // Keep this heuristic aligned with Dart WindowsProtocol.isLaunchLink /
  // captureLaunchArgs (custom scheme, media URLs, magnets, local files).
  if (value.rfind("javp:", 0) == 0 || value.rfind("magnet:", 0) == 0 ||
      value.rfind("http://", 0) == 0 || value.rfind("https://", 0) == 0 ||
      value.rfind("file:", 0) == 0 || value.rfind("content:", 0) == 0) {
    return true;
  }
  if (value.find("://") != std::string::npos) {
    return false;
  }
  const auto dot = value.find_last_of('.');
  if (dot != std::string::npos) {
    std::string ext = value.substr(dot + 1);
    for (char& c : ext) {
      c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    }
    if (ext == "torrent" || ext == "mkv" || ext == "mp4" || ext == "avi" ||
        ext == "mov" || ext == "m3u" || ext == "m3u8" || ext == "ts" ||
        ext == "mp3" || ext == "flac") {
      return true;
    }
  }
  return false;
}

BOOL CALLBACK EnumVisibleJavpWindowProc(HWND hwnd, LPARAM lparam) {
  wchar_t class_name[64] = {};
  if (::GetClassNameW(hwnd, class_name, 64) == 0) {
    return TRUE;
  }
  if (wcscmp(class_name, kJavpWindowClassName) != 0) {
    return TRUE;
  }
  // Sync workers keep a hidden HWND with the same class; never activate those.
  if (!::IsWindowVisible(hwnd)) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(lparam) = hwnd;
  return FALSE;
}

HWND FindJavpWindow(int attempts = 50, int sleep_ms = 100) {
  for (int i = 0; i < attempts; ++i) {
    HWND hwnd = nullptr;
    ::EnumWindows(EnumVisibleJavpWindowProc, reinterpret_cast<LPARAM>(&hwnd));
    if (hwnd != nullptr) {
      return hwnd;
    }
    ::Sleep(sleep_ms);
  }
  return nullptr;
}

}  // namespace

void FocusJavpWindow(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }

  // Raise first, then activate. Never AttachThreadInput — that joins this
  // thread (the same one Dart stalls on) to Explorer or a hung-window ghost,
  // after which Windows refuses to foreground us until the process dies.
  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW | SWP_NOACTIVATE);
  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

bool HasJavpSyncFlag(const std::vector<std::string>& arguments) {
  for (const auto& arg : arguments) {
    if (arg == "--javp-sync" || arg.rfind("--javp-sync=", 0) == 0) {
      return true;
    }
  }
  return false;
}

bool TryHandleVersionFlag(const std::vector<std::string>& arguments) {
  bool want_version = false;
  for (const auto& arg : arguments) {
    if (arg == "--version" || arg == "-V") {
      want_version = true;
      break;
    }
  }
  if (!want_version) {
    return false;
  }

  // wWinMain already tried AttachConsole(ATTACH_PARENT_PROCESS). That updates
  // Win32 standard handles for a /SUBSYSTEM:WINDOWS binary, but CRT stdout
  // stays unbound until rebound — otherwise printf prints nothing.
  FILE* unused = nullptr;
  freopen_s(&unused, "CONOUT$", "w", stdout);
#ifndef FLUTTER_VERSION
#define FLUTTER_VERSION "0.0.0"
#endif
  std::printf("JAVP %s\n", FLUTTER_VERSION);
  std::fflush(stdout);
  return true;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::string GetLaunchLinkFromArguments(
    const std::vector<std::string>& arguments) {
  for (const auto& raw : arguments) {
    if (LooksLikeLaunchLink(raw)) {
      return raw;
    }
  }
  return std::string();
}

bool ActivateExistingInstance(const std::string& launch_link) {
  ::SetLastError(ERROR_SUCCESS);
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kJavpSingleInstanceMutex);
  if (mutex == nullptr) {
    return false;
  }
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    // First instance — keep the mutex handle alive for the process lifetime.
    // Intentionally leaked on success so the OS releases it on exit.
    static HANDLE retained_mutex = mutex;
    (void)retained_mutex;
    return false;
  }
  ::CloseHandle(mutex);

  HWND hwnd = FindJavpWindow();
  if (hwnd == nullptr) {
    // Another process holds the mutex but has no window yet / is exiting.
    // Prefer not opening a second UI.
    return true;
  }

  // This process was just launched by the user, so it holds foreground
  // permission. Grant it to the running instance and raise that HWND
  // *before* COPYDATA — SendMessage on a Dart-stalled thread would
  // otherwise freeze the new process and never activate the old one.
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid != 0) {
    ::AllowSetForegroundWindow(pid);
  }
  FocusJavpWindow(hwnd);

  if (!launch_link.empty()) {
    COPYDATASTRUCT cds;
    cds.dwData = kJavpCopyDataDeepLink;
    cds.cbData = static_cast<DWORD>(launch_link.size() + 1);
    cds.lpData = const_cast<char*>(launch_link.c_str());
    DWORD_PTR copy_result = 0;
    ::SendMessageTimeoutW(hwnd, WM_COPYDATA, reinterpret_cast<WPARAM>(hwnd),
                          reinterpret_cast<LPARAM>(&cds),
                          SMTO_ABORTIFHUNG | SMTO_NORMAL, 200, &copy_result);
  }

  return true;
}
