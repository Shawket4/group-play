import AVFoundation
import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Group Play is a speaker: play through the silent switch and keep playing in the background
    // (Info.plist UIBackgroundModes = audio). cpal does not set the category itself.
    GroupPlayAudioSession.configure()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GroupPlayIOS") {
      GroupPlayIOSChannel.register(with: registrar.messenger())
    }
  }
}

enum GroupPlayAudioSession {
  static func configure() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      NSLog("group-play: audio session setup failed: \(error)")
    }
  }

  static func info() -> [String: Any] {
    let s = AVAudioSession.sharedInstance()
    let route = s.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
    return [
      "sampleRate": s.sampleRate,
      "outputLatencyMs": s.outputLatency * 1000.0,
      "ioBufferMs": s.ioBufferDuration * 1000.0,
      "route": route,
    ]
  }
}

/// MethodChannel "group_play/ios". Mirrors the parts of the Android channel that make sense on iOS.
enum GroupPlayIOSChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "group_play/ios", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "configureAudio":
        GroupPlayAudioSession.configure()
        result(GroupPlayAudioSession.info())
      case "audioInfo":
        result(GroupPlayAudioSession.info())
      case "joinWifi":
        // Needs the Hotspot Configuration entitlement (paid developer team). Without it the
        // call fails and the UI falls back to "join this Wi-Fi in Settings" + a Wi-Fi QR code.
        guard let args = call.arguments as? [String: Any],
          let ssid = args["ssid"] as? String,
          let pass = args["passphrase"] as? String
        else {
          result(FlutterError(code: "args", message: "ssid and passphrase required", details: nil))
          return
        }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(config) { error in
          DispatchQueue.main.async {
            if let error = error as NSError? {
              // "already associated" counts as success
              if error.domain == NEHotspotConfigurationErrorDomain,
                error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
              {
                result(true)
              } else {
                result(FlutterError(code: "wifi", message: error.localizedDescription, details: error.code))
              }
            } else {
              result(true)
            }
          }
        }
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
