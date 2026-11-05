import Foundation

/// Synthetic files only; compile with the production Foundation queue core:
/// xcrun swiftc -swift-version 5 -parse-as-library ios/Runner/ExternalFileImportBridge.swift tool/file_import_smoke.swift -o "$RUNNER_TEMP/file-import-smoke"
@main enum FileImportSmoke {
  enum Failure: Error { case check(String) }
  static var checks = 0
  static func require(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw Failure.check(name) }
    checks += 1
  }
  static func rejects(_ code: String, _ operation: () throws -> Void) throws {
    do { try operation(); throw Failure.check("Expected " + code) }
    catch let error as ExternalFileInbox.ImportFailure { try require(error.code == code, code) }
  }
  static func main() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("file-import-smoke-" + UUID().uuidString)
      .standardizedFileURL.resolvingSymlinksInPath()
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("sender")
    let queueDirectory = root.appendingPathComponent("inbox")
    try files.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appendingPathComponent("同名曲谱.PDF")
    let synthetic = Data(repeating: 0x5a, count: 3 * 256 * 1024 + 17)
    try synthetic.write(to: source)
    let inbox = ExternalFileInbox(root: queueDirectory)
    guard let first = try inbox.receive(source) else { throw Failure.check("first receipt") }
    let pending = try inbox.listPending()
    try require(pending.count == 1, "receipt")
    try require(pending[0]["name"] as? String == "同名曲谱.PDF", "display name")
    try require(pending[0]["extension"] as? String == "pdf", "case insensitive extension")
    try require(pending[0]["byteCount"] as? Int64 == Int64(synthetic.count), "streamed byte count")
    let ownCopy = URL(fileURLWithPath: pending[0]["path"] as! String)
    try require(try Data(contentsOf: ownCopy) == synthetic, "complete streamed copy")
    try require(try Data(contentsOf: source) == synthetic, "source untouched")
    try require(try inbox.receive(source) == nil, "duplicate delivery")
    try rejects("unacknowledged_import") { _ = try inbox.release(first.id) }
    try require(files.fileExists(atPath: ownCopy.path), "unacknowledged copy retained")

    let restored = ExternalFileInbox(root: queueDirectory)
    try require(try restored.listPending().first?["path"] as? String == ownCopy.path, "restart queue")
    for invalid in ["../sender", source.path, "", "00000000-0000-0000-0000-00000000000/"] {
      try rejects("invalid_import_id") { _ = try restored.release(invalid) }
      try rejects("invalid_import_id") { _ = try restored.acknowledge(invalid) }
    }
    try require(files.fileExists(atPath: source.path), "invalid IDs cannot delete source")
    try require(try restored.acknowledge(first.id), "ack")
    try require(try restored.acknowledge(first.id), "ack idempotent")
    try require(try restored.listPending().isEmpty, "acked item leaves pending")
    try require(files.fileExists(atPath: ownCopy.path), "ack retains payload until release")
    let afterAckCrash = ExternalFileInbox(root: queueDirectory)
    try require(try afterAckCrash.listPending().isEmpty, "ack restart")
    try require(!files.fileExists(atPath: ownCopy.path), "ack-release crash cleanup")
    try require(try afterAckCrash.release(first.id), "release idempotent after recovery")

    let secondSource = sourceDirectory.appendingPathComponent("other/同名曲谱.pdf")
    try files.createDirectory(at: secondSource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: secondSource)
    guard let second = try afterAckCrash.receive(source),
      let third = try afterAckCrash.receive(secondSource) else { throw Failure.check("multiple receipt") }
    let multiple = try afterAckCrash.listPending()
    try require(multiple.count == 2, "multiple files")
    try require(Set(multiple.compactMap { $0["path"] as? String }).count == 2, "same name never overwrites")
    try require(try afterAckCrash.acknowledge(second.id), "second ack")
    try require(try afterAckCrash.release(second.id), "explicit release")
    try require(try afterAckCrash.release(second.id), "explicit release idempotent")

    // Recreate a killed copy using the production metadata schema.
    let record = queueDirectory.appendingPathComponent(third.id).appendingPathComponent("record.json")
    var interrupted = third
    interrupted.state = .receiving
    try JSONEncoder().encode(interrupted).write(to: record, options: .atomic)
    let afterCopyCrash = ExternalFileInbox(root: queueDirectory)
    let recovered = try afterCopyCrash.listPending()
    try require((recovered.first?["error"] as? [String: String])?["code"] == "interrupted", "interrupted copy reported")
    try require(recovered.first?["path"] is NSNull, "partial copy never offered")

    let unsupported = sourceDirectory.appendingPathComponent("unsupported.txt")
    try Data([1]).write(to: unsupported)
    _ = try afterCopyCrash.receive(unsupported)
    let directory = sourceDirectory.appendingPathComponent("folder.pdf")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try afterCopyCrash.receive(directory)
    let empty = sourceDirectory.appendingPathComponent("empty.png")
    try Data().write(to: empty)
    _ = try afterCopyCrash.receive(empty)
    let linked = sourceDirectory.appendingPathComponent("link.pdf")
    try files.createSymbolicLink(at: linked, withDestinationURL: source)
    _ = try afterCopyCrash.receive(linked)
    let errors = Set(try afterCopyCrash.listPending().compactMap {
      ($0["error"] as? [String: String])?["code"]
    })
    try require(errors.isSuperset(of: ["interrupted", "unsupported_type", "not_a_file", "empty_file"]), "per-file failures")
    try require(files.fileExists(atPath: directory.path), "source directory untouched")
    for ext in ["JPG", "jpeg", "PNG", "WebP"] {
      let image = sourceDirectory.appendingPathComponent("synthetic." + ext)
      try Data([7, 8, 9]).write(to: image)
      let imageItem = try afterCopyCrash.receive(image)
      try require(imageItem?.state == .ready && imageItem?.fileExtension == ext.lowercased(), "supported " + ext)
    }

    let drafts = root.appendingPathComponent("library/external-imports")
    let saved = root.appendingPathComponent("library/local-imports")
    try files.createDirectory(at: drafts, withIntermediateDirectories: true)
    try files.createDirectory(at: saved, withIntermediateDirectories: true)
    let draft = drafts.appendingPathComponent("source.pdf")
    let destination = saved.appendingPathComponent("saved.pdf")
    try synthetic.write(to: draft)
    func save(_ input: URL, _ output: URL) throws {
      try ExternalFileInbox.copyToNewFile(source: input, destination: output,
        sourceRoot: drafts, destinationRoot: saved)
    }
    try save(draft, destination)
    try require(try Data(contentsOf: destination) == synthetic, "exclusive library copy")
    try Data([9]).write(to: draft)
    try rejects("already_exists") { try save(draft, destination) }
    try require(try Data(contentsOf: destination) == synthetic, "existing target unchanged")
    try rejects("invalid_copy_path") { try save(source, saved.appendingPathComponent("outside-source.pdf")) }
    try rejects("invalid_copy_path") { try save(draft, root.appendingPathComponent("outside-target.pdf")) }
    try rejects("invalid_copy_path") { try save(draft, saved.appendingPathComponent("../../escape.pdf")) }
    let escape = saved.appendingPathComponent("escape")
    try files.createSymbolicLink(at: escape, withDestinationURL: sourceDirectory)
    try rejects("invalid_copy_path") { try save(draft, escape.appendingPathComponent("outside.pdf")) }
    let draftLink = drafts.appendingPathComponent("link.pdf")
    try files.createSymbolicLink(at: draftLink, withDestinationURL: source)
    try rejects("invalid_copy_path") { try save(draftLink, saved.appendingPathComponent("linked.pdf")) }
    try require(try Data(contentsOf: source) == synthetic, "all operations preserve source")
    print("FILE_IMPORT_SMOKE_OK checks=\(checks) stream_chunks=4 queue_restart=1 ack_release_recovery=1 interrupted=1 exclusive_copy=1")
  }
}
