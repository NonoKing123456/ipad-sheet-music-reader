import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions) {
    // Capture the scoped URLs before the implicit engine or Dart is ready.
    ExternalFileImportBridge.shared.captureColdStart(connectionOptions.urlContexts.map { $0.url })
    // Keep Flutter's scene/engine setup and registered lifecycle delegates.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
