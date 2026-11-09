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
git clone git@github.com:Shawket4/group-play.git && cd group-play   # renamed from "tutti"
dart pub global activate melos   # once
flutter pub get                  # resolves the whole workspace

cd apps/group_play
flutter run -d <iphone>          # iOS (first build compiles the Rust engine: ~5-10 min)
flutter run -d <android-phone>   # Android, or install the APK from the GitHub release
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

1. **Same Wi-Fi, sync test.** Phone A: *Host a Session* → *Sync Test* tile. Phone B: scan A's
   code with the Camera app (opens Group Play straight into the session) or *Join as a
   Speaker* → scan. Within ~3 s B shows *In sync* and its gauge needle sits on 0. Put the
   phones side by side: the clicks should sound like one click. If one is consistently
   early/late (Bluetooth speakers, some DACs), nudge its *Timing* (speaker screen, or host →
   tap its avatar). Note the value.
2. **Music file.** Host → *Music File* tile → pick a song.
3. **Full sharing (Android host).** Host → *Phone Audio* tile → the setup guide (install
   Shizuku, start it over wireless debugging, allow Group Play) → *Start Sharing*. Play
   Spotify on the host: the host goes quiet, the speakers play it. Then Chrome/YouTube.
4. **Basic sharing.** Host → *Allowed Apps* tile → accept the screen-capture prompt → play
   YouTube Music.
5. **Hotspot.** Host → Network → Hotspot on. Android speakers join from the code; iPhones scan
   the Wi-Fi code in the Invite sheet with the Camera app first.
6. **Screen off / background.** Lock all phones: playback continues.

If something is off: Settings › Logs → Copy, and the speaker's *Details* (accuracy, drift,
lock error, buffered, dropouts) say where it is.

### What was verified before handing over (Android 15 emulator + this Linux box)

- Engine: 16 unit tests + 3 end-to-end tests (real iroh host/guest in one process: lockstep
  within 1 ms, live capture with a 50 ppm fast clock, join-before-play).
- App, by driving the real UI: host; join by deep link → *In sync* against a Linux host
  (lock error 0.00–0.01 ms, direct path, ~1 ms RTT); leave; sync test; music file (44.1 kHz WAV);
  full sharing via Shizuku (`REMOTE_SUBMIX` as uid 2000, tone captured at full level);
  basic sharing (MediaProjection); hotspot (SSID/password into the code); end session (capture,
  projection, hotspot and service all released); light and dark mode.
- **Watch item, Android host → speakers:** on the emulator the host's *outgoing* stream dies
  on the direct path once audio flows (pings survive, full-size batches vanish) and iroh only
  recovers over the relay ~25 s later. It looks like the emulator's virtual NIC dropping
  segmented UDP batches (the other direction, Linux host → emulator speaker, is flawless),
  but it has not been ruled out on a real phone yet. If an Android host's speakers show
  *Settling* with no sound, the host's Logs will say "guest is behind, skipped … chunks".
- Not runnable here: the iOS build (needs Xcode). Swift side: `AppDelegate.swift` (playback
  audio session, `group_play/ios` channel), Info.plist keys, URL scheme, Podfile (iOS 16).

## Open items

- Relay sessions (different networks) need compression: raw PCM (1.5 Mbit/s per speaker) only
  suits a LAN/hotspot. Opus is the next step.
- Auto-calibration with the microphone (chirp + time of flight) to replace the manual Timing nudge.
- iPhone cannot be a *phone-audio* source (iOS gives apps no access to other apps' audio).
