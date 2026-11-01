import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(Flutter)
import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var scannerChannel: FlutterMethodChannel?
  private var rasterChannel: FlutterMethodChannel?
  private var readerActivityChannel: FlutterMethodChannel?
  private var signingExpiryChannel: FlutterMethodChannel?
  private var scanPending = false
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    BackgroundDownloadBridge.shared.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void) {
    if identifier == BackgroundDownloadBridge.identifier {
      BackgroundDownloadBridge.shared.handleEvents(completion: completionHandler)
    } else {
      super.application(application, handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    BackgroundDownloadBridge.shared.register(messenger: engineBridge.applicationRegistrar.messenger())
    signingExpiryChannel = ProvisioningExpiryBridge.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    let raster = FlutterMethodChannel(
      name: "score_reader/raster_decode",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    rasterChannel = raster
    raster.setMethodCallHandler { call, result in
      RasterDecodeBridge.shared.handle(call, result: result)
    }

    let activity = FlutterMethodChannel(
      name: "score_reader/reader_activity",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    readerActivityChannel = activity
    activity.setMethodCallHandler { call, result in
      ReaderWakeBridge.shared.handle(call, result: result)
    }

    let channel = FlutterMethodChannel(
      name: "score_reader/pairing_scanner",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    scannerChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "scan" else { result(FlutterMethodNotImplemented); return }
      guard let self = self, !self.scanPending else {
        result(FlutterError(code: "busy", message: "相机已打开，请先完成或取消扫码。", details: nil))
        return
      }
      self.scanPending = true
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          guard granted else {
            self.scanPending = false
            result(FlutterError(code: "camera_permission", message: "请在iPad设置中允许曲谱阅读器访问相机，然后重新扫码。", details: nil))
            return
          }
          let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
          guard var presenter = root else {
            self.scanPending = false
            result(FlutterError(code: "no_window", message: "请返回阅读器首页后重试扫码。", details: nil))
            return
          }
          while let presented = presenter.presentedViewController { presenter = presented }
          let scanner = PairingScannerController { value, error in
            self.scanPending = false
            if let error = error {
              result(FlutterError(code: "camera_unavailable", message: error, details: nil))
            } else { result(value) }
          }
          scanner.modalPresentationStyle = .fullScreen
          presenter.present(scanner, animated: true)
        }
      }
    }
  }
}

/// Camera-only QR reader; decoded text is validated by Dart before any connection.
private final class PairingScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let session = AVCaptureSession()
  private let cameraQueue = DispatchQueue(label: "score_reader.camera")
  private var preview: AVCaptureVideoPreviewLayer?
  private var finished = false
  private let completion: (String?, String?) -> Void

  init(completion: @escaping (String?, String?) -> Void) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    guard let camera = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: camera),
          session.canAddInput(input) else {
      DispatchQueue.main.async { self.finish(nil, "无法打开相机，请关闭其他使用相机的应用后重试。") }
      return
    }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else {
      DispatchQueue.main.async { self.finish(nil, "这台设备暂时无法扫描二维码。") }
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    guard output.availableMetadataObjectTypes.contains(.qr) else {
      DispatchQueue.main.async { self.finish(nil, "这台设备暂时无法扫描二维码。") }
      return
    }
    output.metadataObjectTypes = [.qr]
    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    self.preview = preview

    let label = UILabel()
    label.text = "将电脑上的二维码放在画面中央"
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    label.textAlignment = .center
    label.font = .preferredFont(forTextStyle: .headline)
    label.numberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    let cancel = UIButton(type: .system)
    cancel.setTitle("取消扫码", for: .normal)
    cancel.setTitleColor(.white, for: .normal)
    cancel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    cancel.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    cancel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cancel)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      label.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
      cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      cancel.widthAnchor.constraint(equalToConstant: 160),
      cancel.heightAnchor.constraint(equalToConstant: 52),
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(cancelScan), name: UIApplication.didEnterBackgroundNotification, object: nil)
    cameraQueue.async { self.session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
    if let connection = preview?.connection, connection.isVideoOrientationSupported,
       let orientation = view.window?.windowScene?.interfaceOrientation {
      switch orientation {
      case .landscapeLeft: connection.videoOrientation = .landscapeLeft
      case .landscapeRight: connection.videoOrientation = .landscapeRight
      case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
      default: connection.videoOrientation = .portrait
      }
    }
  }

  @objc private func cancelScan() { finish(nil, nil) }

  private func finish(_ value: String?, _ error: String?) {
    guard !finished else { return }
    finished = true
    NotificationCenter.default.removeObserver(self)
    cameraQueue.async { self.session.stopRunning() }
    dismiss(animated: true) { self.completion(value, error) }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
    finish(text, nil)
  }
}


/// Only visible foreground readers hold tokens. One old route cannot release
/// another route's wake request, and UIKit backgrounding independently restores
/// the normal idle timer even before Dart receives its lifecycle notification.
private final class ReaderWakeBridge: NSObject {
  static let shared = ReaderWakeBridge()
  private var owners = Set<String>()
  private var foreground = UIApplication.shared.applicationState == .active
  override init() {
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(resign), name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resign), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setReaderActive" else { result(FlutterMethodNotImplemented); return }
    guard let arguments = call.arguments as? [String: Any],
          let token = arguments["token"] as? String,
          let active = arguments["active"] as? Bool else {
      result(FlutterError(code: "invalid_reader_activity", message: "Invalid reader activity", details: nil)); return
    }
    DispatchQueue.main.async {
      if active { self.owners.insert(token) } else { self.owners.remove(token) }
      self.apply()
      result(nil)
    }
  }
  @objc private func resign() { foreground = false; apply() }
  @objc private func activate() { foreground = true; apply() }
  private func apply() {
    UIApplication.shared.isIdleTimerDisabled = foreground && !owners.isEmpty && UIApplication.shared.applicationState == .active
  }
}

/// ImageIO streaming downsample for sources larger than the Flutter pixel
/// budget. The source is never rewritten. Only a target-sized, temporary PNG
/// crosses into Flutter, avoiding a full source bitmap in Flutter's decoder.
private final class RasterDecodeBridge {
  static let shared = RasterDecodeBridge()
  private let queue = DispatchQueue(label: "score_reader.raster", qos: .userInitiated)
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("score-reader-downsample", isDirectory: true)

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String else {
      result(FlutterError(code: "invalid_raster", message: "Invalid image request", details: nil))
      return
    }
    if call.method == "releaseRaster" {
      queue.async {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var removed = false
        if url.deletingLastPathComponent() == self.directory.standardizedFileURL {
          do { try FileManager.default.removeItem(at: url); removed = true } catch { }
        }
        DispatchQueue.main.async { result(removed) }
      }
      return
    }
    guard call.method == "prepareRaster" else { result(FlutterMethodNotImplemented); return }
    guard let width = arguments["width"] as? Int,
          let height = arguments["height"] as? Int,
          width > 0, height > 0, width <= 8192, height <= 8192,
          width * height <= 12_000_000 else {
      result(FlutterError(code: "invalid_raster", message: "Image request exceeds budget", details: nil))
      return
    }
    queue.async {
      do {
        let output = try autoreleasepool {
          try RasterImageIO.prepare(path: path, width: width, height: height, directory: self.directory)
        }
        DispatchQueue.main.async { result(output.path) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "raster_failed", message: "Image downsample failed", details: nil))
        }
      }
    }
  }

}
#endif

/// Shared by the iOS bridge and a native macOS synthetic-image smoke.
enum RasterImageIO {
  private enum RasterError: Error { case invalidImage, outputFailed }
  private static let queue = DispatchQueue(label: "score_reader.imageio.core")
  private static var active = 0, maximumActive = 0, jobs = 0
  static func metrics() -> (active: Int, maximumActive: Int, jobs: Int) {
    queue.sync { (active, maximumActive, jobs) }
  }
  static func prepare(path: String, width: Int, height: Int, directory: URL) throws -> URL {
    try queue.sync {
      active += 1; jobs += 1; maximumActive = max(maximumActive, active)
      defer { active -= 1 }
      guard width > 0, height > 0, width <= 8192, height <= 8192,
            width * height <= 12_000_000 else { throw RasterError.invalidImage }
      return try downsample(path: path, width: width, height: height, directory: directory)
    }
  }
  private static func downsample(path: String, width: Int, height: Int, directory: URL) throws -> URL {
    let files = FileManager.default
    guard URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
            != directory.standardizedFileURL else { throw RasterError.invalidImage }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    // Dart serializes the complete native+Flutter decode pipeline. At most one
    // thumbnail is live; remove an interrupted previous session's own files.
    for old in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      if old.pathExtension == "png" { try files.removeItem(at: old) }
    }
    guard let source = CGImageSourceCreateWithURL(
      URL(fileURLWithPath: path) as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary
    ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
      throw RasterError.invalidImage
    }
    let short = min(sourceWidth.doubleValue, sourceHeight.doubleValue)
    let long = max(sourceWidth.doubleValue, sourceHeight.doubleValue)
    guard short > 0, long > 0 else { throw RasterError.invalidImage }
    let ratio = short / long
    var edge = min(8192, max(width, height))
    while Double(edge) * ceil(Double(edge) * ratio) > 12_000_000 { edge -= 1 }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: edge,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceShouldAllowFloat: false,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          image.width <= 8192, image.height <= 8192,
          image.width * image.height <= 12_000_000 else { throw RasterError.invalidImage }
    let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw RasterError.outputFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      try? files.removeItem(at: output)
      throw RasterError.outputFailed
    }
    return output
  }
}
