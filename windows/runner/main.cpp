#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Single instance: when the named mutex already exists, forward the video
  // path from the command line to the running instance and exit, so we never
  // end up with a second window, tray icon, or share server.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutexName);
  const bool already_running =
      instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    std::wstring file_path;
    int argc = 0;
    wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
    if (argv != nullptr) {
      if (argc > 1) {
        file_path = argv[1];
      }
      ::LocalFree(argv);
    }

    HWND existing = ::FindWindowW(kMainWindowClassName, nullptr);
    if (existing != nullptr) {
      if (!file_path.empty()) {
        // The data stays valid until SendMessage returns, so the receiver
        // does not need to copy it first.
        COPYDATASTRUCT data = {};
        data.dwData = kSingleInstanceOpenFile;
        data.cbData =
            static_cast<DWORD>((file_path.size() + 1) * sizeof(wchar_t));
        data.lpData = const_cast<wchar_t*>(file_path.c_str());
        ::SendMessage(existing, WM_COPYDATA, 0,
                      reinterpret_cast<LPARAM>(&data));
      } else {
        // No file argument: just bring the existing window to the foreground.
        ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
      }
    }

    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SteamFlow", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
