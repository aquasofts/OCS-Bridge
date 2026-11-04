#include "native_diagnostics.h"
#include "utils.h"
#include <shlobj.h>
#include <dbghelp.h>
#include <io.h>
#include <fcntl.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <thread>

namespace {
std::wstring directory;
HANDLE read_pipe = nullptr;
HANDLE original_output = nullptr;
HANDLE original_error = nullptr;
std::thread reader;
std::atomic<bool> stopping{false};
std::atomic<bool> started{false};
std::atomic<bool> crashing{false};

std::wstring Stamp(bool precise) {
  SYSTEMTIME now{}; GetSystemTime(&now);
  wchar_t value[64]{};
  if (precise) swprintf_s(value, L"%04u%02u%02u-%02u%02u%02u-%03u", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds);
  else swprintf_s(value, L"%04u%02u%02u-%02u%02u", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute);
  return value;
}

void Append(const char* bytes, DWORD length) {
  const auto path = directory + L"\\native-" + Stamp(false) + L"-" + std::to_wstring(GetCurrentProcessId()) + L".log";
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now{}; GetSystemTime(&now);
  char header[160]{};
  const int n = sprintf_s(header, "\n[%04u-%02u-%02uT%02u:%02u:%02u.%03uZ pid=%lu bytes=%lu]\n", now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, GetCurrentProcessId(), length);
  DWORD written = 0;
  WriteFile(file, header, static_cast<DWORD>(n), &written, nullptr);
  WriteFile(file, bytes, length, &written, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
}

void PruneNative() {
  FILETIME now{}; GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER ticks{}; ticks.LowPart = now.dwLowDateTime; ticks.HighPart = now.dwHighDateTime;
  const ULONGLONG cutoff = ticks.QuadPart - 24ULL * 60 * 60 * 10000000;
  WIN32_FIND_DATAW item{};
  HANDLE search = FindFirstFileW((directory + L"\\native-*").c_str(), &item);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    if ((item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    const std::wstring name(item.cFileName);
    const auto extension = std::filesystem::path(name).extension().wstring();
    if (extension != L".log" && extension != L".dmp") continue;
    ULARGE_INTEGER modified{}; modified.LowPart = item.ftLastWriteTime.dwLowDateTime; modified.HighPart = item.ftLastWriteTime.dwHighDateTime;
    if (modified.QuadPart < cutoff) DeleteFileW((directory + L"\\" + name).c_str());
  } while (FindNextFileW(search, &item));
  FindClose(search);
}

LONG WINAPI Crash(EXCEPTION_POINTERS* exception) {
  if (!crashing.exchange(true) && !directory.empty()) {
    char summary[256]{};
    const int n = sprintf_s(summary, "native.crash code=0x%08lx address=%p thread=%lu\n", exception->ExceptionRecord->ExceptionCode, exception->ExceptionRecord->ExceptionAddress, GetCurrentThreadId());
    Append(summary, static_cast<DWORD>(n));
    const auto path = directory + L"\\native-crash-" + Stamp(true) + L"-" + std::to_wstring(GetCurrentProcessId()) + L".dmp";
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      MINIDUMP_EXCEPTION_INFORMATION info{GetCurrentThreadId(), exception, FALSE};
      MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file, MiniDumpWithThreadInfo, &info, nullptr, nullptr);
      FlushFileBuffers(file); CloseHandle(file);
    }
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

void ReadOutput() {
  auto last_prune = std::chrono::steady_clock::now();
  char buffer[65536];
  while (true) {
    DWORD available = 0;
    if (!PeekNamedPipe(read_pipe, nullptr, 0, nullptr, &available, nullptr)) break;
    if (available > 0) {
      DWORD count = 0;
      const DWORD limit = available < sizeof(buffer) ? available : static_cast<DWORD>(sizeof(buffer));
      if (!ReadFile(read_pipe, buffer, limit, &count, nullptr)) break;
      Append(buffer, count);
      if (original_output && original_output != INVALID_HANDLE_VALUE) {
        DWORD written = 0; WriteFile(original_output, buffer, count, &written, nullptr);
      }
    } else {
      if (stopping) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (std::chrono::steady_clock::now() - last_prune >= std::chrono::minutes(1)) {
      PruneNative(); last_prune = std::chrono::steady_clock::now();
    }
  }
}
}  // namespace

bool StartNativeDiagnostics() {
  if (started) return true;
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) return false;
  directory = std::wstring(local) + L"\\OCSBridge\\logs"; CoTaskMemFree(local);
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return false;
  PruneNative();
  SetUnhandledExceptionFilter(Crash);
  HANDLE write_pipe = nullptr;
  if (!CreatePipe(&read_pipe, &write_pipe, nullptr, 65536)) return false;
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  const HANDLE error_output = GetStdHandle(STD_ERROR_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE) DuplicateHandle(GetCurrentProcess(), output, GetCurrentProcess(), &original_output, 0, FALSE, DUPLICATE_SAME_ACCESS);
  if (error_output && error_output != INVALID_HANDLE_VALUE) DuplicateHandle(GetCurrentProcess(), error_output, GetCurrentProcess(), &original_error, 0, FALSE, DUPLICATE_SAME_ACCESS);
  const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(write_pipe), _O_BINARY);
  if (fd == -1) { CloseHandle(read_pipe); CloseHandle(write_pipe); return false; }
  FILE* unused = nullptr;
  freopen_s(&unused, "NUL", "w", stdout);
  freopen_s(&unused, "NUL", "w", stderr);
  _dup2(fd, _fileno(stdout)); _dup2(fd, _fileno(stderr)); _close(fd);
  setvbuf(stdout, nullptr, _IONBF, 0); setvbuf(stderr, nullptr, _IONBF, 0);
  SetStdHandle(STD_OUTPUT_HANDLE, reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stdout))));
  SetStdHandle(STD_ERROR_HANDLE, reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stderr))));
  // ResyncOutputStreams reopens CONOUT$ inside the engine. Explorer-launched
  // GUI processes have no console: that path invokes the CRT invalid-parameter
  // handler and terminates with 0xC0000409. Keep the pipe handles instead;
  // Dart receives them through GetStdHandle and our runner CRT uses _dup2.
  stopping = false; started = true;
  reader = std::thread(ReadOutput);
  std::atexit(StopNativeDiagnostics);
  const auto command = Utf8FromUtf16(GetCommandLineW());
  fprintf(stdout, "native.start pid=%lu thread=%lu command=%s\n", GetCurrentProcessId(), GetCurrentThreadId(), command.c_str());
  return true;
}

void StopNativeDiagnostics() {
  if (!started.exchange(false)) return;
  fprintf(stdout, "native.stop pid=%lu\n", GetCurrentProcessId());
  fflush(stdout); fflush(stderr);
  stopping = true;
  if (reader.joinable()) reader.join();
  SetStdHandle(STD_OUTPUT_HANDLE, original_output); SetStdHandle(STD_ERROR_HANDLE, original_error);
  CloseHandle(read_pipe); read_pipe = nullptr;
}

void TraceNativeMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (!started) return;
  fprintf(stdout, "native.window.message tick=%llu thread=%lu hwnd=%p message=0x%04x wparam=0x%llx lparam=0x%llx\n", GetTickCount64(), GetCurrentThreadId(), hwnd, message, static_cast<unsigned long long>(wparam), static_cast<unsigned long long>(lparam));
}

bool NativeDiagnosticsActive() { return started; }
const std::wstring& NativeDiagnosticsDirectory() { return directory; }
