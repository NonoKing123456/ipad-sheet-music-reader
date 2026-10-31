import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var scannerChannel: FlutterMethodChannel?
  private var scanPending = false
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
