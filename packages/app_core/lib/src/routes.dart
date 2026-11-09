/// Every path in the app, so features navigate without importing each other.
abstract final class Routes {
  static const home = '/';
  static const host = '/host';

  /// `/host/speaker/:id` — `local` is this phone.
  static String hostSpeaker(String id) => '/host/speaker/${Uri.encodeComponent(id)}';
  static const hostSpeakerPattern = 'speaker/:id';
  static const localSpeakerId = 'local';

  static const join = '/join';

  /// What the host's QR code holds: opens Group Play on the join screen with the ticket
  /// (`groupplay://app/join?t=GPLAY1:…`). Scanned in-app or by the phone's camera.
  static String joinLink(String ticket) => 'groupplay://app/join?t=$ticket';
  static const speaker = '/speaker';
  static const speakerDetails = '/speaker/details';
  static const settings = '/settings';
  static const settingsName = '/settings/name';
  static const settingsCapture = '/settings/capture';
  static const settingsLogs = '/settings/logs';
}
