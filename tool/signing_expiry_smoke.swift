import Foundation

/// Synthetic CMS containers only. No installed profile or signing identity is read.
@main
struct SigningExpirySmoke {
  enum Failure: Error { case check(String) }
  static var checks = 0

  static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw Failure.check(name) }
    checks += 1
  }

  static func tlv(_ tag: UInt8, _ payload: Data) -> Data {
    var result = Data([tag])
    if payload.count < 128 { result.append(UInt8(payload.count)) }
    else {
      var length = payload.count
      var encoded: [UInt8] = []
      while length > 0 { encoded.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
      result.append(0x80 | UInt8(encoded.count))
      result.append(contentsOf: encoded)
    }
    result.append(payload)
    return result
  }

  static let dataOID = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01])
  static let signedOID = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x02])

  static func cms(_ payload: Data) -> Data {
    let content = tlv(0x30, dataOID + tlv(0xa0, tlv(0x04, payload)))
    // Empty signer/digest sets deliberately make no cryptographic validity claim.
    let signed = tlv(0x30, Data([0x02,0x01,0x01,0x31,0x00]) + content + Data([0x31,0x00]))
    return tlv(0x30, signedOID + tlv(0xa0, signed))
  }

  static func main() throws {
    let expected = Date(timeIntervalSince1970: 1_800_000_000)
    let xml = try PropertyListSerialization.data(
      fromPropertyList: ["ExpirationDate": expected, "Synthetic": true], format: .xml, options: 0)
    let binaryDate = expected.addingTimeInterval(0.125)
    let binary = try PropertyListSerialization.data(
      fromPropertyList: ["ExpirationDate": binaryDate], format: .binary, options: 0)
    try require(ProvisioningExpiry.expiration(in: cms(xml)) == expected, "CMS XML date")
    try require(ProvisioningExpiry.expiration(in: cms(binary)) == binaryDate, "CMS binary date")
    let valid = cms(xml)
    try require(ProvisioningExpiry.expiration(in: Data(valid.dropLast())) == nil, "truncated CMS")
    try require(ProvisioningExpiry.expiration(in: valid + Data([0])) == nil, "trailing bytes")
    try require(ProvisioningExpiry.expiration(in: Data([0x30,0x80,0,0])) == nil, "indefinite BER")
    try require(ProvisioningExpiry.expiration(in: Data([0x30,0x84,0xff,0xff,0xff,0xff])) == nil, "unbounded length")
    try require(ProvisioningExpiry.expiration(in: xml) == nil, "raw plist is not CMS")
    let missing = try PropertyListSerialization.data(fromPropertyList: ["Synthetic": true], format: .xml, options: 0)
    try require(ProvisioningExpiry.expiration(in: cms(missing)) == nil, "missing date")
    let wrongType = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": "tomorrow"], format: .binary, options: 0)
    try require(ProvisioningExpiry.expiration(in: cms(wrongType)) == nil, "wrong date type")
    try require(ProvisioningExpiry.expiration(in: cms(Data("<plist><dict>broken".utf8))) == nil, "bad plist")
    try require(ProvisioningExpiry.expiration(in: cms(Data([0x30,0x01,0x00]))) == nil, "non-plist payload")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signing-expiry-smoke-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.mobileprovision")
    try valid.write(to: file)
    try require(ProvisioningExpiry.expirationFromFile(file) == expected, "bounded production file reader")
    let oversized = Data(repeating: 0, count: ProvisioningExpiry.maximumBytes + 1)
    try oversized.write(to: file)
    try require(ProvisioningExpiry.expirationFromFile(file) == nil, "file read cap")
    try require(ProvisioningExpiry.expiration(in: oversized) == nil, "parser input cap")
    try FileManager.default.removeItem(at: file)
    try require(ProvisioningExpiry.expirationFromFile(file) == nil, "missing file")
    print("SIGNING_EXPIRY_SMOKE checks=\(checks) passed=true XML=true binary=true truncated_rejected=true input_cap=\(ProvisioningExpiry.maximumBytes) real_profiles_read=0 signature_verification=false")
  }
}
