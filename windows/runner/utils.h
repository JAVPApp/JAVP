#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <windows.h>

#include <string>
#include <vector>

// Unique Win32 class name so protocol relaunches can find this process.
inline constexpr wchar_t kJavpWindowClassName[] = L"JAVP_DESKTOP_WINDOW";

// Named mutex for single-instance activation.
inline constexpr wchar_t kJavpSingleInstanceMutex[] =
    L"Local\\com.javp.javp.SingleInstance";

// WM_COPYDATA.dwData marker for deep-link / launch payloads (UTF-8).
inline constexpr ULONG_PTR kJavpCopyDataDeepLink = 0x4A415650;  // 'JAVP'

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// If argv includes --version / -V, print "JAVP <FLUTTER_VERSION>" to stdout
// and return true (caller should exit 0 without starting the UI). Used by
// terminals and package validators (e.g. WinGet) that probe installed EXEs.
bool TryHandleVersionFlag(const std::vector<std::string>& arguments);

// True when this process is the headless catalog SyncEngine (--javp-sync).
// Must skip single-instance activation and must not Show() the HWND.
bool HasJavpSyncFlag(const std::vector<std::string>& arguments);

// First CLI arg that looks like a javp:// / media / magnet launch link.
std::string GetLaunchLinkFromArguments(
    const std::vector<std::string>& arguments);

// Raise [hwnd] without AttachThreadInput. Joining our (often busy) UI
// thread to Explorer / a DWM ghost is what made the window un-foregroundable
// during sync. Safe to call from this process or a user-launched relaunch.
void FocusJavpWindow(HWND hwnd);

// If another JAVP instance owns the mutex, forward [launch_link] (may be empty)
// via WM_COPYDATA, focus that window, and return true (caller should exit).
bool ActivateExistingInstance(const std::string& launch_link);

#endif  // RUNNER_UTILS_H_
