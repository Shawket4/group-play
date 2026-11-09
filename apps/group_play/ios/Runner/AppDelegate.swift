import AVFoundation
import Flutter
import MediaPlayer
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Group Play is a speaker: play through the silent switch and keep playing in the background
    // (Info.plist UIBackgroundModes = audio). cpal does not set the category itself. Not activated
    // until a session starts, so opening the app doesn't stop the music already playing.
    GroupPlayAudioSession.configure(activate: false)
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

  static func configure(activate: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
      // Not mixable on purpose: a non-mixable playback session with Now Playing info is what makes
      // iOS treat Group Play as a music app (lock screen, Control Center, Dynamic Island) and keep
      // it running in the background. Interruptions are handled below.
      try session.setCategory(.playback, mode: .default, options: [])
      if activate { try session.setActive(true) }
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
      if ended && GroupPlayNowPlaying.active { reactivate() }
    }
    nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: media services were reset")
      configure(activate: GroupPlayNowPlaying.active)
    }
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: entered background")
    }
    nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      NSLog("group-play: entering foreground")
      if GroupPlayNowPlaying.active { reactivate() }
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
/// The lock screen, Control Center and Dynamic Island player. Play/pause go to Dart
/// ("remoteCommand"), which mutes or unmutes this phone; nothing here can seek (it's live).
enum GroupPlayNowPlaying {
  static var channel: FlutterMethodChannel?
  /// In a session: the audio session is ours and the player is up.
  private(set) static var active = false
  private static var commandsReady = false

  private static let artwork: MPMediaItemArtwork? = {
    guard let image = UIImage(named: "NowPlayingArt") else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }()

  static func update(_ args: [String: Any]) {
    guard args["active"] as? Bool == true else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      if active {
        // Out of the session: no controls, and give the audio back so other apps' music resumes.
        active = false
        setCommandsEnabled(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
      return
    }
    if !active {
      active = true
      try? AVAudioSession.sharedInstance().setActive(true)
    }
    setUpCommands()
    setCommandsEnabled(true)
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "Group Play",
      MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
      MPNowPlayingInfoPropertyIsLiveStream: true,
      MPNowPlayingInfoPropertyPlaybackRate: (args["playing"] as? Bool ?? true) ? 1.0 : 0.0,
    ]
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private static func setCommandsEnabled(_ on: Bool) {
    let cc = MPRemoteCommandCenter.shared()
    cc.playCommand.isEnabled = on
    cc.pauseCommand.isEnabled = on
    cc.togglePlayPauseCommand.isEnabled = on
  }

  private static func setUpCommands() {
    guard !commandsReady else { return }
    commandsReady = true
    UIApplication.shared.beginReceivingRemoteControlEvents()
    let cc = MPRemoteCommandCenter.shared()
    let send: (String) -> MPRemoteCommandHandlerStatus = { command in
      channel?.invokeMethod("remoteCommand", arguments: command)
      return .success
    }
    cc.playCommand.addTarget { _ in send("play") }
    cc.pauseCommand.addTarget { _ in send("pause") }
    cc.togglePlayPauseCommand.addTarget { _ in send("toggle") }
    let unsupported: [MPRemoteCommand] = [
      cc.nextTrackCommand, cc.previousTrackCommand, cc.skipForwardCommand, cc.skipBackwardCommand,
      cc.seekForwardCommand, cc.seekBackwardCommand, cc.changePlaybackPositionCommand,
    ]
    for c in unsupported { c.isEnabled = false }
  }
}

enum GroupPlayIOSChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "group_play/ios", binaryMessenger: messenger)
    GroupPlayNowPlaying.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "nowPlaying":
        GroupPlayNowPlaying.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "configureAudio":
        GroupPlayAudioSession.configure(activate: GroupPlayNowPlaying.active)
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
    GroupPlayAudioSession.configure(activate: GroupPlayNowPlaying.active)
  }
}
