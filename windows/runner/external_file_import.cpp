#include "external_file_import.h"

#include <ole2.h>
#include <winternl.h>
#include <algorithm>
#include <functional>
#include <utility>
#include <cwctype>
#include <cstring>

#include "utils.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::wstring Wide(const std::string& input) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      input.data(), static_cast<int>(input.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring output(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
      static_cast<int>(input.size()), output.data(), length);
  return output;
}
std::string Argument(const Map* args, const char* key) {
  if (!args) return {};
  const auto found = args->find(Value(key));
  if (found == args->end()) return {};
  const auto value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string();
}

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE value) : value(value) {}
  ~ScopedHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  HANDLE value;
};

class DirectoryLocks {
 public:
  ~DirectoryLocks() { for (auto handle : handles) CloseHandle(handle); }
  std::vector<HANDLE> handles;
  std::vector<BY_HANDLE_FILE_INFORMATION> identities;
  DWORD Validate() const {
    for (size_t index = 0; index < handles.size(); ++index) {
      BY_HANDLE_FILE_INFORMATION current{};
      if (!GetFileInformationByHandle(handles[index], &current)) return GetLastError();
      const auto& expected = identities[index];
      if (!(current.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
          (current.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
          current.dwVolumeSerialNumber != expected.dwVolumeSerialNumber ||
          current.nFileIndexHigh != expected.nFileIndexHigh ||
          current.nFileIndexLow != expected.nFileIndexLow) return ERROR_ACCESS_DENIED;
    }
    return ERROR_SUCCESS;
  }
};

bool SameFile(const BY_HANDLE_FILE_INFORMATION& a,
              const BY_HANDLE_FILE_INFORMATION& b) {
  return a.dwVolumeSerialNumber == b.dwVolumeSerialNumber &&
      a.nFileIndexHigh == b.nFileIndexHigh && a.nFileIndexLow == b.nFileIndexLow;
}
bool EqualPath(const std::wstring& a, const std::wstring& b) {
  return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
      b.c_str(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

// Accept DOS absolute and UNC names, including their extended-length forms.
// Reject Win32 aliases/streams and device namespaces rather than interpreting
// them differently during validation and the later copy/rename.
bool AbsolutePath(std::wstring input, std::wstring* path, size_t* volume_end) {
  std::replace(input.begin(), input.end(), L'/', L'\\');
  if (input.compare(0, 8, L"\\\\?\\UNC\\") == 0) input = L"\\\\" + input.substr(8);
  else if (input.compare(0, 4, L"\\\\?\\") == 0) input.erase(0, 4);
  size_t start = 0;
  if (input.size() >= 3 && ((input[0] >= L'A' && input[0] <= L'Z') ||
      (input[0] >= L'a' && input[0] <= L'z')) && input[1] == L':' && input[2] == L'\\') {
    *path = L"\\\\?\\" + input;
    start = *volume_end = 7;
  } else if (input.compare(0, 2, L"\\\\") == 0) {
    const auto server_end = input.find(L'\\', 2);
    if (server_end == std::wstring::npos || server_end == 2) return false;
    const auto share_end = input.find(L'\\', server_end + 1);
    if (server_end + 1 == input.size() || share_end == server_end + 1) return false;
    // Validate the server/share components below as well as descendants.
    *path = L"\\\\?\\UNC\\" + input.substr(2);
    *volume_end = share_end == std::wstring::npos ? path->size() : share_end + 6;
    start = 8;
  } else { return false; }
  while (path->size() > *volume_end && path->back() == L'\\') path->pop_back();
  for (size_t at = start; at < path->size();) {
    const auto end = path->find(L'\\', at);
    const auto component = path->substr(at,
        (end == std::wstring::npos ? path->size() : end) - at);
    if (component.empty() || component == L"." || component == L".." ||
        component.back() == L'.' || component.back() == L' ') return false;
    for (auto character : component) {
      if (character < 32 || std::wstring(L"<>:\"|?*").find(character) != std::wstring::npos)
        return false;
    }
    auto stem = component.substr(0, component.find(L'.'));
    std::transform(stem.begin(), stem.end(), stem.begin(),
        [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
    if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL" ||
        (stem.size() == 4 && (stem.compare(0, 3, L"COM") == 0 ||
        stem.compare(0, 3, L"LPT") == 0) && stem[3] >= L'1' && stem[3] <= L'9')) return false;
    if (end == std::wstring::npos) break;
    at = end + 1;
  }
  return true;
}

DWORD FinalPath(HANDLE handle, std::wstring* path) {
  const auto size = GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!size) return GetLastError();
  path->resize(size);
  const auto length = GetFinalPathNameByHandleW(handle, path->data(), size,
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!length) return GetLastError();
  if (length >= size) return ERROR_INSUFFICIENT_BUFFER;
  path->resize(length);
  while (!path->empty() && path->back() == L'\\') path->pop_back();
  return ERROR_SUCCESS;
}

DWORD LockDirectories(const std::wstring& path, size_t volume_end,
                      DirectoryLocks* locks, BY_HANDLE_FILE_INFORMATION* last) {
  // Lock from the volume/share root downwards, before resolving each next
  // component. OPEN_REPARSE_POINT checks the directory itself, not its target.
  for (size_t end = volume_end;;) {
    const auto component = path.substr(0, end);
    // Metadata-only handles do not establish sharing restrictions. LIST_DIRECTORY
    // establishes the no-delete lock for the entire operation.
    const auto handle = CreateFileW(component.c_str(), FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return GetLastError();
    locks->handles.push_back(handle);
    if (!GetFileInformationByHandle(handle, last)) return GetLastError();
    if (!(last->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (last->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
    locks->identities.push_back(*last);
    // The complete chain is rechecked before copying and before publication.
    if (end >= path.size()) break;
    end = path.find(L'\\', end + (path[end] == L'\\' ? 1 : 0));
    if (end == std::wstring::npos) end = path.size();
  }
  return ERROR_SUCCESS;
}

struct CopyProgress {
  std::atomic<bool>* closing;
  bool identified = false;
  BY_HANDLE_FILE_INFORMATION created{};
  static DWORD CALLBACK Update(LARGE_INTEGER, LARGE_INTEGER, LARGE_INTEGER,
      LARGE_INTEGER, DWORD, DWORD, HANDLE, HANDLE destination, LPVOID context) {
    auto state = static_cast<CopyProgress*>(context);
    if (!state->identified) state->identified =
        GetFileInformationByHandle(destination, &state->created) != FALSE;
    return state->closing->load() ? PROGRESS_CANCEL : PROGRESS_CONTINUE;
  }
};

void RemoveOwnPart(const std::wstring& path, const CopyProgress& progress) {
  if (!progress.identified) return;
  const auto handle = CreateFileW(path.c_str(), DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return;
  BY_HANDLE_FILE_INFORMATION current{};
  if (GetFileInformationByHandle(handle, &current) && SameFile(current, progress.created) &&
      !(current.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
    // CopyFileEx preserves source attributes, including READONLY.
    FILE_BASIC_INFO basic{};
    basic.FileAttributes = current.dwFileAttributes & ~FILE_ATTRIBUTE_READONLY;
    if (!basic.FileAttributes) basic.FileAttributes = FILE_ATTRIBUTE_NORMAL;
    SetFileInformationByHandle(handle, FileBasicInfo, &basic, sizeof(basic));
    FILE_DISPOSITION_INFO remove{TRUE};
    SetFileInformationByHandle(handle, FileDispositionInfo, &remove, sizeof(remove));
  }
  CloseHandle(handle);
}

DWORD CreateRelativeGuard(HANDLE parent, const std::wstring& name, HANDLE* guard) {
  // NtCreateFile and OBJECT_ATTRIBUTES.RootDirectory/OBJ_DONT_REPARSE are
  // documented SDK APIs. Only this private guard needs a handle-relative create:
  // a path-based create could follow a junction set using WRITE_ATTRIBUTES
  // between directory validation and creation, even with deny-write sharing.
  // https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntcreatefile
  // https://learn.microsoft.com/windows/win32/api/ntdef/ns-ntdef-_object_attributes
  if (name.empty() || name.size() > 32766 || name.find_first_of(L"\\/:") != std::wstring::npos)
    return ERROR_INVALID_NAME;
  const auto module = GetModuleHandleW(L"ntdll.dll");
  const auto address = module ? GetProcAddress(module, "NtCreateFile") : nullptr;
  if (!address) return ERROR_NOT_SUPPORTED;  // No path-based fallback.
  decltype(&::NtCreateFile) create;
  static_assert(sizeof(create) == sizeof(address));
  std::memcpy(&create, &address, sizeof(create));
  UNICODE_STRING filename{};
  filename.Buffer = const_cast<PWSTR>(name.c_str());
  filename.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
  filename.MaximumLength = filename.Length;
  OBJECT_ATTRIBUTES attributes{};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = parent;
  attributes.ObjectName = &filename;
  attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
  IO_STATUS_BLOCK io{};
  HANDLE created = nullptr;
  const auto status = create(&created, FILE_READ_DATA | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE,
      &attributes, &io, nullptr, FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY,
      FILE_SHARE_READ, FILE_CREATE, FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT |
      FILE_DELETE_ON_CLOSE | FILE_OPEN_REPARSE_POINT, nullptr, 0);
  if (status < 0) return ERROR_ACCESS_DENIED;
  if (!created || created == INVALID_HANDLE_VALUE || io.Information != FILE_CREATED) {
    if (created && created != INVALID_HANDLE_VALUE) CloseHandle(created);
    return ERROR_GEN_FAILURE;
  }
  *guard = created;
  return ERROR_SUCCESS;
}

DWORD CopyWithinRoot(const std::wstring& source, const std::wstring& destination,
                     const std::wstring& trusted_root, std::atomic<bool>* closing) {
  std::wstring root, target;
  size_t root_volume, target_volume;
  if (source.find(L'\0') != std::wstring::npos ||
      !AbsolutePath(trusted_root, &root, &root_volume) ||
      !AbsolutePath(destination, &target, &target_volume)) return ERROR_INVALID_NAME;
  const auto separator = target.find_last_of(L'\\');
  if (separator == std::wstring::npos || separator + 1 == target.size() ||
      separator < target_volume - 1) return ERROR_INVALID_NAME;
  auto parent = target.substr(0, separator);
  if (parent.size() < target_volume) parent.push_back(L'\\');
  DirectoryLocks root_locks, parent_locks;
  BY_HANDLE_FILE_INFORMATION root_info{}, parent_info{};
  auto error = LockDirectories(root, root_volume, &root_locks, &root_info);
  if (error) return error;
  error = LockDirectories(parent, target_volume, &parent_locks, &parent_info);
  if (error) return error;
  std::wstring canonical_root, canonical_parent;
  error = FinalPath(root_locks.handles.back(), &canonical_root);
  if (error) return error;
  error = FinalPath(parent_locks.handles.back(), &canonical_parent);
  if (error) return error;
  const bool within_path = EqualPath(canonical_root, canonical_parent) ||
      (canonical_parent.size() > canonical_root.size() &&
       canonical_parent[canonical_root.size()] == L'\\' &&
       EqualPath(canonical_root, canonical_parent.substr(0, canonical_root.size())));
  bool within_identity = false;
  for (auto handle : parent_locks.handles) {
    BY_HANDLE_FILE_INFORMATION information{};
    if (!GetFileInformationByHandle(handle, &information)) return GetLastError();
    within_identity = within_identity || SameFile(root_info, information);
  }
  // Identity closes case-sensitive-directory and short-name prefix ambiguities.
  if (!within_path || !within_identity) return ERROR_ACCESS_DENIED;
  error = root_locks.Validate();
  if (!error) error = parent_locks.Validate();
  if (error) return error;
  if (GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES) return ERROR_FILE_EXISTS;
  if (closing->load()) return ERROR_REQUEST_ABORTED;
  GUID identifier;
  const auto generated = CoCreateGuid(&identifier);
  if (FAILED(generated)) return ERROR_GEN_FAILURE;
  wchar_t unique[40];
  if (!StringFromGUID2(identifier, unique, 40)) return ERROR_GEN_FAILURE;
  const auto part_name = std::wstring(L".score-reader-import-") + unique + L".part";
  const auto part = parent + (parent.back() == L'\\' ? L"" : L"\\") + part_name;
  // Create in the actual pinned directory, without resolving its mutable path.
  // The retained guard keeps it nonempty until publication, preventing in-place
  // junction conversion. Every ancestor contains a no-delete-pinned child.
  ScopedHandle guard(INVALID_HANDLE_VALUE);
  error = CreateRelativeGuard(parent_locks.handles.back(), part_name + L".guard.part", &guard.value);
  if (error) return error;
  error = root_locks.Validate();
  if (!error) error = parent_locks.Validate();
  if (error) return error;
  if (closing->load()) return ERROR_REQUEST_ABORTED;
  CopyProgress progress{closing};
  const bool copied = CopyFileExW(source.c_str(), part.c_str(), CopyProgress::Update,
      &progress, nullptr, COPY_FILE_FAIL_IF_EXISTS) != FALSE;
  error = copied ? ERROR_SUCCESS : GetLastError();
  if (copied) {
    error = root_locks.Validate();
    if (!error) error = parent_locks.Validate();
    if (closing->load()) error = ERROR_REQUEST_ABORTED;
    if (!error && !MoveFileExW(part.c_str(), target.c_str(), 0)) {
      error = GetLastError();
      if (GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES) error = ERROR_FILE_EXISTS;
    }
  }
  if (error) RemoveOwnPart(part, progress);
  return error;
}
}

class FileDropTarget final : public IDropTarget {
 public:
  explicit FileDropTarget(std::function<void(HDROP)> receive)
      : receive_(std::move(receive)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
    *result = static_cast<IDropTarget*>(this); AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto count = InterlockedDecrement(&references_);
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                       DWORD* effect) override {
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    accepts_ = data && SUCCEEDED(data->QueryGetData(&format));
    *effect = accepts_ ? (*effect & DROPEFFECT_COPY) : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = accepts_ ? (*effect & DROPEFFECT_COPY) : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override { accepts_ = false; return S_OK; }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL,
                                  DWORD* effect) override {
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    if (!data || FAILED(data->GetData(&format, &medium))) {
      *effect = DROPEFFECT_NONE; return S_OK;
    }
    receive_(static_cast<HDROP>(medium.hGlobal));
    ReleaseStgMedium(&medium);
    *effect &= DROPEFFECT_COPY;
    accepts_ = false;
    return S_OK;
  }
 private:
  LONG references_ = 1;
  bool accepts_ = false;
  std::function<void(HDROP)> receive_;
};

ExternalFileImportBridge::ExternalFileImportBridge(
    flutter::BinaryMessenger* messenger, HWND window, HWND flutter_view)
    : window_(window), flutter_view_(flutter_view) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "score_reader/file_import", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (call.method_name() == "listPending") {
      flutter::EncodableList files;
      for (const auto& file : pending_) {
        const auto name = file.path.substr(file.path.find_last_of(L"\\/") + 1);
        files.emplace_back(Map{{Value("id"), Value(file.id)},
          {Value("path"), Value(Utf8FromUtf16(file.path.c_str()))},
          {Value("name"), Value(Utf8FromUtf16(name.c_str()))}});
      }
      result->Success(Value(files));
    } else if (call.method_name() == "ack") {
      const auto id = Argument(args, "id");
      pending_.erase(std::remove_if(pending_.begin(), pending_.end(),
          [&id](const auto& file) { return file.id == id; }), pending_.end());
      result->Success(Value(true));
    } else if (call.method_name() == "release") {
      result->Success(Value(true));  // Windows queue contains paths, no native copy.
    } else if (call.method_name() == "copyToNewFile") {
      const auto source = Wide(Argument(args, "sourcePath"));
      const auto destination = Wide(Argument(args, "destinationPath"));
      const bool restricted = args && args->find(Value("trustedRootPath")) != args->end();
      const auto trusted_root = Wide(Argument(args, "trustedRootPath"));
      if (source.empty() || destination.empty()) {
        result->Error("copy_failed", "Invalid file path"); return;
      }
      ReapFinishedCopies();
      auto finished = std::make_shared<std::atomic<bool>>(false);
      std::thread worker([this, source, destination, restricted, trusted_root, finished,
                          result = std::move(result)]() mutable {
        const auto progress = [](LARGE_INTEGER, LARGE_INTEGER, LARGE_INTEGER,
            LARGE_INTEGER, DWORD, DWORD, HANDLE, HANDLE, LPVOID context) -> DWORD {
          return static_cast<ExternalFileImportBridge*>(context)->closing_.load()
              ? PROGRESS_CANCEL : PROGRESS_CONTINUE;
        };
        DWORD error = ERROR_REQUEST_ABORTED;
        if (!closing_.load() && restricted) {
          error = CopyWithinRoot(source, destination, trusted_root, &closing_);
        } else if (!closing_.load()) {
          const bool copied = CopyFileExW(source.c_str(), destination.c_str(),
              progress, this, nullptr, COPY_FILE_FAIL_IF_EXISTS) != FALSE;
          error = copied ? ERROR_SUCCESS : GetLastError();
        }
        {
          std::lock_guard<std::mutex> lock(copies_mutex_);
          completed_copies_.push_back({std::move(result), error});
        }
        finished->store(true);
        PostMessage(window_, kCopyCompleted, 0, 0);
      });
      copy_jobs_.push_back({std::move(worker), std::move(finished)});
    } else { result->NotImplemented(); }
  });
  // OLE is required even though main already initializes apartment-threaded COM.
  ole_initialized_ = SUCCEEDED(OleInitialize(nullptr));
  if (ole_initialized_) {
    drop_target_ = new FileDropTarget([this](HDROP drop) { ReceiveDrop(drop); });
    window_registered_ = SUCCEEDED(RegisterDragDrop(window_, drop_target_));
    view_registered_ = SUCCEEDED(RegisterDragDrop(flutter_view_, drop_target_));
  }
  DragAcceptFiles(window_, TRUE);  // Fallback for non-OLE WM_DROPFILES senders.
}

ExternalFileImportBridge::~ExternalFileImportBridge() {
  closing_ = true;
  // MethodChannel destruction alone does not unregister its captured handler.
  channel_->SetMethodCallHandler(nullptr);
  for (auto& job : copy_jobs_) if (job.worker.joinable()) job.worker.join();
  CompleteCopies();
  DragAcceptFiles(window_, FALSE);
  if (view_registered_) RevokeDragDrop(flutter_view_);
  if (window_registered_) RevokeDragDrop(window_);
  if (drop_target_) drop_target_->Release();
  if (ole_initialized_) OleUninitialize();
}

void ExternalFileImportBridge::CompleteCopies() {
  ReapFinishedCopies();
  std::vector<CopyCompletion> copies;
  {
    std::lock_guard<std::mutex> lock(copies_mutex_);
    copies.swap(completed_copies_);
  }
  for (auto& copy : copies) {
    if (copy.error == ERROR_SUCCESS) copy.result->Success(Value(true));
    else copy.result->Error(copy.error == ERROR_FILE_EXISTS || copy.error == ERROR_ALREADY_EXISTS
        ? "already_exists" : "copy_failed", "Could not create a new copy");
  }
}

void ExternalFileImportBridge::ReapFinishedCopies() {
  copy_jobs_.erase(std::remove_if(copy_jobs_.begin(), copy_jobs_.end(),
      [](auto& job) {
        if (!job.finished->load()) return false;
        if (job.worker.joinable()) job.worker.join();
        return true;
      }), copy_jobs_.end());
}

void ExternalFileImportBridge::ReceiveDrop(HDROP drop) {
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    if (!length) continue;
    std::wstring path(length + 1, L'\0');
    DragQueryFileW(drop, index, path.data(), length + 1);
    path.resize(length);
    pending_.push_back({"win-" + std::to_string(GetTickCount64()) + "-" +
      std::to_string(++sequence_), std::move(path)});
  }
  channel_->InvokeMethod("pendingChanged", nullptr);
}
