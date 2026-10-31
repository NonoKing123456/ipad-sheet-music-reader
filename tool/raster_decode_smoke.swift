import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

@main
struct RasterDecodeSmoke {
  enum SmokeError: Error { case failed, arguments }
  static func currentRss() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }
  static func peakRss() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss) // Darwin reports bytes; Linux uses KiB.
  }
  static func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
  static func makeFixture(_ source: URL) throws {
    guard !FileManager.default.fileExists(atPath: source.path) else { throw SmokeError.arguments }
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try autoreleasepool {
      guard let context = CGContext(data: nil, width: 5954, height: 8929, bitsPerComponent: 8,
        bytesPerRow: 5954 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SmokeError.failed
      }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 5954, height: 8929))
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 100, y: 100, width: 5700, height: 8))
      guard let image = context.makeImage() else { throw SmokeError.failed }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw SmokeError.failed }
    }
    print("RASTER_FIXTURE source=5954x8929 synthetic=true separate_process=true")
  }
  static func decode(_ source: URL) throws {
    let files = FileManager.default
    let cache = files.temporaryDirectory.appendingPathComponent("raster-smoke-" + UUID().uuidString)
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: cache) }
    let original = try sha(source)
    let before = currentRss(), beforePeak = peakRss()
    var dimensions = [[String: Int]]()
    for target in [(1728,2592),(1901,2851),(2333,3499),(2828,4243)] {
      try autoreleasepool {
        let output = try RasterImageIO.prepare(path: source.path, width: target.0, height: target.1, directory: cache)
        guard let image = CGImageSourceCreateWithURL(output as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width * height <= 12_000_000,
          max(width,height) <= max(target.0,target.1) else { throw SmokeError.failed }
        dimensions.append(["width":width,"height":height,"pixels":width * height])
        try files.removeItem(at: output)
      }
    }
    let stats = RasterImageIO.metrics()
    let empty = try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).isEmpty
    guard stats.active == 0, stats.maximumActive == 1, stats.jobs == 4,
          empty, try sha(source) == original else { throw SmokeError.failed }
    let report: [String: Any] = ["marker":"RASTER_IMAGEIO_SMOKE", "source":[5954,8929],
      "shared_production_core":true,"fixture_generation_in_other_process":true,
      "before_rss_bytes":before,"before_peak_rss_bytes":beforePeak,"peak_rss_bytes":peakRss(),
      "ru_maxrss_units":"Darwin bytes","outputs":dimensions,"native_max_inflight":stats.maximumActive,
      "remaining_native_jobs":stats.active,"temporary_files_remaining":0,"original_unchanged":true,
      "interpretation":"macOS synthetic RSS only; not an iPad memory limit or Jetsam proof"]
    let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: encoded, as: UTF8.self))
  }
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw SmokeError.arguments }
    let source = URL(fileURLWithPath: arguments[2])
    switch arguments[1] {
      case "--make-fixture": try makeFixture(source)
      case "--decode": try decode(source)
      default: throw SmokeError.arguments
    }
  }
}
