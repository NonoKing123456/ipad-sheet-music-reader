#include "external_file_import.h"

#include <ole2.h>
#include <algorithm>
#include <functional>
#include <utility>

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
      if (source.empty() || destination.empty()) {
        result->Error("copy_failed", "Invalid file path"); return;
      }
      ReapFinishedCopies();
      auto finished = std::make_shared<std::atomic<bool>>(false);
      std::thread worker([this, source, destination, finished, result = std::move(result)]() mutable {
        const auto progress = [](LARGE_INTEGER, LARGE_INTEGER, LARGE_INTEGER,
            LARGE_INTEGER, DWORD, DWORD, HANDLE, HANDLE, LPVOID context) -> DWORD {
          return static_cast<ExternalFileImportBridge*>(context)->closing_.load()
              ? PROGRESS_CANCEL : PROGRESS_CONTINUE;
        };
        DWORD error = ERROR_REQUEST_ABORTED;
        if (!closing_.load()) {
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
