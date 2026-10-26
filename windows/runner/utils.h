#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <windows.h>

#include <string>
#include <vector>

// Single-instance forwarding: named mutex, main window class, and the
// WM_COPYDATA identifier used to pass a video path between instances.
constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\SteamFlowSingleInstance";
constexpr const wchar_t kMainWindowClassName[] =
    L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr UINT kSingleInstanceOpenFile = 0x53534631;  // 'SSF1'

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
