import Foundation

/// Compile with the actual schema in BackgroundDownloadBridge.swift, without
/// Flutter/UIKit. All fixtures below are synthetic v30 records, never app data.
@main enum BackgroundQueueSchemaSmoke {
  static func main() throws {
    typealias Schema = BackgroundTransferQueueSchema
    let namespace = String(repeating: "a", count: 64)
    let ids = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"]
    let item: [String: Any] = ["sourceId": "synthetic", "entryId": "fixture", "revisionId": "r1",
      "relativePath": "fixture.pdf", "length": 1, "format": "pdf",
      "hash": String(repeating: "b", count: 64), "missing": false]
    var oldJobs = [String: Any]()
    for (index, state) in ["running", "paused", "staged"].enumerated() {
      oldJobs[ids[index]] = ["id": ids[index], "namespace": namespace,
        "origin": "http://127.0.0.1:1", "token": "synthetic-not-a-credential",
        "original": item, "item": item, "prepare": true, "state": state,
        "phase": "object", "taskId": 100 + index, "attempts": 0, "usedResume": false]
    }
    let oldStore: [String: Any] = ["generation": "synthetic-generation", "jobs": oldJobs,
      "selections": [namespace: [["sourceId": "synthetic", "folder": "", "selected": true]]]]
    let decoded = try JSONDecoder().decode(Schema.Store.self, from: JSONSerialization.data(withJSONObject: oldStore))
    guard decoded.jobs.count == 3, Set(decoded.jobs.values.map { $0.state }) == Set(["running", "paused", "staged"]),
      decoded.jobs.values.allSatisfy({ $0.batchMembers == nil && $0.batchOwner == nil && $0.batchId == nil && $0.batchMask == nil && $0.batchPlanRetries == nil }),
      decoded.selections[namespace]?.count == 1 else { fatalError("Legacy store migration changed the durable plan") }
    let oldRecord: [String: Any] = ["generation": decoded.generation, "id": ids[0], "job": oldJobs[ids[0]]!]
    let record = try JSONDecoder().decode(Schema.Record.self, from: JSONSerialization.data(withJSONObject: oldRecord))
    guard record.id == ids[0], record.job?.state == "running", record.updates == nil, record.deleted == nil else {
      fatalError("Legacy journal record failed")
    }
    var batch = decoded.jobs[ids[0]]!
    batch.batchMembers = ids; batch.batchId = "synthetic-plan"; batch.batchMask = "8000000000000001"; batch.phase = "batch_object"
    var checkpoint = Schema.Record(generation: decoded.generation, id: "", job: nil)
    checkpoint.updates = [ids[0]: batch]; checkpoint.deleted = [ids[1]]
    let restored = try JSONDecoder().decode(Schema.Record.self, from: JSONEncoder().encode(checkpoint))
    guard restored.updates?[ids[0]]?.batchMembers == ids,
      restored.updates?[ids[0]]?.batchMask == "8000000000000001", restored.deleted == [ids[1]] else {
      fatalError("Batch checkpoint round trip failed")
    }
    print("BACKGROUND_QUEUE_SCHEMA_SMOKE_OK legacy_jobs=3 legacy_journal=1 batch_checkpoint=1")
  }
}
