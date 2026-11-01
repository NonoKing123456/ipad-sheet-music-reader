#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr wchar_t kAppId[] = L"SheetMusicReader.Desktop";

// Keep taskbar pins independent of the versioned deployment directory.
void SetRelaunchIdentity(HWND window) {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                &local_app_data))) {
    return;
  }
  const std::wstring base = std::wstring(local_app_data) +
      L"\\Programs\\SheetMusicReader\\";
  CoTaskMemFree(local_app_data);
  IPropertyStore* properties = nullptr;
  if (FAILED(SHGetPropertyStoreForWindow(window, IID_PPV_ARGS(&properties)))) {
    return;
  }
  const auto set = [properties](REFPROPERTYKEY key, const std::wstring& text) {
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(InitPropVariantFromString(text.c_str(), &value))) {
      properties->SetValue(key, value);
    }
    PropVariantClear(&value);
  };
  set(PKEY_AppUserModel_ID, kAppId);
  set(PKEY_AppUserModel_RelaunchCommand,
      L"\"" + base + L"\u66f2\u8c31\u9605\u8bfb\u5668.exe\"");
  set(PKEY_AppUserModel_RelaunchDisplayNameResource,
      L"@" + base + L"\u66f2\u8c31\u9605\u8bfb\u5668.exe,-101");
  set(PKEY_AppUserModel_RelaunchIconResource, base + L"app_icon.ico,0");
  properties->Commit();
  properties->Release();
}
}  // namespace

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
  ::SetCurrentProcessExplicitAppUserModelID(kAppId);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u66f2\u8c31\u9605\u8bfb\u5668", origin, size)) {
    return EXIT_FAILURE;
  }
  SetRelaunchIdentity(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
