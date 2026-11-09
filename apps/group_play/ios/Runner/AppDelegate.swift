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
  private static var observing = false

  static func configure() {
    let session = AVAudioSession.sharedInstance()
    do {
      // mixWithOthers: another app's audio on this phone must not interrupt the speaker. An
      // interrupted session is inactive, and iOS suspends a background app with no active audio.
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      NSLog("group-play: audio session setup failed: \(error)")
    }
    observe()
  }

  /// Calls, Siri and alarms still interrupt: take the session back when they end. The engine
  /// notices its output stopped and rebuilds it on its own once the session is active again.
  private static func observe() {
    guard !observing else { return }
    observing = true
    let nc = NotificationCenter.default
    nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let ended = raw.flatMap(AVAudioSession.InterruptionType.init) == .ended
      NSLog("group-play: audio interruption \(ended ? "ended" : "began")")
      if ended { reactivate() }
    }
    nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: media services were reset")
      configure()
    }
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: entered background")
    }
    nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: entering foreground")
      reactivate()
    }
  }

  private static func reactivate() {
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("group-play: reactivating the audio session failed: \(error)")
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
      case "startMic":
        GroupPlayMic.start(result: result)
      case "stopMic":
        GroupPlayMic.stop()
        result(nil)
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

/// The host's microphone for tuning: mono s16le into a pipe whose read end goes to the engine.
/// The session is switched to play-and-record (measurement mode: no voice processing, output
/// still on the speaker) while it listens, and back to playback after.
enum GroupPlayMic {
  private static var engine: AVAudioEngine?
  private static var writeFd: Int32 = -1

  static func start(result: @escaping FlutterResult) {
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      DispatchQueue.main.async {
        guard granted else {
          result(FlutterError(code: "mic", message: "Allow the microphone in Settings so this phone can listen while tuning.", details: nil))
          return
        }
        do {
          result(try startEngine())
        } catch {
          stop()
          result(FlutterError(code: "mic", message: "The microphone did not start: \(error.localizedDescription)", details: nil))
        }
      }
    }
  }

  private static func startEngine() throws -> [String: Any] {
    stop()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    try session.setActive(true)
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "group-play", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
    }
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else {
      throw NSError(domain: "group-play", code: 2, userInfo: [NSLocalizedDescriptionKey: "pipe failed"])
    }
    // the engine closes its end when tuning is done: get EPIPE, not a SIGPIPE that kills the app
    _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
    let fd = fds[1]
    writeFd = fd
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      guard let channels = buffer.floatChannelData else { return }
      let n = Int(buffer.frameLength)
      var pcm = [Int16](repeating: 0, count: n)
      let src = channels[0]
      for i in 0..<n {
        pcm[i] = Int16(max(-1.0, min(1.0, src[i])) * 32767.0)
      }
      pcm.withUnsafeBytes { raw in
        guard var p = raw.baseAddress else { return }
        var left = raw.count
        while left > 0 {
          let w = write(fd, p, left)
          if w <= 0 { return }
          p = p.advanced(by: w)
          left -= w
        }
      }
    }
    try engine.start()
    self.engine = engine
    NSLog("group-play: mic recording at \(format.sampleRate) Hz")
    return ["fd": Int(fds[0]), "sampleRate": Int(format.sampleRate), "channels": 1]
  }

  static func stop() {
    if let engine = engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    if writeFd >= 0 {
      close(writeFd)
      writeFd = -1
    }
    GroupPlayAudioSession.configure()
  }
}
