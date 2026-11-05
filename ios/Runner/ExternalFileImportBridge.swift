import Foundation

/// A private, durable copy queue. All methods run on the bridge's serial worker.
/// The Foundation-only core is also exercised by file_import_smoke.swift.
final class ExternalFileInbox {
  struct ImportFailure: Error, Codable {
    let code: String
    let message: String
  }
  enum State: String, Codable { case receiving, ready, failed, acknowledged }
  struct Item: Codable {
    let id: String
    let name: String
    let fileExtension: String
    var byteCount: Int64 = 0
    let receivedAt: Int64
    var state: State = .receiving
    var error: ImportFailure?
    let sourceKey: String?
  }

  private let root: URL
  private let files = FileManager.default
  private var loaded = false
  private var items = [String: Item]()
  private static let extensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "webp"]
  private static let chunkSize = 256 * 1024

  init(root: URL) { self.root = root.standardizedFileURL }

  /// File bytes never cross the method channel or enter one whole-file Data.
  /// The source is read only; a unique directory prevents same-name overwrites.
  @discardableResult
  func receive(_ source: URL) throws -> Item? {
    try load()
    let attributes = try? files.attributesOfItem(atPath: source.path)
    let sourceKey = source.standardizedFileURL.absoluteString + "|"
      + String((attributes?[.size] as? NSNumber)?.int64Value ?? -1) + "|"
      + String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)
    // Flutter's cold-scene fallback can report the same delivery a second time.
    if items.values.contains(where: { $0.sourceKey == sourceKey && $0.state != .acknowledged }) {
      return nil
    }
    let id = UUID().uuidString
    var item = Item(id: id, name: source.lastPathComponent,
      fileExtension: source.pathExtension.lowercased(),
      receivedAt: Int64(Date().timeIntervalSince1970 * 1000), sourceKey: sourceKey)
    try files.createDirectory(at: directory(id), withIntermediateDirectories: false)
    // A killed copy becomes an explicit retryable failure on the next launch.
    try persist(item)
    items[id] = item
    do {
      guard source.isFileURL else {
        throw ImportFailure(code: "not_a_file", message: "只能接收本机曲谱文件。")
      }
      guard Self.extensions.contains(item.fileExtension) else {
        throw ImportFailure(code: "unsupported_type", message: "支持 PDF、JPG、PNG 和 WebP 曲谱文件。")
      }
      if let kind = attributes?[.type] as? FileAttributeType, kind != .typeRegular {
        throw ImportFailure(code: "not_a_file", message: "不能接收文件夹或文件链接，请选择曲谱文件。")
      }
      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
        do { item.byteCount = try self.copy(readable, to: self.partial(item)) }
        catch { copyError = error }
      }
      if let error = coordinationError { throw error }
      if let error = copyError { throw error }
      guard item.byteCount > 0 else {
        throw ImportFailure(code: "empty_file", message: "文件为空，请从原应用重新打开。")
      }
      try files.moveItem(at: partial(item), to: payload(item))
      item.state = .ready
    } catch {
      item.state = .failed
      item.error = (error as? ImportFailure) ?? ImportFailure(
        code: "copy_failed", message: "无法接收文件，请确认文件已下载后从原应用重新打开。")
      try? files.removeItem(at: partial(item))
    }
    try persist(item)
    items[id] = item
    return item
  }

  func listPending() throws -> [[String: Any]] {
    try load()
    var result = [[String: Any]]()
    for var item in items.values.sorted(by: {
      $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt
    }) where item.state != .acknowledged {
      if item.state == .ready && !files.fileExists(atPath: payload(item).path) {
        item.state = .failed
        item.error = ImportFailure(code: "missing_copy", message: "暂存文件已不可用，请从原应用重新打开。")
        try persist(item)
        items[item.id] = item
      }
      var value: [String: Any] = ["id": item.id, "name": item.name,
        "extension": item.fileExtension, "byteCount": item.state == .ready ? item.byteCount : 0,
        "receivedAt": item.receivedAt, "path": NSNull()]
      if item.state == .ready { value["path"] = payload(item).path }
      if let error = item.error { value["error"] = ["code": error.code, "message": error.message] }
      result.append(value)
    }
    return result
  }

  /// Dart calls only after its own durable draft is committed (or an error shown).
  /// Ack is durable before returning; a restart can safely reclaim this copy.
  func acknowledge(_ id: String) throws -> Bool {
    try validate(id)
    try load()
    guard var item = items[id] else { return true }
    guard item.state != .receiving else {
      throw ImportFailure(code: "import_busy", message: "文件仍在接收。")
    }
    if item.state == .acknowledged { return true }
    item.state = .acknowledged
    try persist(item)
    items[id] = item
    return true
  }

  /// Never accepts a caller-supplied path. Unacknowledged copies cannot be deleted.
  func release(_ id: String) throws -> Bool {
    try validate(id)
    try load()
    guard let item = items[id] else { return true }
    guard item.state == .acknowledged else {
      throw ImportFailure(code: "unacknowledged_import", message: "请先完成文件暂存。")
    }
    try removeDirectory(id)
    items.removeValue(forKey: id)
    return true
  }

  /// Final library save is exclusive: even a concurrent existing target survives.
  static func copyToNewFile(source: URL, destination: URL, sourceRoot: URL, destinationRoot: URL) throws {
    let files = FileManager.default
    let allowedInput = sourceRoot.standardizedFileURL
    let allowedOutput = destinationRoot.standardizedFileURL
    let input = source.standardizedFileURL.resolvingSymlinksInPath()
    let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let output = parent.appendingPathComponent(destination.lastPathComponent)
    let sourceAttributes = try? files.attributesOfItem(atPath: source.path)
    guard source.isFileURL, destination.isFileURL,
      input.path.hasPrefix(allowedInput.path + "/"),
      parent.path == allowedOutput.path || parent.path.hasPrefix(allowedOutput.path + "/"),
      output.path != input.path,
      (sourceAttributes?[.type] as? FileAttributeType) == .typeRegular else {
      throw ImportFailure(code: "invalid_copy_path", message: "只能保存应用内的暂存曲谱。")
    }
    do { try files.copyItem(at: input, to: output) }
    catch {
      let error = error as NSError
      if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
        throw ImportFailure(code: "already_exists", message: "同名文件已存在，请更换名称。")
      }
      throw ImportFailure(code: "copy_failed", message: "无法保存文件，暂存曲谱已保留。")
    }
  }

  private func copy(_ source: URL, to destination: URL) throws -> Int64 {
    let attributes = try files.attributesOfItem(atPath: source.path)
    guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
      throw ImportFailure(code: "not_a_file", message: "不能接收文件夹或文件链接，请选择曲谱文件。")
    }
    guard files.createFile(atPath: destination.path, contents: nil) else {
      throw ImportFailure(code: "copy_failed", message: "无法创建暂存文件。")
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var count: Int64 = 0
    while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
      try output.write(contentsOf: chunk)
      count += Int64(chunk.count)
    }
    try output.synchronize()
    return count
  }

  private func load() throws {
    guard !loaded else { return }
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var writableRoot = root
    try writableRoot.setResourceValues(excluded)
    for folder in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      let id = folder.lastPathComponent
      let folderAttributes = try? files.attributesOfItem(atPath: folder.path)
      guard (try? validate(id)) != nil,
        (folderAttributes?[.type] as? FileAttributeType) == .typeDirectory else { continue }
      let recordURL = folder.appendingPathComponent("record.json")
      let attributes = try? files.attributesOfItem(atPath: recordURL.path)
      let size = (attributes?[.type] as? FileAttributeType) == .typeRegular
        ? (attributes?[.size] as? NSNumber)?.intValue ?? 0 : 0
      var decoded = size > 0 && size <= 64 * 1024
        ? (try? JSONDecoder().decode(Item.self, from: Data(contentsOf: recordURL))) : nil
      if let value = decoded,
        value.id != id || (value.state == .ready && !Self.extensions.contains(value.fileExtension)) { decoded = nil }
      var item = decoded ?? Item(id: id, name: "未完成的外部曲谱", fileExtension: "",
        receivedAt: Int64(Date().timeIntervalSince1970 * 1000), sourceKey: nil)
      // Persisted fields never determine a filesystem path outside the UUID folder.
      if item.state == .acknowledged {
        try? removeDirectory(id)
        continue
      }
      if item.state == .receiving {
        item.state = .failed
        item.error = ImportFailure(code: "interrupted", message: "上次文件接收未完成，请从原应用重新打开。")
        try persist(item)
      }
      items[id] = item
    }
    loaded = true
  }

  private func validate(_ id: String) throws {
    guard UUID(uuidString: id)?.uuidString == id else {
      throw ImportFailure(code: "invalid_import_id", message: "无效的文件接收编号。")
    }
  }
  private func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
  private func payload(_ item: Item) -> URL { directory(item.id).appendingPathComponent("score." + item.fileExtension) }
  private func partial(_ item: Item) -> URL { directory(item.id).appendingPathComponent("receiving.part") }
  private func persist(_ item: Item) throws {
    try JSONEncoder().encode(item).write(to: directory(item.id).appendingPathComponent("record.json"), options: .atomic)
  }
  private func removeDirectory(_ id: String) throws {
    let folder = directory(id)
    guard files.fileExists(atPath: folder.path) else { return }
    let attributes = try files.attributesOfItem(atPath: folder.path)
    guard folder.deletingLastPathComponent() == root,
      (attributes[.type] as? FileAttributeType) == .typeDirectory else {
      throw ImportFailure(code: "invalid_import_id", message: "无效的暂存目录。")
    }
    try files.removeItem(at: folder)
  }
}

#if canImport(Flutter) && canImport(UIKit)
import Flutter
import UIKit

final class ExternalFileImportBridge: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = ExternalFileImportBridge()
  private let queue = DispatchQueue(label: "score_reader.file_import", qos: .userInitiated)
  private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  private lazy var inbox = ExternalFileInbox(root: support.appendingPathComponent("ExternalFileInbox", isDirectory: true))
  private var channel: FlutterMethodChannel?
  private var coldCapturedURLs = Set<String>()
  // Disk exhaustion cannot persist an error; still report it to the live UI.
  private var volatileFailures = [String: [String: Any]]()

  func register(registrar: FlutterPluginRegistrar) {
    registrar.addSceneDelegate(self)
    let channel = FlutterMethodChannel(name: "score_reader/file_import", binaryMessenger: registrar.messenger())
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  func captureColdStart(_ urls: [URL]) {
    coldCapturedURLs.formUnion(urls.filter { $0.isFileURL }.map { $0.absoluteString })
    receive(urls)
  }

  /// Claim file URLs only; leave every other URL to existing Flutter handlers.
  @discardableResult
  func receive(_ urls: [URL]) -> Bool {
    let urls = urls.filter { $0.isFileURL }
    guard !urls.isEmpty else { return false }
    // A normal switch back to the sender should not suspend an in-progress copy.
    // If iOS terminates it, the persisted receiving record reports interruption.
    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    let finishBackgroundTask = {
      if backgroundTask != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
      }
    }
    backgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "Receive score files", expirationHandler: finishBackgroundTask)
    for url in urls {
      let scoped = url.startAccessingSecurityScopedResource()
      queue.async {
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try self.inbox.receive(url) }
        catch {
          let id = UUID().uuidString
          self.volatileFailures[id] = ["id": id, "name": url.lastPathComponent,
            "extension": url.pathExtension.lowercased(), "byteCount": 0,
            "receivedAt": Int64(Date().timeIntervalSince1970 * 1000), "path": NSNull(),
            "error": ["code": "storage_failed", "message": "暂存空间不可用，请释放空间后从原应用重新打开。"]]
        }
        DispatchQueue.main.async { self.channel?.invokeMethod("pendingChanged", arguments: nil) }
      }
    }
    queue.async { DispatchQueue.main.async(execute: finishBackgroundTask) }
    return true
  }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    let urls = connectionOptions?.urlContexts.map { $0.url }.filter { $0.isFileURL } ?? []
    let remaining = urls.filter { coldCapturedURLs.remove($0.absoluteString) == nil }
    receive(remaining)
    return !urls.isEmpty
  }
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    receive(URLContexts.map { $0.url })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    queue.async {
      do {
        let value: Any
        switch call.method {
        case "listPending":
          value = try self.inbox.listPending() + Array(self.volatileFailures.values)
        case "ack", "release":
          guard let id = arguments["id"] as? String else {
            throw ExternalFileInbox.ImportFailure(code: "invalid_import_id", message: "缺少文件接收编号。")
          }
          if self.volatileFailures[id] != nil {
            self.volatileFailures.removeValue(forKey: id)
            value = true
          } else {
            if call.method == "ack" { value = try self.inbox.acknowledge(id) }
            else { value = try self.inbox.release(id) }
          }
        case "copyToNewFile":
          guard let source = arguments["sourcePath"] as? String,
            let destination = arguments["destinationPath"] as? String else {
            throw ExternalFileInbox.ImportFailure(code: "invalid_copy_path", message: "缺少保存路径。")
          }
          try ExternalFileInbox.copyToNewFile(source: URL(fileURLWithPath: source),
            destination: URL(fileURLWithPath: destination),
            sourceRoot: self.support.resolvingSymlinksInPath().appendingPathComponent("library/external-imports", isDirectory: true),
            destinationRoot: self.support.resolvingSymlinksInPath().appendingPathComponent("library/local-imports", isDirectory: true))
          value = true
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        let failure = (error as? ExternalFileInbox.ImportFailure) ?? ExternalFileInbox.ImportFailure(
          code: "import_queue_failed", message: "无法读取暂存曲谱，请稍后重试。")
        DispatchQueue.main.async { result(FlutterError(code: failure.code, message: failure.message, details: nil)) }
      }
    }
  }
}
#endif
