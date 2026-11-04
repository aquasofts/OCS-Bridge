#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "native_diagnostics.h"

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
  StartNativeDiagnostics();
  const auto native_arguments = GetCommandLineArguments();
  if (std::find(native_arguments.begin(), native_arguments.end(), "--diagnostics-crash-test") != native_arguments.end()) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    RaiseException(0xE0420C51, EXCEPTION_NONCONTINUABLE, 0, nullptr);
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  if (std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--compat-renderer") != command_line_arguments.end()) {
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(100, 80);
  Win32Window::Size size(1180, 800);
  if (!window.Create(L"OCS Bridge", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  StopNativeDiagnostics();
  return EXIT_SUCCESS;
}
