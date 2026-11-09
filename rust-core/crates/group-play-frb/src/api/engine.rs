//! Everything Dart can call. Thin: it translates to `crate::engine` and back.

use group_play_core::{self as engine, engine, guest::Guest, host::Host, source, ticket::Ticket, Role};
use crate::frb_generated::StreamSink;
use anyhow::{anyhow, Result};
use std::sync::atomic::Ordering;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct PeerStatus {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub connected: bool,
    /// "direct" or "relay"
    pub path: String,
    /// Round trip of the network path (what "Direct · 4 ms" shows).
    pub rtt_ms: f64,
    /// Best clock-sync round trip; half of it is the sync accuracy.
    pub sync_rtt_ms: f64,
    pub sync_offset_ms: f64,
    pub skew_ppm: f64,
    pub buffer_ms: f64,
    pub underrun_ms: f64,
    pub latency_ms: f64,
    pub err_ms: f64,
    /// The delay the host gives this speaker (tuning plus fine adjustment), ms.
    pub delay_ms: f64,
    /// Measured by tuning (rather than never tuned).
    pub tuned: bool,
    pub volume: f64,
    pub output: String,
    pub playing: bool,
    pub jumps: u64,
    /// Audio that arrived too late to play or that the host gave up sending (ms, cumulative).
    pub late_ms: f64,
}

#[derive(Clone, Debug)]
pub struct LocalStatus {
    pub output: String,
    pub output_error: Option<String>,
    pub sample_rate: u32,
    pub latency_ms: f64,
    pub err_ms: f64,
    pub buffer_ms: f64,
    pub underrun_ms: f64,
    /// Guest: audio that arrived too late to play or that the host gave up sending (ms).
    pub late_ms: f64,
    pub jumps: u64,
    /// Host: this phone's own delay. Guest: the delay the host gave it. ms.
    pub delay_ms: f64,
    /// Host: its own delay came from tuning.
    pub tuned: bool,
    pub volume: f64,
    /// The host's EQ is on and changes this phone's sound.
    pub eq_active: bool,
    pub enabled: bool,
    pub playing: bool,
    pub sync_valid: bool,
    pub sync_rtt_ms: f64,
    pub sync_offset_ms: f64,
    pub skew_ppm: f64,
    pub sync_samples: u32,
}

#[derive(Clone, Debug)]
pub struct EngineStatus {
    /// "idle" | "host" | "guest"
    pub role: String,
    /// Guest: "connected" | "reconnecting" | "waiting" (host away) | "ended". Host: "hosting".
    pub state: String,
    pub host_name: String,
    /// Host: its join ticket. Guest: the host's latest ticket (remember this one).
    pub ticket: Option<String>,
    /// Host: tuning is running.
    pub tuning: bool,
    pub path: String,
    pub path_rtt_ms: f64,
    pub source: Option<String>,
    pub stream_rate: u32,
    /// Host: live sources' buffer (ms); it can go up on its own when speakers lose audio.
    pub playout_delay_ms: u32,
    pub peers: Vec<PeerStatus>,
    pub local: LocalStatus,
    pub ended_reason: Option<String>,
    pub last_error: Option<String>,
}

/// A timing the host remembered from an earlier session.
#[derive(Clone, Debug)]
pub struct KnownTiming {
    pub peer_id: String,
    pub delay_ms: f64,
    pub tuned: bool,
}

#[derive(Clone, Debug)]
pub struct TunedDevice {
    /// Empty for the host phone itself.
    pub peer_id: String,
    pub name: String,
    pub heard: bool,
    /// How much later than the host it sounded with equal delays (ms), when heard.
    pub late_ms: Option<f64>,
    /// Its delay now (ms).
    pub delay_ms: f64,
    pub spread_ms: f64,
}

#[derive(Clone, Debug)]
pub struct TuneReport {
    pub devices: Vec<TunedDevice>,
    /// How far apart the heard devices sounded before tuning (ms).
    pub spread_before_ms: f64,
}

#[derive(Clone, Debug)]
pub struct TicketInfo {
    pub host_name: String,
    pub addrs: Vec<String>,
    pub has_relay: bool,
    pub wifi_ssid: Option<String>,
    pub wifi_passphrase: Option<String>,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Our logger first (logcat/stderr + the in-app log view); frb's own setup then fails to
    // install its logger, which it ignores, and still sets up backtraces.
    let _ = engine();
    flutter_rust_bridge::setup_default_user_utils();
    log::set_max_level(log::LevelFilter::Info);
}

/// Name shown to the other phones, and the platform ("android", "ios", ...).
/// A new random identity key (32 bytes) for [`set_identity`]. Store it; reuse it every launch.
#[flutter_rust_bridge::frb(sync)]
pub fn new_identity() -> Vec<u8> {
    engine::net::new_identity_key().to_vec()
}

/// This phone's identity from now on: its id (and as host, its ticket) stays the same across
/// launches, so remembered sessions find each other again.
#[flutter_rust_bridge::frb(sync)]
pub fn set_identity(key: Vec<u8>) -> Result<()> {
    let key: [u8; 32] = key.try_into().map_err(|_| anyhow!("identity key must be 32 bytes"))?;
    *engine().identity.lock() = Some(key);
    Ok(())
}

/// This phone's id as the other phones see it (same as a host's peer id for it).
#[flutter_rust_bridge::frb(sync)]
pub fn identity_id() -> Option<String> {
    engine().identity.lock().map(|k| engine::net::identity_id(&k))
}

#[flutter_rust_bridge::frb(sync)]
pub fn configure(device_name: String, platform: String) {
    let e = engine();
    *e.device_name.lock() = device_name;
    *e.platform.lock() = platform;
}

/// Snapshots four times a second, for as long as Dart listens.
pub fn status_stream(sink: StreamSink<EngineStatus>) -> Result<()> {
    engine().rt.spawn(async move {
        loop {
            let st = snapshot().await;
            if sink.add(st).is_err() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });
    Ok(())
}

/// Every log line from now on (the recent history first).
pub fn log_stream(sink: StreamSink<String>) -> Result<()> {
    for line in engine::logging::recent() {
        let _ = sink.add(line);
    }
    engine::logging::set_listener(Some(Box::new(move |line: &str| {
        let _ = sink.add(line.to_string());
    })));
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn recent_logs() -> Vec<String> {
    engine::logging::recent()
}

/// Starts hosting (ending any current session). Returns the join ticket.
pub async fn start_host() -> Result<String> {
    let e = engine();
    e.rt
        .spawn(async move {
            let e = engine();
            let mut role = e.role.lock().await;
            end_role(&mut role).await;
            let local = *e.host_local_playback.lock();
            let name = e.device_name.lock().clone();
            let identity = *e.identity.lock();
            let host = Host::start(name, local, identity).await?;
            apply_local_settings(host.local());
            let ticket = host.ticket().encode();
            log::info!("host: ticket {ticket}");
            *role = Role::Host(host);
            Ok::<_, anyhow::Error>(ticket)
        })
        .await?
}

/// Attaches (or removes) hotspot credentials to the ticket. Returns the new ticket.
pub async fn set_host_wifi(ssid: Option<String>, passphrase: Option<String>) -> Result<String> {
    with_host(move |h| {
        let wifi = match (ssid, passphrase) {
            (Some(ssid), Some(passphrase)) if !ssid.is_empty() => Some(engine::ticket::WifiCreds { ssid, passphrase }),
            _ => None,
        };
        h.set_wifi(wifi);
        Ok(h.ticket().encode())
    })
    .await
}

/// Current ticket (addresses can change when the network does).
pub async fn host_ticket() -> Result<String> {
    with_host(|h| Ok(h.ticket().encode())).await
}

pub async fn play_clicks(bpm: f64) -> Result<()> {
    with_host(move |h| h.play_pull(Box::new(source::Clicks::new(48_000, bpm)))).await
}

pub async fn play_file(path: String) -> Result<String> {
    let src = tokio::task::spawn_blocking(move || source::FileSource::open(&path)).await??;
    let desc = source::PullSource::describe(&src);
    with_host(move |h| h.play_pull(Box::new(src))).await?;
    Ok(desc)
}

/// Live PCM from a pipe: interleaved s16le. The engine owns `fd` from here on.
pub async fn play_fd(fd: i32, sample_rate: u32, channels: u32, label: String) -> Result<()> {
    with_host(move |h| h.play_fd(fd, sample_rate, channels, label)).await
}

pub async fn stop_source() -> Result<()> {
    with_host(|h| {
        h.stop_source();
        Ok(())
    })
    .await
}

/// Margin between capture and playout for live sources; a running capture moves to it at once. Default 300 ms.
pub async fn set_playout_delay_ms(ms: u32) -> Result<()> {
    with_host(move |h| {
        h.set_playout_delay_ms(ms);
        Ok(())
    })
    .await
}

/// The host's EQ and boost, applied by every phone. `bands_db`: 10 bands, 32 Hz to 16 kHz.
#[derive(Clone, Debug)]
pub struct EqConfig {
    pub enabled: bool,
    pub boost_db: f64,
    pub bands_db: Vec<f64>,
}

/// Host: sets the EQ and boost for this phone and every speaker (now and as they join).
pub async fn set_eq(eq: EqConfig) -> Result<()> {
    let mut bands = [0f32; engine::eq::BANDS];
    for (b, v) in bands.iter_mut().zip(&eq.bands_db) {
        *b = *v as f32;
    }
    let settings = engine::eq::EqSettings { enabled: eq.enabled, boost_db: eq.boost_db as f32, bands_db: bands };
    with_host(move |h| {
        h.set_eq(settings);
        Ok(())
    })
    .await
}

/// Whether the host phone itself plays the synced stream.
pub async fn set_host_local_playback(enabled: bool) -> Result<()> {
    *engine().host_local_playback.lock() = enabled;
    let role = engine().role.lock().await;
    if let Role::Host(h) = &*role {
        h.local().enabled.store(enabled, Ordering::Relaxed);
    }
    Ok(())
}

/// Android: route the host's own playback straight to the speaker/headphones. Needed while full
/// sharing records the phone's output: the default route would lead into that recording.
pub async fn set_host_explicit_route(enabled: bool) -> Result<()> {
    with_host(move |h| {
        h.local().explicit_route.store(enabled, Ordering::Relaxed);
        Ok(())
    })
    .await
}

/// Timings remembered from earlier sessions; applied when those speakers join.
pub async fn set_known_timings(timings: Vec<KnownTiming>) -> Result<()> {
    with_host(move |h| {
        h.set_known_timings(timings.into_iter().map(|t| (t.peer_id, engine::host::Timing { delay_ms: t.delay_ms, tuned: t.tuned })).collect());
        Ok(())
    })
    .await
}

/// The host phone's own delay (ms, positive = later). `tuned`: it came from tuning.
pub async fn set_host_delay_ms(ms: f64, tuned: Option<bool>) -> Result<()> {
    with_host(move |h| {
        h.set_self_delay(ms, tuned);
        Ok(())
    })
    .await
}

/// Tunes every connected speaker by ear: each phone chirps in turn while this phone's
/// microphone (`mic_fd`: s16le, `mic_channels` interleaved) listens. Takes 4–10 s. Applies the
/// new delays and returns what it found. The engine owns `mic_fd`; stop the recording after.
pub async fn tune_speakers(mic_fd: i32, mic_rate: u32, mic_channels: u32) -> Result<TuneReport> {
    let job = with_host(move |h| h.tune_start(mic_fd, mic_rate, mic_channels)).await?;
    // the measurement runs without holding the session lock, so status keeps flowing
    let report = tokio::task::spawn_blocking(move || job.run()).await??;
    Ok(TuneReport {
        devices: report
            .devices
            .into_iter()
            .map(|d| TunedDevice { peer_id: d.id, name: d.name, heard: d.heard, late_ms: d.late_ms, delay_ms: d.delay_ms, spread_ms: d.spread_ms })
            .collect(),
        spread_before_ms: report.spread_before_ms,
    })
}

pub async fn set_peer_delay_ms(peer_id: String, ms: f64) -> Result<()> {
    with_host(move |h| {
        h.set_peer_delay(&peer_id, ms);
        Ok(())
    })
    .await
}

pub async fn set_peer_volume(peer_id: String, volume: f64) -> Result<()> {
    with_host(move |h| {
        h.set_peer_volume(&peer_id, volume);
        Ok(())
    })
    .await
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_ticket(ticket: String) -> Result<TicketInfo> {
    let t = Ticket::decode(&ticket)?;
    Ok(TicketInfo {
        host_name: t.host_name,
        addrs: t.addrs.iter().map(|a| a.to_string()).collect(),
        has_relay: t.relay.is_some(),
        wifi_ssid: t.wifi.as_ref().map(|w| w.ssid.clone()),
        wifi_passphrase: t.wifi.map(|w| w.passphrase),
    })
}

/// Joins a host. Returns the host's name once connected. `wait`: a remembered session; do not
/// fail if the host is not up yet, keep trying in the background (state "waiting").
pub async fn join(ticket: String, wait: bool) -> Result<String> {
    let t = Ticket::decode(&ticket)?;
    engine()
        .rt
        .spawn(async move {
            let e = engine();
            let mut role = e.role.lock().await;
            end_role(&mut role).await;
            let name = t.host_name.clone();
            let (me, platform) = (e.device_name.lock().clone(), e.platform.lock().clone());
            let identity = *e.identity.lock();
            let g = Guest::join(t, me, platform, identity, wait).await?;
            apply_local_settings(g.local());
            *role = Role::Guest(g);
            Ok::<_, anyhow::Error>(name)
        })
        .await?
}

/// Ends hosting or leaves the session.
pub async fn leave() -> Result<()> {
    engine()
        .rt
        .spawn(async move {
            let mut role = engine().role.lock().await;
            end_role(&mut role).await;
        })
        .await?;
    Ok(())
}

/// This device's calibration: positive = play later (use when this phone is early).
pub async fn set_delay_ms(ms: f64) -> Result<()> {
    *engine().delay_ms.lock() = ms;
    with_local(move |l| l.delay_ns.store((ms * 1e6) as i64, Ordering::Relaxed)).await;
    Ok(())
}

pub async fn set_volume(volume: f64) -> Result<()> {
    *engine().volume.lock() = volume;
    with_local(move |l| l.set_volume(volume as f32)).await;
    Ok(())
}

// ---------------------------------------------------------------------------------------------

fn apply_local_settings(l: &std::sync::Arc<engine::player::PlayerShared>) {
    let e = engine();
    l.delay_ns.store((*e.delay_ms.lock() * 1e6) as i64, Ordering::Relaxed);
    l.set_volume(*e.volume.lock() as f32);
}

async fn end_role(role: &mut Role) {
    match std::mem::replace(role, Role::Idle) {
        Role::Idle => {}
        Role::Host(h) => h.shutdown().await,
        Role::Guest(g) => g.leave().await,
    }
}

async fn with_host<R: Send + 'static>(f: impl FnOnce(&Host) -> Result<R> + Send + 'static) -> Result<R> {
    engine()
        .rt
        .spawn(async move {
            let role = engine().role.lock().await;
            match &*role {
                Role::Host(h) => f(h),
                _ => Err(anyhow!("not hosting")),
            }
        })
        .await?
}

async fn with_local(f: impl FnOnce(&std::sync::Arc<engine::player::PlayerShared>) + Send + 'static) {
    let _ = engine()
        .rt
        .spawn(async move {
            let role = engine().role.lock().await;
            match &*role {
                Role::Host(h) => f(h.local()),
                Role::Guest(g) => f(g.local()),
                Role::Idle => {}
            }
        })
        .await;
}

fn local_status(l: &engine::player::PlayerShared, stream_rate: u32, sync: Option<engine::sync::ClockEstimate>) -> LocalStatus {
    let rate = stream_rate.max(1) as f64;
    let pos = l.position_frame.load(Ordering::Relaxed);
    let out_rate = l.out_rate.load(Ordering::Relaxed);
    let sync = sync.unwrap_or_else(engine::sync::ClockEstimate::identity);
    LocalStatus {
        output: l.device_name.lock().clone(),
        output_error: l.error.lock().clone(),
        sample_rate: out_rate,
        latency_ms: l.latency_ns.load(Ordering::Relaxed) as f64 / 1e6,
        err_ms: l.err_ns.load(Ordering::Relaxed) as f64 / 1e6,
        buffer_ms: if pos >= 0 { (l.ring.highest() as f64 - pos as f64) / rate * 1000.0 } else { 0.0 },
        underrun_ms: l.underrun_frames.load(Ordering::Relaxed) as f64 / out_rate.max(1) as f64 * 1000.0,
        late_ms: 0.0,
        jumps: l.jumps.load(Ordering::Relaxed),
        delay_ms: l.total_delay_ns() as f64 / 1e6,
        tuned: false,
        volume: l.volume() as f64,
        eq_active: l.eq().is_active(),
        enabled: l.enabled.load(Ordering::Relaxed),
        playing: pos >= 0 && l.ring.highest() as i64 > pos,
        sync_valid: sync.valid && sync.samples >= 5 || sync.samples == 0 && sync.valid,
        sync_rtt_ms: sync.min_rtt_ns as f64 / 1e6,
        sync_offset_ms: sync.offset_ns / 1e6,
        skew_ppm: sync.skew * 1e6,
        sync_samples: sync.samples as u32,
    }
}

async fn snapshot() -> EngineStatus {
    let e = engine();
    let last_error = e.last_error.lock().clone();
    let role = e.role.lock().await;
    match &*role {
        Role::Idle => EngineStatus {
            role: "idle".into(),
            state: "idle".into(),
            host_name: String::new(),
            ticket: None,
            tuning: false,
            path: String::new(),
            path_rtt_ms: 0.0,
            source: None,
            stream_rate: 0,
            playout_delay_ms: 0,
            peers: vec![],
            local: LocalStatus {
                output: String::new(),
                output_error: None,
                sample_rate: 0,
                latency_ms: 0.0,
                err_ms: 0.0,
                buffer_ms: 0.0,
                underrun_ms: 0.0,
                late_ms: 0.0,
                jumps: 0,
                delay_ms: 0.0,
                tuned: false,
                volume: *e.volume.lock(),
                eq_active: false,
                enabled: true,
                playing: false,
                sync_valid: false,
                sync_rtt_ms: 0.0,
                sync_offset_ms: 0.0,
                skew_ppm: 0.0,
                sync_samples: 0,
            },
            ended_reason: None,
            last_error,
        },
        Role::Host(h) => {
            let s = h.snapshot();
            EngineStatus {
                role: "host".into(),
                state: "hosting".into(),
                host_name: e.device_name.lock().clone(),
                ticket: Some(s.ticket),
                tuning: h.is_tuning(),
                path: String::new(),
                path_rtt_ms: 0.0,
                source: s.source,
                stream_rate: s.sample_rate,
                playout_delay_ms: h.playout_delay_ms(),
                peers: s
                    .peers
                    .into_iter()
                    .map(|p| {
                        let st = p.status.unwrap_or_else(|| engine::proto::GuestStatus {
                            sync_offset_ms: 0.0,
                            rtt_ms: 0.0,
                            skew_ppm: 0.0,
                            buffer_ms: 0.0,
                            underrun_ms: 0.0,
                            latency_ms: 0.0,
                            err_ms: 0.0,
                            delay_ms: 0.0,
                            volume: 1.0,
                            output: String::new(),
                            playing: false,
                            jumps: 0,
                            late_ms: 0.0,
                        });
                        PeerStatus {
                            id: p.id,
                            name: p.name,
                            platform: p.platform,
                            connected: p.connected,
                            path: p.path,
                            rtt_ms: p.path_rtt_ms,
                            sync_rtt_ms: st.rtt_ms,
                            sync_offset_ms: st.sync_offset_ms,
                            skew_ppm: st.skew_ppm,
                            buffer_ms: st.buffer_ms,
                            underrun_ms: st.underrun_ms,
                            latency_ms: st.latency_ms,
                            err_ms: st.err_ms,
                            delay_ms: p.timing.delay_ms,
                            tuned: p.timing.tuned,
                            volume: st.volume,
                            output: st.output,
                            playing: st.playing,
                            jumps: st.jumps,
                            late_ms: st.late_ms,
                        }
                    })
                    .collect(),
                local: LocalStatus { tuned: h.self_tuned(), ..local_status(h.local(), s.sample_rate, None) },
                ended_reason: None,
                last_error,
            }
        }
        Role::Guest(g) => {
            let v = g.view();
            EngineStatus {
                role: "guest".into(),
                state: v.state.clone(),
                host_name: v.host_name.clone(),
                ticket: v.host_ticket.clone(),
                tuning: false,
                path: v.path.clone(),
                path_rtt_ms: v.path_rtt_ms,
                source: v.source.clone(),
                stream_rate: v.sample_rate,
                playout_delay_ms: 0,
                peers: vec![],
                local: LocalStatus { late_ms: engine::guest::guest_status(g).late_ms, ..local_status(g.local(), v.sample_rate, Some(v.sync)) },
                ended_reason: v.kicked.clone(),
                last_error,
            }
        }
    }
}
