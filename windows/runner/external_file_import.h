#ifndef RUNNER_EXTERNAL_FILE_IMPORT_H_
#define RUNNER_EXTERNAL_FILE_IMPORT_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <atomic>
#include <mutex>
#include <thread>
#include <string>
#include <vector>

class FileDropTarget;

// Native paths stay queued until Dart has durably copied the file and acks it.
class ExternalFileImportBridge {
 public:
  ExternalFileImportBridge(flutter::BinaryMessenger* messenger, HWND window,
                           HWND flutter_view);
  ~ExternalFileImportBridge();
  void ReceiveDrop(HDROP drop);
  static constexpr UINT kCopyCompleted = WM_APP + 46;
  void CompleteCopies();

 private:
  struct PendingFile { std::string id; std::wstring path; };
  HWND window_, flutter_view_;
  bool ole_initialized_ = false, window_registered_ = false,
       view_registered_ = false;
  FileDropTarget* drop_target_ = nullptr;
  unsigned long sequence_ = 0;
  std::vector<PendingFile> pending_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  struct CopyCompletion {
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
    DWORD error;
  };
  std::atomic<bool> closing_{false};
  struct CopyJob {
    std::thread worker;
    std::shared_ptr<std::atomic<bool>> finished;
  };
  void ReapFinishedCopies();
  std::vector<CopyJob> copy_jobs_;
  std::mutex copies_mutex_;
  std::vector<CopyCompletion> completed_copies_;
};

#endif
