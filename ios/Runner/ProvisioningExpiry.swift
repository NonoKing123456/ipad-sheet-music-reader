import Foundation

/// Best-effort display metadata from the profile accepted by the OS. This is
/// neither CMS signature verification nor a certificate/revocation check.
/// Apple's profile layout is not a stable API; unsupported layouts return nil.
enum ProvisioningExpiry {
  static let maximumBytes = 2 * 1024 * 1024

  static func bundledExpiration() -> Date? {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
    return expirationFromFile(url)
  }

  static func expirationFromFile(_ url: URL) -> Date? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var data = Data()
    do {
      // Bound the read itself, including a file that grows after an initial stat.
      while data.count <= maximumBytes {
        let count = min(64 * 1024, maximumBytes + 1 - data.count)
        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
          return expiration(in: data)
        }
        data.append(chunk)
      }
    } catch { return nil }
    return nil
  }

  static func expiration(in cms: Data) -> Date? {
    guard !cms.isEmpty, cms.count <= maximumBytes else { return nil }
    let der = ProfileDER(bytes: Array(cms))
    guard let root = der.single(in: 0..<cms.count), root.tag == 0x30,
          let outer = der.children(of: root, limit: 2), outer.count == 2,
          der.oid(outer[0], equals: [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x02]),
          outer[1].tag == 0xa0,
          let signed = der.single(in: outer[1].value), signed.tag == 0x30,
          let fields = der.children(of: signed, limit: 6), fields.count >= 4,
          fields[0].tag == 0x02, !fields[0].value.isEmpty,
          fields[1].tag == 0x31, fields[2].tag == 0x30 else { return nil }
    var tail = 3
    if tail < fields.count && fields[tail].tag == 0xa0 { tail += 1 }
    if tail < fields.count && fields[tail].tag == 0xa1 { tail += 1 }
    guard tail == fields.count - 1, fields[tail].tag == 0x31,
          let content = der.children(of: fields[2], limit: 2), content.count == 2,
          der.oid(content[0], equals: [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01]),
          content[1].tag == 0xa0,
          let octets = der.single(in: content[1].value), octets.tag == 0x04 else { return nil }
    let payload = Data(der.bytes[octets.value])
    guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
          let dictionary = plist as? [String: Any],
          let expiration = dictionary["ExpirationDate"] as? Date,
          expiration.timeIntervalSince1970.isFinite,
          expiration.timeIntervalSince1970 >= 0,
          expiration.timeIntervalSince1970 <= 253_402_300_799 else { return nil }
    return expiration
  }
}

/// Only the fixed ContentInfo -> SignedData -> eContent route is followed.
/// No recursive certificate walk or arbitrary XML scanning is performed.
private struct ProfileDER {
  struct Node { let tag: UInt8; let value: Range<Int> }
  let bytes: [UInt8]

  func read(_ cursor: inout Int, end: Int) -> Node? {
    guard cursor >= 0, cursor < end, end <= bytes.count else { return nil }
    let tag = bytes[cursor]
    cursor += 1
    guard tag & 0x1f != 0x1f, cursor < end else { return nil }
    let first = bytes[cursor]
    cursor += 1
    var length = Int(first)
    if first & 0x80 != 0 {
      let count = Int(first & 0x7f)
      // DER definite lengths only. Indefinite BER and huge lengths fail closed.
      guard count > 0, count <= 4, count <= end - cursor, bytes[cursor] != 0 else { return nil }
      length = 0
      for _ in 0..<count { length = length * 256 + Int(bytes[cursor]); cursor += 1 }
      guard length >= 128 else { return nil }
    }
    guard length <= end - cursor else { return nil }
    let value = cursor..<(cursor + length)
    cursor += length
    return Node(tag: tag, value: value)
  }

  func single(in range: Range<Int>) -> Node? {
    var cursor = range.lowerBound
    guard let node = read(&cursor, end: range.upperBound), cursor == range.upperBound else { return nil }
    return node
  }

  func children(of node: Node, limit: Int) -> [Node]? {
    var cursor = node.value.lowerBound
    var nodes: [Node] = []
    while cursor < node.value.upperBound {
      guard nodes.count < limit, let child = read(&cursor, end: node.value.upperBound) else { return nil }
      nodes.append(child)
    }
    return nodes
  }

  func oid(_ node: Node, equals expected: [UInt8]) -> Bool {
    node.tag == 0x06 && bytes[node.value].elementsEqual(expected)
  }
}

#if canImport(Flutter)
import Flutter

enum ProvisioningExpiryBridge {
  static func register(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "score_reader/signing_expiry", binaryMessenger: messenger)
    let queue = DispatchQueue(label: "score_reader.signing_expiry", qos: .utility)
    channel.setMethodCallHandler { call, result in
      guard call.method == "expiration" else { result(FlutterMethodNotImplemented); return }
      queue.async {
        let expiration = ProvisioningExpiry.bundledExpiration()
        let response: [String: Any]
        if let expiration = expiration {
          response = ["status": "known", "expirationMilliseconds": Int64(expiration.timeIntervalSince1970 * 1000)]
        } else { response = ["status": "unknown"] }
        DispatchQueue.main.async { result(response) }
      }
    }
    return channel
  }
}
#endif
