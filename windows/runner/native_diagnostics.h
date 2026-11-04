#ifndef RUNNER_NATIVE_DIAGNOSTICS_H_
#define RUNNER_NATIVE_DIAGNOSTICS_H_
#include <windows.h>
#include <string>
bool StartNativeDiagnostics();
void StopNativeDiagnostics();
void TraceNativeMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
bool NativeDiagnosticsActive();
const std::wstring& NativeDiagnosticsDirectory();
#endif
