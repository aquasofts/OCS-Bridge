#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <wincred.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <iostream>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "utils.h"
#include "native_diagnostics.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kCloseReady = WM_APP + 31;
constexpr UINT_PTR kCloseTimeout = 0x0C5;

std::string StringArg(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  if (it == args.end()) return {};
  const auto value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

std::wstring ToWide(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length == 0) return {};
  std::wstring output(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), output.data(), length);
  return output;
}

void HandleVault(const flutter::MethodCall<Value>& call,
                 std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!args) { result->Error("arguments", "Invalid arguments"); return; }
  const std::string id = StringArg(*args, "id");
  if (id.empty() || id.size() > 160) {
    result->Error("arguments", "Invalid provider ID"); return;
  }
  std::wstring target = L"OCSBridge/provider/" + ToWide(id);
  if (call.method_name() == "read") {
    PCREDENTIALW credential = nullptr;
    if (CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
      const std::string secret(reinterpret_cast<char*>(credential->CredentialBlob),
          credential->CredentialBlobSize);
      result->Success(Value(secret));
      SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
      CredFree(credential);
    } else if (GetLastError() == ERROR_NOT_FOUND) {
      result->Success();
    } else { result->Error("vault", "Credential read failed"); }
  } else if (call.method_name() == "write") {
    std::string secret = StringArg(*args, "value");
    if (secret.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      result->Error("vault", "API Key is too long"); return;
    }
    if (secret.empty()) {
      if (CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND) { result->Success(); }
      else { result->Error("vault", "Credential delete failed"); }
      return;
    }
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target.data();
    credential.CredentialBlobSize = static_cast<DWORD>(secret.size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(secret.data());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    const BOOL saved = CredWriteW(&credential, 0);
    const DWORD error = saved ? ERROR_SUCCESS : GetLastError();
    SecureZeroMemory(secret.data(), secret.size());
    if (saved) result->Success();
    else result->Error("vault", "Credential write failed", Value(static_cast<int>(error)));
  } else if (call.method_name() == "delete") {
    if (CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND) { result->Success(); }
    else { result->Error("vault", "Credential delete failed"); }
  } else { result->NotImplemented(); }
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  vault_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.ocsbridge/vault",
      &flutter::StandardMethodCodec::GetInstance());
  vault_channel_->SetMethodCallHandler(HandleVault);
  files_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.ocsbridge/files",
      &flutter::StandardMethodCodec::GetInstance());
  files_channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                 std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (call.method_name() == "requestSelfClose") {
      result->Success(); PostMessage(GetHandle(), WM_CLOSE, 0, 0); return;
    }
    if (call.method_name() == "windowVisible") {
      result->Success(Value(IsWindowVisible(GetHandle()) != FALSE)); return;
    }
    if (call.method_name() == "diagnosticOutput") {
      const auto text = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!text) { result->Error("arguments", "Expected diagnostic text"); return; }
      // The Dart runtime can retain absent GUI-process stdio descriptors even
      // after the runner installs its logging pipe. Write through the runner.
      std::cout << *text << std::endl;
      result->Success(); return;
    }
    if (call.method_name() == "diagnosticsStatus") {
      result->Success(Value(Map{{Value("active"), Value(NativeDiagnosticsActive())}, {Value("directory"), Value(Utf8FromUtf16(NativeDiagnosticsDirectory().c_str()))}}));
      return;
    }
    if (call.method_name() == "probe") {
      IFileSaveDialog* dialog = nullptr;
      const HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
      if (dialog) dialog->Release();
      if (SUCCEEDED(hr)) result->Success(Value(true));
      else result->Error("dialog", "Save dialog unavailable", Value(static_cast<int>(hr)));
      return;
    }
    if (call.method_name() != "chooseSave") { result->NotImplemented(); return; }
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args) { result->Error("arguments", "Invalid export arguments"); return; }
    IFileSaveDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&dialog));
    if (FAILED(hr)) { result->Error("dialog", "Cannot open save dialog", Value(static_cast<int>(hr))); return; }
    const auto filename = ToWide(StringArg(*args, "filename"));
    const auto extension = ToWide(StringArg(*args, "extension"));
    const auto description = ToWide(StringArg(*args, "description"));
    const auto pattern = L"*." + extension;
    const COMDLG_FILTERSPEC filter[] = {{description.c_str(), pattern.c_str()}};
    dialog->SetTitle(L"\u5bfc\u51fa\u7b54\u6848");
    dialog->SetFileName(filename.c_str());
    dialog->SetDefaultExtension(extension.c_str());
    dialog->SetFileTypes(1, filter);
    dialog->SetOptions(FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_OVERWRITEPROMPT | FOS_NOCHANGEDIR);
    IShellItem* downloads = nullptr;
    if (SUCCEEDED(SHCreateItemInKnownFolder(FOLDERID_Downloads, 0, nullptr, IID_PPV_ARGS(&downloads)))) {
      dialog->SetDefaultFolder(downloads); downloads->Release();
    }
    hr = dialog->Show(GetHandle());
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { dialog->Release(); result->Success(); return; }
    IShellItem* selected = nullptr;
    if (SUCCEEDED(hr)) hr = dialog->GetResult(&selected);
    PWSTR path = nullptr;
    if (SUCCEEDED(hr)) hr = selected->GetDisplayName(SIGDN_FILESYSPATH, &path);
    if (SUCCEEDED(hr)) result->Success(Value(Utf8FromUtf16(path)));
    else result->Error("dialog", "Cannot choose export path", Value(static_cast<int>(hr)));
    if (path) CoTaskMemFree(path);
    if (selected) selected->Release();
    dialog->Release();
  });
  lifecycle_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "dev.ocsbridge/lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    const auto& args = project_.dart_entrypoint_arguments();
    if (std::find(args.begin(), args.end(), "--smoke-test") == args.end() &&
        std::find(args.begin(), args.end(), "--smoke-test-close") == args.end()) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  lifecycle_channel_ = nullptr;
  files_channel_ = nullptr;
  vault_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kCloseReady) {
    allow_close_ = true;
    KillTimer(hwnd, kCloseTimeout);
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    return 0;
  }
  if (message == WM_TIMER && wparam == kCloseTimeout) {
    std::cerr << "close.flush.timeout" << std::endl;
    PostMessage(hwnd, kCloseReady, 0, 0);
    return 0;
  }
  if (message == WM_CLOSE && !allow_close_ && lifecycle_channel_) {
    if (close_requested_) return 0;
    close_requested_ = true;
    SetTimer(hwnd, kCloseTimeout, 15000, nullptr);
    auto complete = [hwnd]() { if (IsWindow(hwnd)) PostMessage(hwnd, kCloseReady, 0, 0); };
    lifecycle_channel_->InvokeMethod("closeRequested", nullptr,
      std::make_unique<flutter::MethodResultFunctions<Value>>(
        [complete](const Value*) { complete(); },
        [complete](const std::string&, const std::string&, const Value*) { complete(); },
        [complete]() { complete(); }));
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
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
