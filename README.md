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
- **Tuning (by ear).** Each phone's latency report misses what the hardware adds after it
  (speaker DSP, codec buffers, Bluetooth), and that differs per model; Samsung's Group Play
  could skip this because it only ran on Samsung phones with known latencies. *Tune* measures
  it: every phone chirps in its own slot of a calibration stream while the host's microphone
  records, the chirp arrivals give each phone's lateness relative to the host (the host's own
  input latency cancels), and every phone, the host included, gets the delay that lines it up
  with the latest one. Timing is owned by the host and remembered per phone.
- **Sessions are remembered.** Every phone keeps one identity key, so a host has the same id and
  port (47100) every launch and its old join code keeps working. On launch a host starts
  hosting again and a speaker rejoins its host by itself, waiting for it if it is not up yet.
- **Transport.** iroh (QUIC, dial by public key). Same Wi-Fi or the host's hotspot → direct UDP;
  different networks → iroh relays (works, but raw PCM is heavy there: see open items).
- **Sources.** Sync-test clicks, a music file (symphonia: MP3/AAC/FLAC/WAV/OGG), or, on Android,
  the phone's own audio:
  - **Full sharing** — everything the phone plays, Spotify and Chrome included. Shizuku runs a
    service as the adb shell user that records `REMOTE_SUBMIX` (the scrcpy technique). That
    routes every app's sound into the recording; the host's own synced copy is opened on the
    speaker (or headphones/Bluetooth) explicitly, so the host keeps playing in step. Android 12+.
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
melos run core_test   # Rust engine: 21 unit + 6 end-to-end (real iroh host/guest in one process)
cd rust-core && cargo run --release --example cli -- join GPLAY1:...   # headless speaker on a laptop
```

## Test plan (phones)

1. **Same Wi-Fi, sync test.** Phone A: *Host a Session* → *Sync Test* tile. Phone B: scan A's
   code with the Camera app (opens Group Play straight into the session) or *Join as a
   Speaker* → scan. Within ~3 s B shows *In sync* and its gauge needle sits on 0.
2. **Tune.** Put the phones side by side, volume up, room quiet. Host → *Tune* (allow the
   microphone). Five seconds of chirps; the card says how far apart they were. Now the clicks
   should sound like one click. Logs show `tune: slot N heard 3/3 late … ms`: send those lines
   if it is still off. Fine adjustment, if ever needed: host → tap a speaker (or this phone) →
   *Timing* (+ = later). The speaker phone has no timing control any more.
3. **Remembered session.** Close both apps (swipe away). Open the host app: it hosts again by
   itself. Open the speaker app: it rejoins by itself (or shows *Waiting for host* until the
   host is up). Tuned timings come back too. *End Session* / *Leave* forgets it.
4. **Music file.** Host → *Music File* tile → pick a song.
5. **Full sharing (Android host).** Host → *Phone Audio* tile → the setup guide (install
   Shizuku, start it over wireless debugging, allow Group Play) → *Start Sharing*. Play
   Spotify on the host: the host and the speakers play it together. Tune works while sharing
   (Spotify pauses for the chirps and resumes). If the host echoes, turn off *Play Along* on its
   own row and tell me the phone model.
6. **Basic sharing.** Host → *Allowed Apps* tile → accept the screen-capture prompt → play
   YouTube Music. The host plays the app directly, so it is ahead of the speakers by the buffer:
   full sharing is the in-step mode.
7. **Hotspot.** Host → Network → Hotspot on. Android speakers join from the code; iPhones scan
   the Wi-Fi code in the Invite sheet with the Camera app first.
8. **Screen off / background.** Lock all phones: playback continues.

If something is off: Settings › Logs → Copy, and the speaker's *Details* (accuracy, drift,
lock error, buffered, dropouts) say where it is.

### What was verified for the tuning + remembered-session pass (2026-11-09)

- Engine: 21 unit + 6 end-to-end tests. The tuning test runs the whole loop over real
  connections with a simulated room (one speaker really 17 ms later than it reports, mic 30 ms
  behind): it measures 17 ms (±0.5) and the two then play the same frame at the same instant.
  Detector tests at 48 / 44.1 / 16 kHz mics with echo, hum and noise: within 0.35 ms.
  Persistence tests: same id and addresses after a host restart; the speaker waits and rejoins
  by itself with its timing; a reconnect with the same identity stays connected.
- Android emulator, real UI: Tune card → mic indicator on, 6 s recording, calibration stream
  reaches the speaker, clean "could not hear itself" message (the emulator mic is silent here,
  so the acoustic part could not run on the emulator); force-stop + relaunch → hosts again,
  same id/port, the Linux speaker rejoins in ~2 s with its remembered +7 ms; app as speaker →
  relaunch rejoins; host killed and restarted → rejoins by itself; *Waiting for host* screen;
  full sharing → `dumpsys media.audio_flinger` shows our stream on `AUDIO_DEVICE_OUT_SPEAKER`
  while every other app goes to `REMOTE_SUBMIX` (no loop); tuning during full sharing pauses
  and resumes it.
- Not verified: the acoustic tune on real phones (needs real speakers and mics), and the iOS
  side of it (`GroupPlayMic` in `AppDelegate.swift`: play-and-record session in measurement mode
  while listening, then back to playback). The iOS output-latency fix (render timestamp +
  `outputLatency`, cpal counts the IO buffer twice) only shows on a real iPhone.

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
- Basic sharing cannot be in step on the host (the app plays there directly); full sharing is.
- A source restarts after tuning only for sharing and the sync test; a music file starts over.
- iPhone cannot be a *phone-audio* source (iOS gives apps no access to other apps' audio).
