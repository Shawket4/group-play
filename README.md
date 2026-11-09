# Group Play

Every phone in the room plays the same song at the same moment. One phone hosts (picks the
music); the others join as speakers by scanning a QR code. iPhone and Android, any mix.

A thin Flutter UI (Cupertino / Apple HIG, Riverpod, go_router) over a Rust engine that does
the real work: clock sync, timeline-locked playback, transport.

## Layout (Madar POS architecture)

```
apps/group_play/           The Flutter app: boot, router, platform runners (android/ ios/ linux/)
packages/
  rust_bridge/             FFI plugin: cargokit builds group-play-frb; generated bindings (do not hand-edit)
  app_core/                Riverpod providers: engine status, session actions, device settings,
                           Android capabilities, alerts, logs; platform channels; routes
  design_system/           Apple HIG tokens (system colors, type scale, spacing, motion) + components
  features/                home · host · join · speaker · settings (one package each)
rust-core/
  crates/group-play-core/  THE ENGINE: sync, playback, sources, host/guest, iroh transport (+ tests, cli)
  crates/group-play-frb/   flutter_rust_bridge surface (one-line delegation) + Android JNI init
tool/gen-bindings.sh       regenerate bindings (`melos run bridge`)
```

Rules: the UI holds no logic (screens read providers and call notifier methods); no `setState`
anywhere; navigation through go_router (`Routes` in app_core); flutter_rust_bridge is pinned to
exactly `2.13.0` in three places (frb crate, rust_bridge pubspec, `tool/gen-bindings.sh`).

## How it works

- **Clock sync.** Each speaker pings the host over QUIC datagrams (NTP-style, four timestamps),
  keeps the fastest round trips and fits a line through them: offset and crystal drift (ppm).
- **One timeline.** The host maps every source frame to a host-clock time. Each speaker asks its
  audio hardware when the next buffer reaches the DAC (AAudio / CoreAudio timestamps), converts
  that to host time, and reads exactly that frame, resampling by a few ppm to follow drift and
  slewing small errors (≤0.2 %, inaudible) instead of skipping.
- **Transport.** iroh (QUIC, dial by public key). Same Wi-Fi or the host's hotspot → direct UDP;
  different networks → iroh relays (works, but raw PCM is heavy there: see open items).
- **Sources.** Sync-test clicks, a music file (symphonia: MP3/AAC/FLAC/WAV/OGG), or, on Android,
  the phone's own audio:
  - **Full sharing** — everything the phone plays, Spotify and Chrome included. Shizuku runs a
    service as the adb shell user that records `REMOTE_SUBMIX` (the scrcpy technique). The phone's
    speaker goes quiet; the speakers play. Android 12+.
  - **Basic sharing** — MediaProjection playback capture; apps can opt out (Spotify, Chrome do).

## Run it (MacBook)

Prereqs: Flutter 3.47+, Xcode, CocoaPods, Rust (rustup) — cargokit builds the Rust for each
target during the Flutter build and adds the rustup targets itself.

```bash
git clone git@github.com:Shawket4/group-play.git && cd group-play
dart pub global activate melos   # once
flutter pub get                  # resolves the whole workspace

cd apps/group_play
flutter run -d <iphone>          # iOS (first build compiles the Rust engine: ~5-10 min)
flutter run -d <android-phone>   # Android (or: flutter build apk --release)
```

iOS signing: open `apps/group_play/ios/Runner.xcworkspace`, set your team on the Runner target
(bundle id `com.shawket.groupplay`). No special entitlements are needed. Joining a hotspot from
inside the app on iPhone needs the *Hotspot Configuration* capability (paid team); without it
the app shows the network + password and a Wi-Fi QR code for the Camera app instead.

Checks:

```bash
melos run analyze     # flutter analyze, whole workspace (clean)
melos run core_test   # Rust engine: 16 unit + 3 end-to-end (real iroh host/guest in one process)
cd rust-core && cargo run --release --example cli -- join GPLAY1:...   # headless speaker on a laptop
```

## Test plan (phones)

1. **Same Wi-Fi, sync test.** Phone A: *Host a Session* → *Sync Test*. Phone B: *Join as a
   Speaker* → scan. Within ~3 s B shows *In sync*. Put the phones side by side: the clicks should
   sound like one click. If one is consistently early/late (Bluetooth speakers, some DACs), open
   it (host: Speakers → tap it; speaker: its own screen) and nudge *Timing*. Note the value.
2. **Music file.** Host → *Music File* → pick a song. Walk between the phones.
3. **Full sharing (Android host).** Settings › Full Sharing Setup → install Shizuku, start it
   (wireless debugging), allow Group Play. Host → *Everything This Phone Plays*. Open Spotify on
   the host and play: the host goes quiet, the speakers play Spotify. Then Chrome/YouTube.
   This is the item still unproven on a real phone (proven on the Android 15 emulator).
4. **Basic sharing.** Host → *Apps That Allow Capture* → accept the screen-capture prompt →
   play YouTube Music.
5. **Hotspot.** Turn the host's Wi-Fi hotspot on in the app; join from Android (one tap) and
   iPhone (Camera → Wi-Fi code, then scan the join code).
6. **Screen off / background.** Lock both phones: playback continues (foreground service on
   Android, background audio on iOS).

If something is off: Settings › Logs → Copy, and the per-speaker *Details* rows (offset, drift,
lock error, buffered, dropouts) say where it is.

## Open items

- Relay sessions (different networks) need compression: raw PCM (1.5 Mbit/s per speaker) only
  suits a LAN/hotspot. Opus is the next step.
- Auto-calibration with the microphone (chirp + time of flight) to replace the manual Timing nudge.
- iPhone cannot be a *phone-audio* source (iOS gives apps no access to other apps' audio).
