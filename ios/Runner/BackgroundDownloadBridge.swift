import Foundation
import CryptoKit
import Flutter
import UIKit

/// One durable system session owns the entire selected batch, including the
/// existing prepare POSTs (file-backed uploads) and subsequent object GETs.
/// 'staged' is deliberately not 'success': Dart must verify and atomically
/// import through ReplicaCollectionView before acknowledging/removing a job.
final class BackgroundDownloadBridge: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate {
  static let shared = BackgroundDownloadBridge()
  static let identifier = "score_reader.offline.background.v1"
  private struct Item: Codable {
    var sourceId: String
    var entryId: String
    var revisionId: String
    var relativePath: String
    var length: Int64
    var format: String
    var hash: String?
    var missing: Bool
  }
  private struct Job: Codable {
    var id: String
    var namespace: String
    var origin: String
    var token: String
    var original: Item
    var item: Item
    var prepare: Bool
    var state: String = "queued"
    var phase: String = "prepare"
    var taskId: Int?
    var attempts: Int = 0
    var failure: String?
    var status: Int?
    var usedResume: Bool = false
  }
  private enum TransferError: Error { case invalid, storage, integrity }
  private struct SelectionRule: Codable {
    let sourceId: String
    let folder: String?
    let entryId: String?
    let selected: Bool
    func matches(_ item: Item) -> Bool {
      guard sourceId == item.sourceId else { return false }
      if entryId == item.entryId { return true }
      guard let folder = folder else { return false }
      return folder.isEmpty || item.relativePath == folder || item.relativePath.hasPrefix(folder + "/")
    }
  }
  private struct SelectionIndex {
    private struct Choice { let position: Int; let selected: Bool }
    private var entries = [String: [String: Choice]]()
    private var folders = [String: [String: Choice]]()
    init(_ rules: [SelectionRule]) {
      for (position, rule) in rules.enumerated() {
        let choice = Choice(position: position, selected: rule.selected)
        if let id = rule.entryId { entries[rule.sourceId, default: [:]][id] = choice }
        if let folder = rule.folder { folders[rule.sourceId, default: [:]][folder] = choice }
      }
    }
    func includes(_ item: Item) -> Bool {
      var result = entries[item.sourceId]?[item.entryId]
      var folder = item.relativePath
      while true {
        if let choice = folders[item.sourceId]?[folder], choice.position > (result?.position ?? -1) { result = choice }
        if folder.isEmpty { break }
        if let slash = folder.range(of: "/", options: .backwards) { folder = String(folder[..<slash.lowerBound]) }
        else { folder = "" }
      }
      return result?.selected ?? false
    }
  }
  private struct Store: Codable {
    let generation: String
    let jobs: [String: Job]
    let selections: [String: [SelectionRule]]
  }
  private struct Record: Codable { let generation: String; let id: String; let job: Job? }
  private let queue = DispatchQueue(label: "score_reader.background-download")
  private let files = FileManager.default
  private var jobs = [String: Job]()
  private var byNamespace = [String: [String: String]]()
  private var counts = [String: [String: Int]]()
  private var stagedIDs = [String: Set<String>]()
  private var generation = UUID().uuidString
  private var selections = [String: [SelectionRule]]()
  private var selectionIndexes = [String: SelectionIndex]()
  private var journalBytes = 0
  private var activeIDs = Set<String>()
  private var pendingIDs = [String]()
  private var priorityIDs = [String]()
  private var pendingSet = Set<String>()
  private var pendingOffset = 0
  private var filling = false
  private var storageBlocked = Set<String>()
  private var responseBytes = [Int: Data]()
  private var completionHandler: (() -> Void)?
  private var loaded = false
  private var starting = false
  private var waiting = [() -> Void]()
  private var channel: FlutterMethodChannel?
  private var protectionObserver: NSObjectProtocol?
  override init() {
    super.init()
    protectionObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self = self else { return }
      self.queue.async {
        if self.loaded && !self.storageAvailable {
          self.loaded = false; self.starting = false; self.start()
        }
      }
    }
  }
  private lazy var root: URL = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("score-reader-background", isDirectory: true)
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 7 * 24 * 60 * 60
    config.httpMaximumConnectionsPerHost = 3
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = queue
    return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
  }()

  func start() {
    queue.async {
      guard !self.loaded, !self.starting else { return }
      self.starting = true
      do {
        try self.files.createDirectory(at: self.root, withIntermediateDirectories: true,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try self.root.setResourceValues(resource)
        let state = self.root.appendingPathComponent("queue.json")
        if self.files.fileExists(atPath: state.path) {
          let store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: state))
          self.jobs = store.jobs; self.generation = store.generation; self.selections = store.selections
          try self.replayJournal()
          guard self.jobs.allSatisfy({ key, value in UUID(uuidString: key) != nil && value.id == key &&
            value.namespace.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && value.item.length >= 0
          }) else { throw TransferError.invalid }
        }
      } catch {
        // Keep an unreadable durable queue intact. No transfer may silently
        // overwrite it; commands fail until protected storage is accessible.
        self.finishLoading(storageAvailable: false)
        return
      }
      self.rebuildIndexes()
      self.storageBlocked = Set(self.jobs.values.filter { $0.state == "error" && $0.failure == "storage" }.map { $0.namespace })
      self.selectionIndexes = self.selections.mapValues { SelectionIndex($0) }
      self.session.getAllTasks { tasks in
        self.queue.async {
          var active = Set<String>()
          for task in tasks {
            guard let id = task.taskDescription, var job = self.jobs[id],
                  task.state != .completed, task.state != .canceling,
                  job.state != "paused", job.state != "error", job.state != "staged" else {
              task.cancel(); continue
            }
            if active.contains(id) { task.cancel(); continue }
            active.insert(id); self.activeIDs.insert(id); job.taskId = task.taskIdentifier
            job.state = "running"; self.put(job)
            task.resume()
          }
          for id in Array(self.jobs.keys) where !active.contains(id) {
            guard var job = self.jobs[id] else { continue }
            job.taskId = nil
            // Recheck only an uncommitted move/state-write crash window here.
            // Durable stages were already hashed and Dart checks them again;
            // avoid rehashing a whole large library during app launch.
            let stageExists = self.files.fileExists(atPath: self.path(id, "stage").path)
            if stageExists && (job.state == "staged" ||
               (try? self.verify(self.path(id, "stage"), job.item)) != nil) {
              job.state = "staged"
            } else if job.state != "paused" && job.state != "error" {
              job.state = "queued"
            }
            self.put(job)
          }
          self.finishLoading(storageAvailable: true)
          for id in Array(self.jobs.keys) where self.jobs[id]?.state == "queued" {
            self.queueJob(id)
          }
          self.fillWindow()
        }
      }
    }
  }
  private var storageAvailable = false
  private func put(_ job: Job) {
    if let old = jobs[job.id] {
      counts[old.namespace, default: [:]][old.state, default: 0] -= 1
      stagedIDs[old.namespace]?.remove(job.id)
    }
    jobs[job.id] = job
    byNamespace[job.namespace, default: [:]][job.original.entryId] = job.id
    counts[job.namespace, default: [:]][job.state, default: 0] += 1
    if job.state == "staged" { stagedIDs[job.namespace, default: []].insert(job.id) }
  }
  private func rebuildIndexes() {
    byNamespace.removeAll(); counts.removeAll(); stagedIDs.removeAll()
    for job in jobs.values {
      byNamespace[job.namespace, default: [:]][job.original.entryId] = job.id
      counts[job.namespace, default: [:]][job.state, default: 0] += 1
      if job.state == "staged" { stagedIDs[job.namespace, default: []].insert(job.id) }
    }
  }
  private func queueJob(_ id: String, priority: Bool = false) {
    if jobs[id]?.state == "queued", jobs[id]?.taskId == nil, pendingSet.insert(id).inserted {
      if priority { priorityIDs.append(id) } else { pendingIDs.append(id) }
    }
  }
  private func fillWindow() {
    guard !filling else { return }
    filling = true; defer { filling = false }
    while activeIDs.count < 6 && (!priorityIDs.isEmpty || pendingOffset < pendingIDs.count) {
      let id: String
      if let ready = priorityIDs.popLast() { id = ready }
      else { id = pendingIDs[pendingOffset]; pendingOffset += 1 }
      pendingSet.remove(id)
      schedule(id)
    }
    if pendingOffset > 1024 && pendingOffset > pendingIDs.count / 2 {
      pendingIDs = Array(pendingIDs.dropFirst(pendingOffset)); pendingOffset = 0
    }
  }
  private func finishLoading(storageAvailable: Bool) {
    self.storageAvailable = storageAvailable; loaded = true
    let commands = waiting; waiting.removeAll()
    commands.forEach { $0() }
  }
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "score_reader/background_download", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.queue.async {
        let command = {
          do {
            guard self.storageAvailable else { throw TransferError.storage }
            let output = try self.handle(call)
            DispatchQueue.main.async { result(output) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "background_storage", message: "Background queue unavailable", details: nil))
            }
          }
        }
        if self.loaded { command() } else { self.waiting.append(command) }
      }
    }
    start()
  }
  func handleEvents(completion: @escaping () -> Void) {
    queue.async { self.completionHandler = completion }
    start()
  }
  private func path(_ id: String, _ extensionName: String) -> URL {
    root.appendingPathComponent(id).appendingPathExtension(extensionName)
  }
  private func replayJournal() throws {
    let url = root.appendingPathComponent("queue.journal")
    guard files.fileExists(atPath: url.path) else { return }
    let data = try Data(contentsOf: url)
    var start = data.startIndex, valid = 0
    for end in data.indices where data[end] == 10 {
      guard end - start < 128 * 1024,
            let record = try? JSONDecoder().decode(Record.self, from: data[start..<end]) else { break }
      if record.generation == generation { jobs[record.id] = record.job }
      valid = end + 1; start = end + 1
    }
    // A process death during an append leaves only an uncommitted final line.
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(valid)); try handle.close()
    journalBytes = valid
  }
  private func save(_ id: String? = nil) throws {
    let journal = root.appendingPathComponent("queue.journal")
    if let id = id, journalBytes < 16 * 1024 * 1024 {
      var data = try JSONEncoder().encode(Record(generation: generation, id: id, job: jobs[id]))
      data.append(10)
      if !files.fileExists(atPath: journal.path) {
        try Data().write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      let handle = try FileHandle(forWritingTo: journal)
      defer { try? handle.close() }
      try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
      journalBytes += data.count
      return
    }
    let nextGeneration = UUID().uuidString
    let data = try JSONEncoder().encode(Store(generation: nextGeneration, jobs: jobs, selections: selections))
    try data.write(to: root.appendingPathComponent("queue.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    generation = nextGeneration
    // Generation makes a crash between snapshot replacement and journal
    // truncation safe: old records can never roll the new snapshot backwards.
    try Data().write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    journalBytes = 0
  }
  private func json(_ item: Item) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
  }
  private func snapshot(_ job: Job) throws -> [String: Any] {
    var value: [String: Any] = ["state": job.state, "item": try json(job.item)]
    value["requestedRevisionId"] = job.original.revisionId
    if job.state == "staged" { value["path"] = path(job.id, "stage").path }
    value["failure"] = job.failure; value["status"] = job.status
    return value
  }
  private func notifyChanged() {
    DispatchQueue.main.async { self.channel?.invokeMethod("changed", arguments: nil) }
  }
  private func handle(_ call: FlutterMethodCall) throws -> Any? {
    guard let args = call.arguments as? [String: Any],
          let namespace = args["namespace"] as? String,
          namespace.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw TransferError.invalid }
    if call.method == "enqueue" {
      guard let origin = args["origin"] as? String, let url = URL(string: origin),
            url.scheme == "http", url.host != nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
            let token = args["token"] as? String, !token.isEmpty,
            let prepare = args["prepare"] as? Bool, let raw = args["items"] as? [[String: Any]] else { throw TransferError.invalid }
      let items = try JSONDecoder().decode([Item].self, from: JSONSerialization.data(withJSONObject: raw))
      if let rules = args["selection"] as? [[String: Any]] {
        selections[namespace] = try JSONDecoder().decode([SelectionRule].self, from: JSONSerialization.data(withJSONObject: rules))
      } else { selections[namespace] = nil }
      selectionIndexes[namespace] = selections[namespace].map { SelectionIndex($0) }
      guard Set(items.map { $0.entryId }).count == items.count,
            items.allSatisfy({ $0.length >= 0 && !$0.missing }) else { throw TransferError.invalid }
      let incoming = Dictionary(uniqueKeysWithValues: items.map { ($0.entryId, $0) })
      for (entryId, id) in byNamespace[namespace] ?? [:] {
        guard let job = jobs[id] else { continue }
        if let item = incoming[entryId], item.revisionId == job.original.revisionId,
           item.sourceId == job.original.sourceId, item.hash == job.original.hash { continue }
        remove(id)
      }
      // Reserve both staged content and the replica's atomic import, plus a
      // small safety margin. Existing stages need only their import copy.
      var required: Int64 = 64 * 1024 * 1024
      for item in items {
        guard item.length < (Int64.max - required) / 2 else { throw TransferError.storage }
        let staged = (byNamespace[namespace]?[item.entryId]).flatMap { jobs[$0]?.state } == "staged"
        required += item.length * (staged ? 1 : 2)
      }
      if !items.isEmpty { try requireSpace(required) }
      storageBlocked.remove(namespace)
      for item in items {
        if let id = byNamespace[namespace]?[item.entryId] {
          guard var job = jobs[id] else { continue }
          job.token = token
          if job.state == "paused" || job.state == "error" {
            if job.state == "error", job.prepare {
              job.phase = "prepare"; job.item = job.original
              try? files.removeItem(at: path(id, "resume"))
            }
            job.state = "queued"; job.failure = nil; job.status = nil; job.attempts = 0
          }
          put(job)
        } else {
          let id = UUID().uuidString
          put(Job(id: id, namespace: namespace, origin: origin, token: token,
            original: item, item: item, prepare: prepare, phase: prepare ? "prepare" : "object"))
        }
      }
      try save()
      for item in items { if let id = byNamespace[namespace]?[item.entryId] { queueJob(id) } }
      fillWindow()
      notifyChanged()
      return nil
    }
    if call.method == "activity" {
      let values = counts[namespace] ?? [:]
      let held = storageBlocked.contains(namespace) ? (values["queued"] ?? 0) : 0
      return ["pending": (values["running"] ?? 0) + (values["queued"] ?? 0) - held,
        "staged": values["staged"] ?? 0, "failed": values["error"] ?? 0, "paused": (values["paused"] ?? 0) + held,
        "storageBlocked": storageBlocked.contains(namespace)] as [String: Any]
    }
    if call.method == "staged" {
      return try (stagedIDs[namespace] ?? []).prefix(32).compactMap { jobs[$0] }.map { try snapshot($0) }
    }
    if call.method == "pause" {
      for (id, stored) in Array(jobs) where stored.namespace == namespace && (stored.state == "running" || stored.state == "queued") {
        var job = stored
        job.state = "paused"; put(job)
        if job.taskId != nil { cancelTask(job, resume: true) }
      }
      try save(); notifyChanged(); return nil
    }
    if call.method == "resume" {
      storageBlocked.remove(namespace)
      for (id, stored) in Array(jobs) where stored.namespace == namespace &&
        (stored.state == "paused" || (stored.state == "error" && stored.failure == "storage")) {
        var job = stored
        job.state = "queued"; job.failure = nil; job.status = nil; job.attempts = 0; put(job)
      }
      try save()
      for id in (byNamespace[namespace] ?? [:]).values { queueJob(id) }
      fillWindow()
      notifyChanged(); return nil
    }
    if call.method == "discard" {
      for (id, job) in Array(jobs) where job.namespace == namespace { remove(id) }
      try save(); notifyChanged(); return nil
    }
    guard let entryId = args["entryId"] as? String else { throw TransferError.invalid }
    guard let id = byNamespace[namespace]?[entryId], let job = jobs[id] else {
      return ["state": "missing"]
    }
    if call.method == "status" {
      if job.state == "queued" && storageBlocked.contains(namespace) { return ["state": "error", "failure": "storage"] }
      return try snapshot(job)
    }
    if call.method == "acknowledge" { remove(job.id); try save(job.id); fillWindow(); notifyChanged(); return nil }
    throw TransferError.invalid
  }
  private func requireSpace(_ count: Int64) throws {
    let attributes = try files.attributesOfFileSystem(forPath: root.path)
    guard let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value > count else { throw TransferError.storage }
  }
  private func cancelTask(_ job: Job, resume: Bool) {
    session.getAllTasks { tasks in
      for task in tasks where task.taskDescription == job.id {
        if resume, let download = task as? URLSessionDownloadTask {
          download.cancel { data in
            self.queue.async {
              guard let current = self.jobs[job.id], current.taskId == job.taskId || current.state == "paused",
                    let data = data, !data.isEmpty else { return }
              try? data.write(to: self.path(job.id, "resume"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
          }
        } else { task.cancel() }
      }
    }
  }
  private func remove(_ id: String) {
    if let job = jobs.removeValue(forKey: id) {
      byNamespace[job.namespace]?[job.original.entryId] = nil
      counts[job.namespace, default: [:]][job.state, default: 0] -= 1
      stagedIDs[job.namespace]?.remove(id)
      activeIDs.remove(id)
      if job.taskId != nil { cancelTask(job, resume: false) }
    }
    for ext in ["stage", "resume", "request", "response"] { try? files.removeItem(at: path(id, ext)) }
  }
  private func schedule(_ id: String) {
    guard var job = jobs[id], job.taskId == nil, job.state == "queued", !storageBlocked.contains(job.namespace) else { return }
    do {
      guard let origin = URL(string: job.origin) else { throw TransferError.invalid }
      var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
      components.path = job.phase == "prepare" ? "/v2/prepare" : (job.prepare ? "/v2/object" : "/object")
      if job.phase == "object" {
        components.queryItems = [URLQueryItem(name: "entryId", value: job.item.entryId), URLQueryItem(name: "revisionId", value: job.item.revisionId)]
      }
      guard let url = components.url else { throw TransferError.invalid }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(job.token)", forHTTPHeaderField: "Authorization")
      let task: URLSessionTask
      if job.phase == "prepare" {
        try? files.removeItem(at: path(id, "response"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["entryId": job.original.entryId, "revisionId": job.original.revisionId])
        try body.write(to: path(id, "request"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        task = session.uploadTask(with: request, fromFile: path(id, "request"))
      } else if let resume = try? Data(contentsOf: path(id, "resume")), !resume.isEmpty {
        task = session.downloadTask(withResumeData: resume)
        job.usedResume = true
        try? files.removeItem(at: path(id, "resume"))
      } else {
        job.usedResume = false
        task = session.downloadTask(with: request)
      }
      task.taskDescription = id
      task.countOfBytesClientExpectsToReceive = job.phase == "prepare" ? 64 * 1024 : job.item.length
      job.taskId = task.taskIdentifier; job.state = "running"; put(job)
      activeIDs.insert(id)
      // Save mapping before resume; an OS termination can never orphan a task.
      do { try save(id) } catch { task.cancel(); throw error }
      task.resume()
    } catch { fail(id, "storage") }
  }
  private func fail(_ id: String, _ failure: String, status: Int? = nil) {
    guard var job = jobs[id], job.state != "paused" else { return }
    job.state = "error"; job.failure = failure; job.status = status; job.taskId = nil
    if failure == "storage" { storageBlocked.insert(job.namespace) }
    put(job); activeIDs.remove(id); try? save(id); fillWindow(); notifyChanged()
  }
  private func verify(_ file: URL, _ item: Item) throws {
    guard let expected = item.hash, expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          let size = try files.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
          size.int64Value == item.length else { throw TransferError.integrity }
    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
    var hash = SHA256()
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }; hash.update(data: data)
    }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw TransferError.integrity }
  }
  private func validResponse(_ task: URLSessionTask, _ job: Job) -> Bool {
    guard let response = task.response as? HTTPURLResponse, let url = response.url,
          let origin = URL(string: job.origin), url.scheme == origin.scheme,
          url.host == origin.host, url.port == origin.port,
          response.statusCode == 200 || (job.phase == "object" && response.statusCode == 206) else { return false }
    return true
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let id = dataTask.taskDescription, let job = jobs[id], job.taskId == dataTask.taskIdentifier, job.state == "running" else { return }
    var bytes = responseBytes[dataTask.taskIdentifier] ?? (try? Data(contentsOf: path(id, "response"))) ?? Data()
    guard bytes.count + data.count <= 64 * 1024 else { fail(id, "integrity"); dataTask.cancel(); return }
    bytes.append(data); responseBytes[dataTask.taskIdentifier] = bytes
    do {
      try bytes.write(to: path(id, "response"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch { fail(id, "storage"); dataTask.cancel() }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription, let job = jobs[id], job.taskId == downloadTask.taskIdentifier, job.state == "running" else { return }
    if totalBytesWritten > job.item.length || (totalBytesExpectedToWrite > job.item.length && totalBytesExpectedToWrite > 0) {
      fail(id, "integrity"); downloadTask.cancel()
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let id = downloadTask.taskDescription, var job = jobs[id], job.taskId == downloadTask.taskIdentifier, job.state == "running" else { return }
    guard validResponse(downloadTask, job) else {
      fail(id, "http", status: (downloadTask.response as? HTTPURLResponse)?.statusCode); return
    }
    do {
      try verify(location, job.item)
      let destination = path(id, "stage")
      try? files.removeItem(at: destination)
      try files.moveItem(at: location, to: destination)
      try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
      job.state = "staged"; job.taskId = nil; put(job)
      activeIDs.remove(id)
      try save(id)
      fillWindow()
      notifyChanged()
    } catch TransferError.integrity { fail(id, "integrity") }
      catch { fail(id, "storage") }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    defer { responseBytes.removeValue(forKey: task.taskIdentifier) }
    guard let id = task.taskDescription, var job = jobs[id], job.taskId == task.taskIdentifier else { return }
    if job.phase == "prepare" { try? files.removeItem(at: path(id, "request")) }
    job.taskId = nil; put(job); activeIDs.remove(id)
    if job.state == "paused" { try? save(id); fillWindow(); return }
    // The user can resume before cancellation finishes. Only the old task's
    // completion clears its ID; the queued replacement starts exactly once.
    if job.state == "queued" {
      if let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !resume.isEmpty {
        try? resume.write(to: path(id, "resume"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      try? save(id); queueJob(id, priority: true); fillWindow(); return
    }
    if let error = error as NSError? {
      if error.domain == NSCocoaErrorDomain || [NSURLErrorCannotCreateFile,
        NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile].contains(error.code) {
        fail(id, "storage"); return
      }
      if let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !resume.isEmpty {
        try? resume.write(to: path(id, "resume"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      let retryable = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorCancelled].contains(error.code) || job.usedResume
      if job.usedResume { try? files.removeItem(at: path(id, "resume")) }
      if retryable && job.attempts < 3 {
        job.attempts += 1; job.state = "queued"; put(job); try? save(id); queueJob(id, priority: true); fillWindow()
      } else { fail(id, "connection") }
      return
    }
    guard job.phase == "prepare" else { fail(id, "integrity"); return }
    guard validResponse(task, job) else { fail(id, "http", status: (task.response as? HTTPURLResponse)?.statusCode); return }
    do {
      let item = try JSONDecoder().decode(Item.self, from: responseBytes[task.taskIdentifier] ?? (try? Data(contentsOf: path(id, "response"))) ?? Data())
      guard item.entryId == job.original.entryId, item.sourceId == job.original.sourceId,
            item.length >= 0, item.length < (Int64.max - 64 * 1024 * 1024) / 2,
            !item.missing, item.hash != nil else { throw TransferError.integrity }
      if let selection = selectionIndexes[job.namespace] {
        // A prepare can resolve a file that moved outside its selected folder.
        // Preserve Dart's last-rule-wins scope before downloading any bytes.
        guard selection.includes(item) else { fail(id, "http", status: 404); return }
      }
      try requireSpace(item.length * 2 + 64 * 1024 * 1024)
      job.item = item; job.phase = "object"; job.state = "queued"; job.attempts = 0
      put(job); try save(id); queueJob(id, priority: true); fillWindow()
      try? files.removeItem(at: path(id, "response"))
    } catch TransferError.storage { fail(id, "storage") }
      catch { fail(id, "integrity") }
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // All file moves, validation and durable updates above finish on this same
    // serial delegate queue before UIKit is told the wake event is handled.
    let completion = completionHandler; completionHandler = nil
    DispatchQueue.main.async { completion?() }
  }
}
