import Foundation

/// Shared verbatim by the iOS bridge and the Foundation-only migration smoke.
enum BackgroundTransferQueueSchema {
  struct Item: Codable {
    var sourceId: String
    var entryId: String
    var revisionId: String
    var relativePath: String
    var length: Int64
    var format: String
    var hash: String?
    var missing: Bool
  }
  struct Job: Codable {
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
    var batchMembers: [String]?
    var batchOwner: String?
    var batchId: String?
    var batchMask: String?
    var batchPlanRetries: Int?
  }
  struct SelectionRule: Codable {
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
  struct Store: Codable {
    let generation: String
    let jobs: [String: Job]
    let selections: [String: [SelectionRule]]
  }
  struct Record: Codable {
    let generation: String; let id: String; let job: Job?
    var updates: [String: Job]? = nil
    var deleted: [String]? = nil
  }
}

#if canImport(Flutter) && canImport(UIKit)
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
  private typealias Item = BackgroundTransferQueueSchema.Item
  private typealias Job = BackgroundTransferQueueSchema.Job
  private typealias SelectionRule = BackgroundTransferQueueSchema.SelectionRule
  private typealias Store = BackgroundTransferQueueSchema.Store
  private typealias Record = BackgroundTransferQueueSchema.Record
  private enum TransferError: Error { case invalid, storage, integrity }
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
  private static let batchCount = 64
  private static let smallObjectBytes: Int64 = 256 * 1024
  private static let batchPayloadBytes: Int64 = 4 * 1024 * 1024
  private static let batchArchiveBytes: Int64 = 4 * 1024 * 1024 + 64 * (16 * 1024 + 8) + 8
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
            value.namespace.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && value.item.length >= 0 &&
            (value.batchMembers == nil || (!value.batchMembers!.isEmpty && value.batchMembers!.count <= Self.batchCount && Set(value.batchMembers!).count == value.batchMembers!.count))
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
          for id in Array(self.jobs.keys) {
            guard var job = self.jobs[id], let owner = job.batchOwner,
                  job.state != "staged", job.state != "paused",
                  self.jobs[owner] == nil || self.jobs[owner]?.state == "staged" else { continue }
            job.batchOwner = nil; job.phase = "prepare"; job.state = "queued"; self.put(job)
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
    if jobs[id]?.state == "queued", jobs[id]?.taskId == nil, jobs[id]?.batchOwner == nil, pendingSet.insert(id).inserted {
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
      guard end - start < 4 * 1024 * 1024,
            let record = try? JSONDecoder().decode(Record.self, from: data[start..<end]) else { break }
      if record.generation == generation {
        if let updates = record.updates {
          for (id, job) in updates { jobs[id] = job }
          for id in record.deleted ?? [] { jobs[id] = nil }
        } else { jobs[record.id] = record.job }
      }
      valid = end + 1; start = end + 1
    }
    // A process death during an append leaves only an uncommitted final line.
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(valid)); try handle.close()
    journalBytes = valid
  }
  private func save(_ id: String? = nil) throws {
    if let id = id { try saveMany([id]); return }
    try checkpoint()
  }
  private func saveMany(_ ids: [String]) throws {
    let journal = root.appendingPathComponent("queue.journal")
    if journalBytes < 16 * 1024 * 1024 {
      let updates = Dictionary(uniqueKeysWithValues: ids.compactMap { id in jobs[id].map { (id, $0) } })
      let deleted = ids.filter { jobs[$0] == nil }
      var record = Record(generation: generation, id: "", job: nil)
      record.updates = updates; record.deleted = deleted
      var data = try JSONEncoder().encode(record)
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
    try checkpoint()
  }
  private func checkpoint() throws {
    let journal = root.appendingPathComponent("queue.journal")
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
    if job.state == "staged", let owner = job.batchOwner ?? (job.batchMembers != nil ? job.id : nil) {
      value["batchKey"] = owner
    }
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
      // If one member was deselected or changed revision, dissolve its old
      // batch before pruning. No surviving member can depend on a removed
      // leader, and cancellation targets the old task ID, not its replacement.
      for id in (byNamespace[namespace] ?? [:]).values {
        guard let leader = jobs[id], let members = leader.batchMembers else { continue }
        let unchanged = members.allSatisfy { memberId in
          guard let old = jobs[memberId], let item = incoming[old.original.entryId] else { return false }
          return item.revisionId == old.original.revisionId && item.sourceId == old.original.sourceId && item.hash == old.original.hash
        }
        if unchanged { continue }
        if leader.taskId != nil { cancelTask(leader, resume: false) }
        activeIDs.remove(id)
        for memberId in members {
          guard var member = jobs[memberId] else { continue }
          member.batchMembers = nil; member.batchOwner = nil; member.batchId = nil; member.batchMask = nil
          member.taskId = nil
          if member.state != "staged" { member.state = "queued"; member.phase = "prepare" }
          put(member)
        }
      }
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
              job.phase = job.batchMembers != nil ? "batch_prepare" : job.batchOwner != nil ? "batch_wait" : "prepare"
              job.item = job.original
              try? files.removeItem(at: path(id, "resume"))
            }
            job.state = "queued"; job.failure = nil; job.status = nil; job.attempts = 0
            job.batchPlanRetries = 0
          }
          put(job)
        } else {
          let id = UUID().uuidString
          put(Job(id: id, namespace: namespace, origin: origin, token: token,
            original: item, item: item, prepare: prepare, phase: prepare ? "prepare" : "object"))
        }
      }
      repairOrphanedBatchMembers(namespace)
      if prepare && args["smallFileBatches"] as? Bool == true {
        formSmallBatches(namespace, items.compactMap { byNamespace[namespace]?[$0.entryId] })
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
      if let rules = args["selection"] as? [[String: Any]] {
        selections[namespace] = try JSONDecoder().decode([SelectionRule].self, from: JSONSerialization.data(withJSONObject: rules))
        selectionIndexes[namespace] = selections[namespace].map { SelectionIndex($0) }
      }
      storageBlocked.remove(namespace)
      for (id, stored) in Array(jobs) where stored.namespace == namespace &&
        (stored.state == "paused" || (stored.state == "error" && stored.failure == "storage")) {
        var job = stored
        if job.phase == "batch_object" {
          job.phase = "batch_prepare"; job.batchId = nil; job.batchMask = nil
          try? files.removeItem(at: path(id, "resume"))
        }
        job.state = "queued"; job.failure = nil; job.status = nil; job.attempts = 0; put(job)
      }
      repairOrphanedBatchMembers(namespace)
      try save()
      for id in (byNamespace[namespace] ?? [:]).values { queueJob(id) }
      fillWindow()
      notifyChanged(); return nil
    }
    if call.method == "discard" {
      for (id, job) in Array(jobs) where job.namespace == namespace { remove(id) }
      try save(); notifyChanged(); return nil
    }
    if call.method == "acknowledgeMany" {
      guard let entries = args["entryIds"] as? [String], entries.count <= Self.batchCount,
        Set(entries).count == entries.count else { throw TransferError.invalid }
      let ids = entries.compactMap { byNamespace[namespace]?[$0] }
      for id in ids { remove(id) }
      try saveMany(ids); fillWindow(); notifyChanged(); return nil
    }
    guard let entryId = args["entryId"] as? String else { throw TransferError.invalid }
    guard let id = byNamespace[namespace]?[entryId], let job = jobs[id] else {
      return ["state": "missing"]
    }
    if call.method == "batchMetadata" {
      let owner = job.batchOwner ?? job.id
      return try (jobs[owner]?.batchMembers ?? []).compactMap { jobs[$0] }
        .filter { $0.state == "staged" }.map { try json($0.item) }
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
  private func formSmallBatches(_ namespace: String, _ ids: [String]) {
    var group = [String](), bytes: Int64 = 0
    func finish() {
      if group.count > 1, let first = group.first, var leader = jobs[first] {
        leader.batchMembers = group; leader.phase = "batch_prepare"; put(leader)
        for id in group.dropFirst() {
          guard var member = jobs[id] else { continue }
          member.batchOwner = first; member.phase = "batch_wait"; put(member)
        }
      }
      group.removeAll(keepingCapacity: true); bytes = 0
    }
    for id in ids {
      guard let job = jobs[id], job.namespace == namespace, job.prepare,
        job.state == "queued", job.phase == "prepare", job.batchOwner == nil,
        job.batchMembers == nil, job.original.length <= Self.smallObjectBytes else { continue }
      if group.count == Self.batchCount || bytes + job.original.length > Self.batchPayloadBytes { finish() }
      group.append(id); bytes += job.original.length
    }
    finish()
  }
  private func repairOrphanedBatchMembers(_ namespace: String) {
    for id in (byNamespace[namespace] ?? [:]).values {
      guard var member = jobs[id], member.state != "staged", member.state != "paused",
        let owner = member.batchOwner, jobs[owner] == nil || jobs[owner]?.state == "staged" else { continue }
      member.batchOwner = nil; member.batchMembers = nil; member.phase = "prepare"
      member.state = "queued"; member.taskId = nil; put(member)
    }
  }
  private func fallbackBatch(_ leader: Job) {
    let ids = leader.batchMembers ?? [leader.id]
    for id in ids {
      guard var job = jobs[id], job.state != "staged" else { continue }
      job.batchMembers = nil; job.batchOwner = nil; job.batchId = nil; job.batchMask = nil
      job.phase = "prepare"; job.state = "queued"; job.taskId = nil
      job.failure = nil; job.status = nil; put(job)
    }
    activeIDs.remove(leader.id)
    try? saveMany(ids)
    for id in ids { queueJob(id, priority: true) }
    fillWindow(); notifyChanged()
  }
  private func cancelTask(_ job: Job, resume: Bool) {
    session.getAllTasks { tasks in
      for task in tasks where task.taskDescription == job.id && task.taskIdentifier == job.taskId {
        if resume, let download = task as? URLSessionDownloadTask {
          download.cancel { data in
            self.queue.async {
              guard let current = self.jobs[job.id], current.taskId == job.taskId || current.state == "paused",
                    current.phase != "batch_prepare",
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
    if job.phase == "object", let selection = selectionIndexes[job.namespace], !selection.includes(job.item) {
      fail(id, "http", status: 404); return
    }
    do {
      guard let origin = URL(string: job.origin) else { throw TransferError.invalid }
      var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
      components.path = job.phase == "batch_prepare" ? "/v2/batch-prepare" :
        job.phase == "batch_object" ? "/v2/batch-object" :
        job.phase == "prepare" ? "/v2/prepare" : (job.prepare ? "/v2/object" : "/object")
      if job.phase == "batch_object" {
        components.queryItems = [URLQueryItem(name: "batchId", value: job.batchId), URLQueryItem(name: "mask", value: job.batchMask)]
      }
      if job.phase == "object" {
        components.queryItems = [URLQueryItem(name: "entryId", value: job.item.entryId), URLQueryItem(name: "revisionId", value: job.item.revisionId)]
      }
      guard let url = components.url else { throw TransferError.invalid }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(job.token)", forHTTPHeaderField: "Authorization")
      let task: URLSessionTask
      if job.phase == "prepare" || job.phase == "batch_prepare" {
        try? files.removeItem(at: path(id, "response"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: Data
        if job.phase == "batch_prepare", let members = job.batchMembers {
          let items = try members.map { id -> [String: Any] in
            guard let member = jobs[id] else { throw TransferError.invalid }
            return ["sourceId": member.original.sourceId, "entryId": member.original.entryId, "revisionId": member.original.revisionId]
          }
          body = try JSONSerialization.data(withJSONObject: ["items": items])
        } else {
          body = try JSONSerialization.data(withJSONObject: ["entryId": job.original.entryId, "revisionId": job.original.revisionId])
        }
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
      task.countOfBytesClientExpectsToReceive = job.phase == "batch_prepare" ? 1024 * 1024 :
        job.phase == "batch_object" ? Self.batchArchiveBytes : job.phase == "prepare" ? 64 * 1024 : job.item.length
      job.taskId = task.taskIdentifier; job.state = "running"; put(job)
      activeIDs.insert(id)
      // Save mapping before resume; an OS termination can never orphan a task.
      do { try save(id) } catch { task.cancel(); throw error }
      task.resume()
    } catch { fail(id, "storage") }
  }
  private func fail(_ id: String, _ failure: String, status: Int? = nil) {
    guard var job = jobs[id], job.state != "paused" else { return }
    if let members = job.batchMembers {
      for memberId in members {
        guard var member = jobs[memberId], member.state != "staged", member.state != "paused" else { continue }
        member.state = "error"; member.failure = failure; member.status = status; member.taskId = nil; put(member)
      }
      if failure == "storage" { storageBlocked.insert(job.namespace) }
      activeIDs.remove(id); try? saveMany(members); fillWindow(); notifyChanged(); return
    }
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
  private func sameItem(_ a: Item, _ b: Item) -> Bool {
    a.entryId == b.entryId && a.sourceId == b.sourceId && a.revisionId == b.revisionId &&
      a.relativePath == b.relativePath && a.length == b.length && a.hash == b.hash &&
      a.format == b.format && a.missing == b.missing
  }
  private func prepareBatch(_ leader: Job, _ data: Data) throws {
    guard let ids = leader.batchMembers, !ids.isEmpty, ids.count <= Self.batchCount, Set(ids).count == ids.count,
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      body["protocol"] as? Int == 1, let token = body["batchId"] as? String,
      !token.isEmpty, token.utf8.count <= 128,
      let results = body["items"] as? [[String: Any]], results.count == ids.count else { throw TransferError.integrity }
    var mask: UInt64 = 0, total: Int64 = 0
    for (index, id) in ids.enumerated() {
      guard var member = jobs[id], results[index]["index"] as? Int == index,
        results[index]["entryId"] as? String == member.original.entryId else { throw TransferError.integrity }
      guard results[index]["status"] as? Int == 200, let raw = results[index]["item"] else { continue }
      guard let item = try? JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: raw)) else { throw TransferError.integrity }
      guard item.entryId == member.original.entryId, item.sourceId == member.original.sourceId,
        item.revisionId == member.original.revisionId, !item.missing, item.hash != nil,
        item.length >= 0, item.length <= Self.smallObjectBytes else { throw TransferError.integrity }
      if let selection = selectionIndexes[leader.namespace], !selection.includes(item) { continue }
      total += item.length
      guard total <= Self.batchPayloadBytes else { throw TransferError.integrity }
      mask |= UInt64(1) << index; member.item = item; put(member)
    }
    guard mask != 0 else { fallbackBatch(leader); return }
    guard var updated = jobs[leader.id] else { throw TransferError.integrity }
    updated.batchId = token; updated.batchMask = String(mask, radix: 16)
    updated.phase = "batch_object"; updated.state = "queued"; updated.taskId = nil; updated.attempts = 0
    put(updated); try saveMany(ids); queueJob(leader.id, priority: true); fillWindow()
  }
  private func readExact(_ handle: FileHandle, _ length: Int) throws -> Data {
    guard length >= 0, length <= Int(Self.smallObjectBytes) else { throw TransferError.integrity }
    var data = Data()
    while data.count < length {
      guard let chunk = try handle.read(upToCount: length - data.count), !chunk.isEmpty else { throw TransferError.integrity }
      data.append(chunk)
    }
    return data
  }
  private func word(_ data: Data, _ offset: Int = 0) -> Int {
    data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
  }
  private func unpackBatch(_ leader: Job, _ location: URL) throws {
    guard let ids = leader.batchMembers, !ids.isEmpty, ids.count <= Self.batchCount, Set(ids).count == ids.count,
      let maskText = leader.batchMask,
      let mask = UInt64(maskText, radix: 16),
      let size = try files.attributesOfItem(atPath: location.path)[.size] as? NSNumber,
      size.int64Value <= Self.batchArchiveBytes else { throw TransferError.integrity }
    var expected = [String: String]()
    for (index, id) in ids.enumerated() where (mask & (UInt64(1) << index)) != 0 {
      guard let member = jobs[id] else { throw TransferError.integrity }
      expected[member.item.entryId] = id
    }
    let handle = try FileHandle(forReadingFrom: location); defer { try? handle.close() }
    guard try readExact(handle, 4) == Data([83, 82, 66, 49]),
      word(try readExact(handle, 4)) == expected.count else { throw TransferError.integrity }
    var seen = Set<String>(), total = 0
    for _ in 0..<expected.count {
      let prefix = try readExact(handle, 8), headerLength = word(prefix), length = word(prefix, 4)
      guard headerLength > 0, headerLength <= 16 * 1024, length <= Int(Self.smallObjectBytes),
        total + length <= Int(Self.batchPayloadBytes) else { throw TransferError.integrity }
      let raw = try readExact(handle, headerLength)
      guard let header = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
        let entryId = header["entryId"] as? String, let id = expected[entryId], var member = jobs[id],
        seen.insert(id).inserted, header["sourceId"] as? String == member.item.sourceId,
        header["revisionId"] as? String == member.item.revisionId else { throw TransferError.integrity }
      let bytes = try readExact(handle, length); total += length
      guard header["status"] as? Int == 200 else {
        if length != 0 { throw TransferError.integrity }; continue
      }
      guard let value = header["item"] else { throw TransferError.integrity }
      guard let item = try? JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: value)) else { throw TransferError.integrity }
      guard sameItem(item, member.item) else { throw TransferError.integrity }
      // A corrupt member never invalidates following well-framed objects.
      if bytes.count != Int(item.length) || SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() != item.hash { continue }
      if let selection = selectionIndexes[member.namespace], !selection.includes(item) { continue }
      try bytes.write(to: path(id, "stage"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      member.state = "staged"; member.taskId = nil; put(member)
    }
    guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw TransferError.integrity }
    activeIDs.remove(leader.id)
    let staged = ids.filter { jobs[$0]?.state == "staged" }
    let stageOwner = staged.first
    for id in ids {
      guard var member = jobs[id] else { continue }
      member.batchOwner = member.state == "staged" && id != stageOwner ? stageOwner : nil
      member.batchMembers = id == stageOwner ? staged : nil
      member.batchId = nil; member.batchMask = nil
      member.taskId = nil
      if member.state != "staged" { member.phase = "prepare"; member.state = "queued" }
      put(member)
    }
    // One durable record and fsync covers all <=64 per-file stage transitions.
    try saveMany(ids)
    for id in ids { queueJob(id, priority: true) }
    fillWindow(); notifyChanged()
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
    let limit = job.phase == "batch_prepare" ? 1024 * 1024 : 64 * 1024
    guard bytes.count + data.count <= limit else { fail(id, "integrity"); dataTask.cancel(); return }
    bytes.append(data); responseBytes[dataTask.taskIdentifier] = bytes
    do {
      try bytes.write(to: path(id, "response"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch { fail(id, "storage"); dataTask.cancel() }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription, let job = jobs[id], job.taskId == downloadTask.taskIdentifier, job.state == "running" else { return }
    let limit = job.phase == "batch_object" ? Self.batchArchiveBytes : job.item.length
    if totalBytesWritten > limit || (totalBytesExpectedToWrite > limit && totalBytesExpectedToWrite > 0) {
      fail(id, "integrity"); downloadTask.cancel()
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let id = downloadTask.taskDescription, var job = jobs[id], job.taskId == downloadTask.taskIdentifier, job.state == "running" else { return }
    if job.phase == "batch_object", let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
       (status == 404 || status == 410), (job.batchPlanRetries ?? 0) < 2 {
      job.taskId = nil; job.phase = "batch_prepare"; job.state = "queued"; job.attempts += 1
      job.batchId = nil; job.batchMask = nil; put(job); activeIDs.remove(id)
      job.batchPlanRetries = (job.batchPlanRetries ?? 0) + 1; put(job)
      try? files.removeItem(at: path(id, "resume")); try? save(id); queueJob(id, priority: true); fillWindow(); return
    }
    guard validResponse(downloadTask, job) else {
      fail(id, "http", status: (downloadTask.response as? HTTPURLResponse)?.statusCode); return
    }
    do {
      if job.phase == "batch_object" {
        do { try unpackBatch(job, location) }
        catch TransferError.integrity { fallbackBatch(job) }
        return
      }
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
    if job.phase == "prepare" || job.phase == "batch_prepare" { try? files.removeItem(at: path(id, "request")) }
    job.taskId = nil; put(job); activeIDs.remove(id)
    if job.state == "paused" { try? save(id); fillWindow(); return }
    // The user can resume before cancellation finishes. Only the old task's
    // completion clears its ID; the queued replacement starts exactly once.
    if job.state == "queued" {
      if job.phase != "batch_prepare", let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !resume.isEmpty {
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
    if job.phase == "batch_prepare", (task.response as? HTTPURLResponse)?.statusCode == 404 { fallbackBatch(job); return }
    guard job.phase == "prepare" || job.phase == "batch_prepare" else { fail(id, "integrity"); return }
    guard validResponse(task, job) else { fail(id, "http", status: (task.response as? HTTPURLResponse)?.statusCode); return }
    do {
      if job.phase == "batch_prepare" {
        try prepareBatch(job, responseBytes[task.taskIdentifier] ?? (try? Data(contentsOf: path(id, "response"))) ?? Data())
        try? files.removeItem(at: path(id, "response")); return
      }
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

#endif
