//! The host: owns the timeline, runs the source, fans media out to every guest, answers pings.

use super::clock::now_ns;
use super::eq::EqSettings;
use super::net;
use super::player::{Player, PlayerShared};
use super::proto::{self, Dgram, GuestMsg, GuestStatus, HostMsg, Media, PROTOCOL_VERSION};
use super::ring::PcmRing;
use super::source::{FdReader, PullSource};
use super::sync::ClockEstimate;
use super::ticket::{Ticket, WifiCreds};
use super::timeline::Timeline;
use super::tune::{self, Plan, Recording, TuneSource};
use anyhow::{Context, Result};
use iroh::endpoint::Connection;
use iroh::Endpoint;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};

/// Pull sources (file, clicks) are produced this far ahead of playout, so guests ride out
/// seconds of Wi-Fi trouble.
const PULL_LEAD_NS: i64 = 2_500_000_000;
/// First frame of a pull source plays this long after "play" is pressed.
const PULL_START_NS: i64 = 700_000_000;
/// Recent media kept for guests that join mid-stream.
const RECENT_NS: i64 = 4_000_000_000;

/// A segment counts as usable until this long before its last frame plays on a guest (one
/// output callback has to find it in the ring).
const CALLBACK_MARGIN_NS: i64 = 10_000_000;

/// What goes out to every guest.
#[derive(Clone)]
enum Frame {
    /// A length-prefixed `Media` message for the reliable, ordered meta stream.
    Meta(Arc<Vec<u8>>),
    /// One chunk of audio, sent on a segment stream of its own.
    Segment(Arc<Segment>),
}

struct Segment {
    /// The whole segment-stream payload (kind byte, header, PCM).
    bytes: Vec<u8>,
    /// Stream frame one past the segment's end.
    end_frame: u64,
    /// When that frame plays on the host clock, before any per-speaker delay.
    play_end_ns: i64,
}

struct StreamInfo {
    id: u32,
    sample_rate: u32,
    timeline: Timeline,
    desc: String,
}

/// Timing the host keeps for a guest (by its endpoint id, stable when the guest keeps its identity).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Timing {
    pub delay_ms: f64,
    /// Set by tuning (as opposed to never measured).
    pub tuned: bool,
}

pub struct PeerInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub connected: bool,
    pub path: String,
    pub path_rtt_ms: f64,
    pub status: Option<GuestStatus>,
    cmd: mpsc::UnboundedSender<HostMsg>,
    /// Which connection this entry belongs to. A guest that reconnects keeps its id (a stable
    /// identity), so the old connection's cleanup must not touch the new one's entry.
    conn: u64,
}

static NEXT_CONN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

struct Shared {
    stream: Mutex<Option<StreamInfo>>,
    recent: Mutex<VecDeque<Arc<Segment>>>,
    bus: broadcast::Sender<Frame>,
    peers: Mutex<HashMap<String, PeerInfo>>,
    local: Arc<PlayerShared>,
    next_stream_id: AtomicU32,
    host_name: String,
    endpoint: Endpoint,
    wifi: Mutex<Option<WifiCreds>>,
    timings: Mutex<HashMap<String, Timing>>,
    /// Whether the host's own delay came from tuning.
    self_tuned: AtomicBool,
    tuning: AtomicBool,
    /// Margin between capture and playout for live sources (ns). A running capture follows it.
    live_delay_ns: AtomicI64,
    /// Live captures running (a counter: an old capture thread can still be winding down when
    /// the next one starts).
    live: AtomicU32,
    /// The EQ every phone applies (sent to guests as they join and on every change).
    eq: Mutex<EqSettings>,
}

impl Shared {
    fn ticket(&self) -> Ticket {
        net::ticket_for(&self.endpoint, &self.host_name, self.wifi.lock().clone())
    }

    fn send_to(&self, peer: &str, msg: HostMsg) {
        if let Some(p) = self.peers.lock().get(peer) {
            let _ = p.cmd.send(msg);
        }
    }

    fn set_peer_delay(&self, peer: &str, ms: f64, tuned: Option<bool>) {
        {
            let mut t = self.timings.lock();
            let e = t.entry(peer.to_string()).or_default();
            e.delay_ms = ms;
            if let Some(tuned) = tuned {
                e.tuned = tuned;
            }
        }
        self.send_to(peer, HostMsg::SetDelay { delay_ms: ms });
    }

    fn publish_meta(&self, msg: &Media) {
        match proto::frame(msg) {
            Ok(b) => {
                let _ = self.bus.send(Frame::Meta(Arc::new(b)));
            }
            Err(e) => log::error!("host: encode media: {e}"),
        }
    }

    fn start_stream(&self, sample_rate: u32, timeline: Timeline, desc: String) -> u32 {
        let id = self.next_stream_id.fetch_add(1, Ordering::Relaxed);
        self.recent.lock().clear();
        *self.stream.lock() = Some(StreamInfo { id, sample_rate, timeline, desc: desc.clone() });
        self.local.ring.clear();
        self.local.set_stream_id(id);
        self.local.set_timeline(Some(timeline), true);
        self.publish_meta(&Media::StreamStart { id, sample_rate, timeline, desc });
        id
    }

    fn chunk(&self, id: u32, first_frame: u64, pcm: &[i16]) {
        // Lock order everywhere: `stream` before `recent`.
        let Some(tl) = self.stream.lock().as_ref().filter(|s| s.id == id).map(|s| s.timeline) else {
            return; // a source thread still finishing after its stream was replaced
        };
        self.local.ring.write_i16(first_frame, pcm);
        let frames = (pcm.len() / 2) as u32;
        let end_frame = first_frame + frames as u64;
        let seg = Arc::new(Segment {
            bytes: proto::SegmentHeader { id, first_frame, frames }.stream_bytes(pcm),
            end_frame,
            play_end_ns: tl.host_ns_at(end_frame as f64) as i64,
        });
        {
            let cutoff = tl.frame_at((now_ns() - RECENT_NS) as f64).max(0.0) as u64;
            let mut recent = self.recent.lock();
            recent.push_back(seg.clone());
            // drop chunks that played more than RECENT_NS ago
            while recent.front().map(|s| s.end_frame < cutoff).unwrap_or(false) {
                recent.pop_front();
            }
            while recent.len() > 2000 {
                recent.pop_front();
            }
        }
        let _ = self.bus.send(Frame::Segment(seg));
    }

    fn retime(&self, id: u32, timeline: Timeline) {
        {
            let mut s = self.stream.lock();
            match s.as_mut() {
                Some(s) if s.id == id => s.timeline = timeline,
                _ => return,
            }
        }
        self.local.set_timeline(Some(timeline), false);
        self.publish_meta(&Media::Timeline { id, timeline });
    }

    fn stop_stream(&self, id: u32) {
        {
            let mut s = self.stream.lock();
            if s.as_ref().map(|s| s.id) != Some(id) {
                return;
            }
            *s = None;
        }
        self.recent.lock().clear();
        self.local.set_timeline(None, false);
        self.publish_meta(&Media::StreamStop { id });
    }

    /// What a guest needs to join the current stream: its StreamStart (a meta message) and the
    /// segments that have not played yet.
    fn snapshot(&self) -> (Option<Arc<Vec<u8>>>, Vec<Arc<Segment>>) {
        let stream = self.stream.lock();
        let Some(s) = stream.as_ref() else { return (None, Vec::new()) };
        let start = Media::StreamStart { id: s.id, sample_rate: s.sample_rate, timeline: s.timeline, desc: s.desc.clone() };
        let now = now_ns();
        let segments = self.recent.lock().iter().filter(|g| g.play_end_ns > now).cloned().collect();
        (proto::frame(&start).ok().map(Arc::new), segments)
    }
}

struct SourceHandle {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Drop for SourceHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            // fd sources block in read(): closing the pipe's write end (Kotlin side) ends them.
            // Do not wait forever for that.
            let deadline = std::time::Instant::now() + Duration::from_millis(300);
            while !t.is_finished() && std::time::Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            if t.is_finished() {
                let _ = t.join();
            }
        }
    }
}

pub struct Host {
    endpoint: Endpoint,
    shared: Arc<Shared>,
    _player: Option<Player>,
    source: Mutex<Option<SourceHandle>>,
    accept: tokio::task::JoinHandle<()>,
    watch: tokio::task::JoinHandle<()>,
}

pub struct HostSnapshot {
    pub ticket: String,
    pub source: Option<String>,
    pub sample_rate: u32,
    pub peers: Vec<PeerSnapshot>,
}

pub struct PeerSnapshot {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub connected: bool,
    pub path: String,
    pub path_rtt_ms: f64,
    pub status: Option<GuestStatus>,
    pub timing: Timing,
}

/// One device's tuning outcome. `id` is empty for the host itself.
#[derive(Clone, Debug)]
pub struct TunedDevice {
    pub id: String,
    pub name: String,
    pub heard: bool,
    /// Lateness relative to the host with equal delays (ms), when heard.
    pub late_ms: Option<f64>,
    /// The delay it has now (ms).
    pub delay_ms: f64,
    pub spread_ms: f64,
    pub snr: f64,
}

#[derive(Clone, Debug)]
pub struct TuneReport {
    pub devices: Vec<TunedDevice>,
    /// Largest disagreement between the devices after tuning would be 0; this is how far apart
    /// they were before (max minus min sounding time, ms), for the "was 23 ms apart" line.
    pub spread_before_ms: f64,
}

impl Host {
    pub async fn start(host_name: String, local_playback: bool, identity: Option<[u8; 32]>) -> Result<Host> {
        let endpoint = net::make_endpoint(true, identity).await?;
        let ring = PcmRing::new(48_000 * 12);
        let local = PlayerShared::new(ring);
        local.set_clock(ClockEstimate::identity());
        local.enabled.store(local_playback, Ordering::Relaxed);
        let (bus, _) = broadcast::channel(1024);
        let shared = Arc::new(Shared {
            stream: Mutex::new(None),
            recent: Mutex::new(VecDeque::new()),
            bus,
            peers: Mutex::new(HashMap::new()),
            local: local.clone(),
            next_stream_id: AtomicU32::new(1),
            host_name,
            endpoint: endpoint.clone(),
            wifi: Mutex::new(None),
            timings: Mutex::new(HashMap::new()),
            self_tuned: AtomicBool::new(false),
            tuning: AtomicBool::new(false),
            live_delay_ns: AtomicI64::new(300_000_000),
            live: AtomicU32::new(0),
            eq: Mutex::new(EqSettings::default()),
        });
        let player = Some(Player::start(local));
        let accept = tokio::spawn(accept_loop(endpoint.clone(), shared.clone()));
        let watch = tokio::spawn(buffer_watch(shared.clone()));
        log::info!("host: listening as {}", endpoint.id());
        Ok(Host { endpoint, shared, _player: player, source: Mutex::new(None), accept, watch })
    }

    pub fn ticket(&self) -> Ticket {
        self.shared.ticket()
    }

    pub fn set_wifi(&self, wifi: Option<WifiCreds>) {
        *self.shared.wifi.lock() = wifi;
    }

    /// Timings remembered from earlier sessions (by guest id), applied when those guests join.
    pub fn set_known_timings(&self, known: Vec<(String, Timing)>) {
        let mut t = self.shared.timings.lock();
        for (id, timing) in known {
            t.insert(id, timing);
        }
    }

    /// The host phone's own delay (ms).
    pub fn set_self_delay(&self, ms: f64, tuned: Option<bool>) {
        self.shared.local.assigned_delay_ns.store((ms * 1e6) as i64, Ordering::Relaxed);
        if let Some(t) = tuned {
            self.shared.self_tuned.store(t, Ordering::Relaxed);
        }
    }

    pub fn self_delay_ms(&self) -> f64 {
        self.shared.local.assigned_delay_ns.load(Ordering::Relaxed) as f64 / 1e6
    }

    pub fn self_tuned(&self) -> bool {
        self.shared.self_tuned.load(Ordering::Relaxed)
    }

    pub fn is_tuning(&self) -> bool {
        self.shared.tuning.load(Ordering::Relaxed)
    }

    pub fn local(&self) -> &Arc<PlayerShared> {
        &self.shared.local
    }

    /// Live sources' margin between capture and playout. A running capture moves to it at once
    /// (every speaker jumps by the difference together).
    pub fn set_playout_delay_ms(&self, ms: u32) {
        self.shared.live_delay_ns.store(ms.clamp(60, 3000) as i64 * 1_000_000, Ordering::Relaxed);
    }

    /// The EQ and boost for everyone: this phone now, each speaker as the message arrives.
    pub fn set_eq(&self, eq: EqSettings) {
        let eq = eq.sanitized();
        *self.shared.eq.lock() = eq;
        self.shared.local.set_eq(eq);
        for p in self.shared.peers.lock().values() {
            let _ = p.cmd.send(HostMsg::SetEq { eq });
        }
    }

    pub fn eq(&self) -> EqSettings {
        *self.shared.eq.lock()
    }

    pub fn playout_delay_ms(&self) -> u32 {
        (self.shared.live_delay_ns.load(Ordering::Relaxed) / 1_000_000) as u32
    }

    pub fn stop_source(&self) {
        let old = self.source.lock().take();
        drop(old);
        let id = self.shared.stream.lock().as_ref().map(|s| s.id);
        if let Some(id) = id {
            self.shared.stop_stream(id);
        }
    }

    pub fn play_pull(&self, src: Box<dyn PullSource>) -> Result<()> {
        self.stop_source();
        let stop = Arc::new(AtomicBool::new(false));
        let shared = self.shared.clone();
        let st = stop.clone();
        let thread = thread::Builder::new().name("gp-source".into()).spawn(move || {
            if let Err(e) = run_pull(src, &shared, &st) {
                log::error!("source: {e:#}");
            }
        })?;
        *self.source.lock() = Some(SourceHandle { stop, thread: Some(thread) });
        Ok(())
    }

    pub fn play_fd(&self, fd: i32, sample_rate: u32, channels: u32, label: String) -> Result<()> {
        self.stop_source();
        let reader = FdReader::from_fd(fd, channels as usize)?;
        let stop = Arc::new(AtomicBool::new(false));
        let shared = self.shared.clone();
        let st = stop.clone();
        let thread = thread::Builder::new().name("gp-capture".into()).spawn(move || {
            if let Err(e) = run_fd(reader, sample_rate, label, &shared, &st) {
                log::error!("capture: {e:#}");
            }
        })?;
        *self.source.lock() = Some(SourceHandle { stop, thread: Some(thread) });
        Ok(())
    }

    /// The host's fine adjustment for one guest (ms, positive = later).
    pub fn set_peer_delay(&self, peer: &str, ms: f64) {
        self.shared.set_peer_delay(peer, ms, None);
    }

    pub fn set_peer_volume(&self, peer: &str, v: f64) {
        if let Some(p) = self.shared.peers.lock().get(peer) {
            let _ = p.cmd.send(HostMsg::SetVolume { volume: v });
        }
    }

    pub fn snapshot(&self) -> HostSnapshot {
        let stream = self.shared.stream.lock();
        let peers = self
            .shared
            .peers
            .lock()
            .values()
            .map(|p| PeerSnapshot {
                timing: self.shared.timings.lock().get(&p.id).copied().unwrap_or_default(),
                id: p.id.clone(),
                name: p.name.clone(),
                platform: p.platform.clone(),
                connected: p.connected,
                path: p.path.clone(),
                path_rtt_ms: p.path_rtt_ms,
                status: p.status.clone(),
            })
            .collect();
        HostSnapshot {
            ticket: self.ticket().encode(),
            source: stream.as_ref().map(|s| s.desc.clone()),
            sample_rate: stream.as_ref().map(|s| s.sample_rate).unwrap_or(0),
            peers,
        }
    }

    /// Starts tuning: plays the calibration stream with every connected device in its own slot,
    /// while `mic_fd` (s16le from this phone's microphone) records. Returns at once; run the
    /// returned job (about 6 s, blocking) to measure and apply the new delays.
    pub fn tune_start(&self, mic_fd: i32, mic_rate: u32, mic_channels: u32) -> Result<TuneJob> {
        let reader = FdReader::from_fd(mic_fd, mic_channels as usize)?;
        anyhow::ensure!(mic_rate >= 8_000, "microphone rate {mic_rate} Hz is too low");
        let mut peers: Vec<(String, String)> =
            self.shared.peers.lock().values().filter(|p| p.connected).map(|p| (p.id.clone(), p.name.clone())).collect();
        anyhow::ensure!(!peers.is_empty(), "No speakers are connected yet");
        anyhow::ensure!(!self.shared.tuning.swap(true, Ordering::SeqCst), "Already tuning");
        peers.sort();
        let plan = Plan::new(1 + peers.len() as u32);
        let recording = Arc::new(Mutex::new(Recording { samples: Vec::new(), rate: mic_rate as f64, anchor_ns: i64::MAX }));
        let stop = Arc::new(AtomicBool::new(false));
        {
            let recording = recording.clone();
            let stop = stop.clone();
            thread::Builder::new().name("gp-tune-mic".into()).spawn(move || record(reader, mic_rate, &recording, &stop))?;
        }
        let was_enabled = self.shared.local.enabled.swap(true, Ordering::Relaxed);
        if let Err(e) = self.play_pull(Box::new(TuneSource::new(plan))) {
            self.shared.local.enabled.store(was_enabled, Ordering::Relaxed);
            self.shared.tuning.store(false, Ordering::SeqCst);
            stop.store(true, Ordering::Relaxed);
            return Err(e);
        }
        Ok(TuneJob { shared: self.shared.clone(), plan, peers, recording, stop, was_enabled })
    }

    pub async fn shutdown(self) {
        // stop taking connections first, or a guest told "host ended" rejoins in the gap
        self.accept.abort();
        self.watch.abort();
        self.stop_source();
        for p in self.shared.peers.lock().values() {
            let _ = p.cmd.send(HostMsg::Kick { reason: "host ended the session".into(), resumable: true });
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
        self.accept.abort();
        self.endpoint.close().await;
    }
}

/// A tuning run in progress. [`TuneJob::run`] blocks until the chirps are done.
pub struct TuneJob {
    shared: Arc<Shared>,
    plan: Plan,
    peers: Vec<(String, String)>,
    recording: Arc<Mutex<Recording>>,
    stop: Arc<AtomicBool>,
    was_enabled: bool,
}

impl TuneJob {
    pub fn seconds(&self) -> f64 {
        self.plan.seconds() + 1.3
    }

    pub fn run(self) -> Result<TuneReport> {
        let res = self.measure();
        // always: everyone plays everything again, the host's own playback is as it was
        self.shared.local.set_gate(None);
        for (id, _) in &self.peers {
            self.shared.send_to(id, HostMsg::Gate { gate: None });
        }
        self.shared.local.enabled.store(self.was_enabled, Ordering::Relaxed);
        self.stop.store(true, Ordering::Relaxed);
        self.shared.tuning.store(false, Ordering::SeqCst);
        res
    }

    fn measure(&self) -> Result<TuneReport> {
        let shared = &self.shared;
        // the calibration stream starts on the source thread
        let deadline = now_ns() + 3_000_000_000;
        let (id, tl) = loop {
            if let Some(s) = shared.stream.lock().as_ref().filter(|s| s.desc == "Tuning") {
                break (s.id, s.timeline);
            }
            anyhow::ensure!(now_ns() < deadline, "tuning stream did not start");
            thread::sleep(Duration::from_millis(5));
        };
        shared.local.set_gate(Some(self.plan.gate(id, 0)));
        for (i, (peer, _)) in self.peers.iter().enumerate() {
            shared.send_to(peer, HostMsg::Gate { gate: Some(self.plan.gate(id, i as u32 + 1)) });
        }
        let current: Vec<f64> = std::iter::once(shared.local.assigned_delay_ns.load(Ordering::Relaxed) as f64 / 1e6)
            .chain(self.peers.iter().map(|(p, _)| shared.timings.lock().get(p).map(|t| t.delay_ms).unwrap_or(0.0)))
            .collect();
        let expected: Vec<Vec<f64>> = (0..self.plan.rounds)
            .map(|r| (0..self.plan.slots).map(|k| tl.host_ns_at(self.plan.frame_of(r, k) as f64) + current[k as usize] * 1e6).collect())
            .collect();
        let max_delay_ns = current.iter().copied().fold(0.0, f64::max) * 1e6;
        let end = tl.host_ns_at(self.plan.total_frames() as f64) + max_delay_ns + 600e6;
        while (now_ns() as f64) < end {
            if shared.stream.lock().as_ref().is_some_and(|s| s.id != id) {
                anyhow::bail!("tuning was interrupted (another source started)");
            }
            thread::sleep(Duration::from_millis(20));
        }
        self.stop.store(true, Ordering::Relaxed);
        let rec = std::mem::replace(&mut *self.recording.lock(), Recording { samples: Vec::new(), rate: 0.0, anchor_ns: 0 });
        anyhow::ensure!(rec.samples.len() as f64 > rec.rate * 2.0, "the microphone gave no audio");
        let peak = rec.samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        log::info!("tune: {:.1} s of mic audio at {} Hz, peak {:.3}", rec.samples.len() as f64 / rec.rate, rec.rate, peak);
        let results = tune::analyze(&rec, &self.plan, &expected);
        for r in &results {
            log::info!("tune: slot {} heard {}/{} late {:?} ms spread {:.2} ms snr {:.0}", r.slot, r.heard, self.plan.rounds, r.late_ms, r.spread_ms, r.snr);
        }
        anyhow::ensure!(
            results[0].late_ms.is_some(),
            "This phone could not hear itself. Check that the microphone is not covered and the volume is up."
        );
        let late: Vec<Option<f64>> = results.iter().map(|r| r.late_ms).collect();
        let delays = tune::new_delays(&current, &late);
        // apply
        shared.local.assigned_delay_ns.store((delays[0] * 1e6) as i64, Ordering::Relaxed);
        shared.self_tuned.store(true, Ordering::Relaxed);
        for (i, (peer, _)) in self.peers.iter().enumerate() {
            let heard = late[i + 1].is_some();
            shared.set_peer_delay(peer, delays[i + 1], heard.then_some(true));
        }
        let sounding: Vec<f64> = late.iter().zip(&current).filter_map(|(l, d)| l.map(|l| l + d - current[0])).collect();
        let spread_before_ms = if sounding.len() >= 2 {
            sounding.iter().copied().fold(f64::MIN, f64::max) - sounding.iter().copied().fold(f64::MAX, f64::min)
        } else {
            0.0
        };
        let mut devices = vec![TunedDevice {
            id: String::new(),
            name: shared.host_name.clone(),
            heard: true,
            late_ms: Some(0.0),
            delay_ms: delays[0],
            spread_ms: 0.0,
            snr: results[0].snr,
        }];
        for (i, (peer, name)) in self.peers.iter().enumerate() {
            let r = &results[i + 1];
            devices.push(TunedDevice {
                id: peer.clone(),
                name: name.clone(),
                heard: r.late_ms.is_some(),
                late_ms: r.late_ms,
                delay_ms: delays[i + 1],
                spread_ms: r.spread_ms,
                snr: r.snr,
            });
        }
        Ok(TuneReport { devices, spread_before_ms })
    }
}

/// Reads the microphone pipe into `out` until `stop`, EOF or 60 s. The anchor (host time of
/// sample 0) is the earliest "arrival minus duration so far" over all reads.
fn record(mut reader: FdReader, rate: u32, out: &Mutex<Recording>, stop: &AtomicBool) {
    let chunk = (rate / 100).max(1) as usize;
    let mut pcm = Vec::with_capacity(chunk * 2);
    let max = rate as usize * 60;
    let mut total = 0usize;
    while !stop.load(Ordering::Relaxed) && total < max {
        pcm.clear();
        match reader.read_frames(&mut pcm, chunk) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) => {
                log::warn!("tune: mic read: {e}");
                break;
            }
        }
        let now = now_ns();
        let mut rec = out.lock();
        rec.samples.extend(pcm.chunks_exact(2).map(|f| (f[0] as f32 + f[1] as f32) * 0.5 / 32768.0));
        total = rec.samples.len();
        let a = now - (total as f64 / rate as f64 * 1e9) as i64;
        rec.anchor_ns = rec.anchor_ns.min(a);
    }
}

fn run_pull(mut src: Box<dyn PullSource>, shared: &Shared, stop: &AtomicBool) -> Result<()> {
    let rate = src.sample_rate();
    let chunk = (rate / 50).max(1) as usize;
    let tl = Timeline::new(now_ns() + PULL_START_NS, rate as f64);
    let id = shared.start_stream(rate, tl, src.describe());
    log::info!("source: '{}' at {rate} Hz", src.describe());
    let mut next: u64 = 0;
    let mut pcm = Vec::with_capacity(chunk * 2);
    while !stop.load(Ordering::Relaxed) {
        let horizon = tl.frame_at((now_ns() + PULL_LEAD_NS) as f64).max(0.0) as u64;
        while next < horizon {
            pcm.clear();
            let n = src.pull(&mut pcm, chunk)?;
            if n == 0 {
                // finished: wait until the last frame has played, then stop
                let end_ns = tl.host_ns_at(next as f64) as i64 + 200_000_000;
                while now_ns() < end_ns && !stop.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(20));
                }
                if !stop.load(Ordering::Relaxed) {
                    shared.stop_stream(id);
                }
                return Ok(());
            }
            shared.chunk(id, next, &pcm);
            next += n as u64;
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

/// Peak and RMS of i16 PCM over a window, in dBFS.
#[derive(Default)]
struct Level {
    peak: i32,
    sum_sq: f64,
    samples: u64,
}

impl Level {
    fn add(&mut self, pcm: &[i16]) {
        for &s in pcm {
            let s = s as i32;
            self.peak = self.peak.max(s.abs());
            self.sum_sq += (s * s) as f64;
        }
        self.samples += pcm.len() as u64;
    }

    fn peak_db(&self) -> f64 {
        20.0 * (self.peak.max(1) as f64 / 32768.0).log10()
    }

    fn rms_db(&self) -> f64 {
        let ms = self.sum_sq / self.samples.max(1) as f64;
        10.0 * (ms.max(1.0) / (32768.0 * 32768.0)).log10()
    }
}

/// Counts this capture out of the host's running live captures however it ends.
struct LiveFlag<'a>(&'a AtomicU32);

impl Drop for LiveFlag<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Live capture. Frames arrive in real time on the *capture* clock; the timeline's rate is
/// adjusted (PI loop) so the margin between arrival and playout stays at the live delay.
fn run_fd(mut reader: FdReader, rate: u32, label: String, shared: &Shared, stop: &AtomicBool) -> Result<()> {
    shared.live.fetch_add(1, Ordering::Relaxed);
    let _live = LiveFlag(&shared.live);
    let mut delay_ns = shared.live_delay_ns.load(Ordering::Relaxed);
    let chunk = (rate / 100).max(1) as usize; // 10 ms reads
    let mut pcm = Vec::with_capacity(chunk * 2);
    // first data
    let n = reader.read_frames(&mut pcm, chunk).context("capture produced no data")?;
    if n == 0 {
        anyhow::bail!("capture ended before any audio arrived");
    }
    let t_arr = now_ns();
    let nominal = rate as f64;
    let mut tl = Timeline::new(t_arr - (n as f64 / nominal * 1e9) as i64 + delay_ns, nominal);
    let id = shared.start_stream(rate, tl, label.clone());
    log::info!("capture: '{label}' at {rate} Hz, playout delay {} ms", delay_ns / 1_000_000);
    shared.chunk(id, 0, &pcm);
    let mut next = n as u64;

    let mut window_best: f64 = f64::MIN; // best (largest) slack in the current window
    let mut window_start = now_ns();
    let mut integral = 0.0;
    let mut level = Level::default();
    while !stop.load(Ordering::Relaxed) {
        pcm.clear();
        let n = match reader.read_frames(&mut pcm, chunk) {
            Ok(n) => n,
            Err(e) => {
                // still end the stream below, or speakers keep a timeline with no audio behind it
                log::warn!("capture: read failed: {e:#}");
                break;
            }
        };
        if n == 0 {
            log::info!("capture: stream ended");
            break;
        }
        let now = now_ns();
        let want = shared.live_delay_ns.load(Ordering::Relaxed);
        if want != delay_ns {
            // every speaker moves by the difference at once (the host and guests share the timeline)
            log::info!("capture: playout delay {} -> {} ms", delay_ns / 1_000_000, want / 1_000_000);
            tl = Timeline { anchor_host_ns: tl.anchor_host_ns + (want - delay_ns), ..tl };
            shared.retime(id, tl);
            delay_ns = want;
            integral = 0.0;
            window_best = f64::MIN;
            window_start = now;
        }
        level.add(&pcm);
        if level.samples >= rate as u64 * 2 * 5 {
            // every ~5 s: how loud the capture is (a quiet host or speakers start here)
            log::info!("capture: level peak {:.1} dBFS, rms {:.1} dBFS", level.peak_db(), level.rms_db());
            level = Level::default();
        }
        shared.chunk(id, next, &pcm);
        next += n as u64;
        // slack: how long before its playout the newest frame arrived
        let slack = tl.host_ns_at(next as f64) - now as f64;
        if slack < 0.0 {
            // arrived too late to play (capture stalled, app was frozen): re-anchor with a jump
            log::warn!("capture: late by {:.0} ms, re-anchoring", -slack / 1e6);
            tl = Timeline { anchor_frame: next, anchor_host_ns: now + delay_ns, rate: tl.rate };
            shared.retime(id, tl);
            integral = 0.0;
            window_best = f64::MIN;
            window_start = now;
            continue;
        }
        window_best = window_best.max(slack);
        if now - window_start >= 1_000_000_000 {
            let dt = (now - window_start) as f64 / 1e9;
            let err_s = (window_best - delay_ns as f64) / 1e9; // + = audio arrives early = capture fast
            integral = (integral + err_s * dt).clamp(-0.5, 0.5);
            let corr = (0.01 * err_s + 0.0005 * integral).clamp(-500e-6, 500e-6);
            let new_rate = nominal * (1.0 + corr);
            if (new_rate - tl.rate).abs() > nominal * 1e-7 {
                tl = tl.rerated(next, new_rate);
                shared.retime(id, tl);
            }
            window_best = f64::MIN;
            window_start = now;
        }
    }
    shared.stop_stream(id);
    Ok(())
}

async fn accept_loop(endpoint: Endpoint, shared: Arc<Shared>) {
    while let Some(incoming) = endpoint.accept().await {
        let shared = shared.clone();
        tokio::spawn(async move {
            match incoming.await {
                Ok(conn) => {
                    if let Err(e) = serve_guest(conn, shared).await {
                        log::info!("host: guest left: {e:#}");
                    }
                }
                Err(e) => log::warn!("host: incoming failed: {e}"),
            }
        });
    }
}

async fn serve_guest(conn: Connection, shared: Arc<Shared>) -> Result<()> {
    let peer_id = conn.remote_id().to_string();
    // pings first, so the guest can start syncing while the handshake runs
    let pinger = tokio::spawn(answer_pings(conn.clone()));
    let (mut ctl_send, mut ctl_recv) = conn.accept_bi().await.context("control stream")?;
    let hello: GuestMsg = proto::read_msg(&mut ctl_recv).await?.context("guest closed before hello")?;
    let GuestMsg::Hello { name, platform, version } = hello else { anyhow::bail!("expected hello") };
    if version != PROTOCOL_VERSION {
        let reason = format!("This phone and the host run different versions of Group Play (host {PROTOCOL_VERSION}, this phone {version}). Update both.");
        proto::write_msg(&mut ctl_send, &HostMsg::Kick { reason, resumable: false }).await?;
        anyhow::bail!("guest {name} speaks protocol {version}");
    }
    proto::write_msg(&mut ctl_send, &HostMsg::Welcome { host_name: shared.host_name.clone(), version: PROTOCOL_VERSION, ticket: shared.ticket().encode() })
        .await?;
    // its timing from before (tuned or adjusted): same id, same phone
    let known = shared.timings.lock().get(&peer_id).copied();
    if let Some(t) = known {
        proto::write_msg(&mut ctl_send, &HostMsg::SetDelay { delay_ms: t.delay_ms }).await?;
    } else {
        proto::write_msg(&mut ctl_send, &HostMsg::SetDelay { delay_ms: 0.0 }).await?;
    }
    let eq = *shared.eq.lock();
    proto::write_msg(&mut ctl_send, &HostMsg::SetEq { eq }).await?;
    log::info!("host: {name} ({platform}) joined");
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<HostMsg>();
    let conn_no = NEXT_CONN.fetch_add(1, Ordering::Relaxed);
    shared.peers.lock().insert(
        peer_id.clone(),
        PeerInfo {
            id: peer_id.clone(),
            name: name.clone(),
            platform,
            connected: true,
            path: net::path_kind(&conn),
            path_rtt_ms: net::path_rtt_ms(&conn),
            status: None,
            cmd: cmd_tx,
            conn: conn_no,
        },
    );

    // media pump
    let media = {
        let conn = conn.clone();
        let shared = shared.clone();
        let peer = PeerRef { id: peer_id.clone(), name: name.clone() };
        tokio::spawn(async move {
            if let Err(e) = media_pump(conn.clone(), shared, peer).await {
                // a connection that closed on its own is reported by the control loop
                if conn.close_reason().is_none() {
                    log::warn!("host: media pump ended: {e:#}");
                }
            }
        })
    };

    // commands from the host UI to this guest
    let commander = tokio::spawn(async move {
        while let Some(cmd) = cmd_rx.recv().await {
            let kick = matches!(cmd, HostMsg::Kick { .. });
            if proto::write_msg(&mut ctl_send, &cmd).await.is_err() || kick {
                break;
            }
        }
        let _ = ctl_send.finish();
    });

    let result: Result<()> = async {
        loop {
            match proto::read_msg::<GuestMsg>(&mut ctl_recv).await? {
                Some(GuestMsg::Status(st)) => {
                    if let Some(p) = shared.peers.lock().get_mut(&peer_id).filter(|p| p.conn == conn_no) {
                        p.status = Some(st);
                        p.path = net::path_kind(&conn);
                        p.path_rtt_ms = net::path_rtt_ms(&conn);
                    }
                }
                Some(GuestMsg::Bye) | None => return Ok(()),
                Some(GuestMsg::Hello { .. }) => {}
            }
        }
    }
    .await;
    log::info!("host: {name} disconnected");
    if let Some(p) = shared.peers.lock().get_mut(&peer_id).filter(|p| p.conn == conn_no) {
        p.connected = false;
    }
    media.abort();
    commander.abort();
    pinger.abort();
    conn.close(0u32.into(), b"bye");
    result
}

/// Steps the live delay climbs through when speakers keep losing audio.
const LIVE_DELAY_STEPS_MS: [i64; 3] = [500, 800, 1000]; // the Buffer slider tops out at 1000
/// Audio a speaker may lose per watch window before the live delay goes up.
const LOST_PER_WINDOW_MS: f64 = 60.0;

/// Live sources have only the playout delay as headroom against Wi-Fi hiccups. When a speaker
/// keeps losing audio during a live share, give everyone more room: one step at a time, and
/// never back down on its own (the Buffer control on the host screen can).
async fn buffer_watch(shared: Arc<Shared>) {
    // by connection, not by phone: a guest that rejoins arrives with the underruns it counted
    // while it was cut off, which are not new losses
    let mut last: HashMap<u64, f64> = HashMap::new();
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    loop {
        tick.tick().await;
        if shared.live.load(Ordering::Relaxed) == 0 {
            last.clear();
            continue;
        }
        let mut worst: Option<(String, f64)> = None;
        for p in shared.peers.lock().values().filter(|p| p.connected) {
            let Some(st) = p.status.as_ref() else { continue };
            // silence the speaker actually played for lack of audio (late, dropped, or never sent)
            let lost = st.underrun_ms - last.insert(p.conn, st.underrun_ms).unwrap_or(st.underrun_ms);
            if worst.as_ref().map_or(true, |(_, w)| lost > *w) {
                worst = Some((p.name.clone(), lost));
            }
        }
        let Some((name, lost)) = worst else { continue };
        if lost <= LOST_PER_WINDOW_MS {
            continue;
        }
        let cur = shared.live_delay_ns.load(Ordering::Relaxed) / 1_000_000;
        if let Some(&next) = LIVE_DELAY_STEPS_MS.iter().find(|&&s| s > cur) {
            log::warn!("host: {name} lost {lost:.0} ms of audio in 2 s; live buffer {cur} -> {next} ms");
            shared.live_delay_ns.store(next * 1_000_000, Ordering::Relaxed);
        }
    }
}

struct PeerRef {
    id: String,
    name: String,
}

/// Feeds one guest: the meta stream, then a segment stream per chunk of audio. A segment that
/// can't reach the guest before it plays there is skipped (or reset once in flight), so a slow
/// moment costs a short gap instead of a backlog that makes every later chunk late too.
async fn media_pump(conn: Connection, shared: Arc<Shared>, peer: PeerRef) -> Result<()> {
    let mut meta = conn.open_uni().await.context("meta stream")?;
    let _ = meta.set_priority(i32::MAX);
    meta.write_all(&[proto::STREAM_META]).await.context("meta")?;
    let mut rx = shared.bus.subscribe();
    let mut segments = SegmentSender::new(conn, peer);
    segments.refresh_offset(&shared);
    let (start, recent) = shared.snapshot();
    if let Some(b) = start {
        meta.write_all(&b).await.context("meta")?;
    }
    for s in recent {
        segments.send(s).await?;
    }
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            m = rx.recv() => match m {
                Ok(Frame::Meta(b)) => meta.write_all(&b).await.context("meta")?,
                Ok(Frame::Segment(s)) => segments.send(s).await?,
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    // Segments stand alone; what may be lost is a timeline change, so resend it.
                    log::warn!("host: {} fell {n} messages behind, resyncing", segments.peer.name);
                    let (start, recent) = shared.snapshot();
                    if let Some(b) = start {
                        meta.write_all(&b).await.context("meta")?;
                    }
                    // what it missed and can still play (the deadline check drops the rest)
                    for s in recent {
                        segments.send(s).await?;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => return Ok(()),
            },
            _ = tick.tick() => {
                segments.refresh_offset(&shared);
                segments.report();
            }
        }
    }
}

struct SegmentSender {
    conn: Connection,
    peer: PeerRef,
    /// When this guest hears a frame relative to the host's playout: its delay minus its
    /// output latency (ns), from its latest status.
    offset_ns: i64,
    seq: u32,
    skipped: u64,
    reset: Arc<std::sync::atomic::AtomicU64>,
    reported: (u64, u64),
}

impl SegmentSender {
    fn new(conn: Connection, peer: PeerRef) -> Self {
        Self { conn, peer, offset_ns: 0, seq: 0, skipped: 0, reset: Default::default(), reported: (0, 0) }
    }

    fn refresh_offset(&mut self, shared: &Shared) {
        if let Some(st) = shared.peers.lock().get(&self.peer.id).and_then(|p| p.status.as_ref()) {
            self.offset_ns = ((st.delay_ms - st.latency_ms) * 1e6) as i64;
        } else if let Some(t) = shared.timings.lock().get(&self.peer.id) {
            // before its first status: at least the delay the host gave it
            self.offset_ns = (t.delay_ms * 1e6) as i64;
        }
    }

    async fn send(&mut self, seg: Arc<Segment>) -> Result<()> {
        let deadline = seg.play_end_ns + self.offset_ns - CALLBACK_MARGIN_NS;
        if deadline <= now_ns() {
            self.skipped += 1;
            return Ok(());
        }
        let mut s = self.conn.open_uni().await.context("segment stream")?;
        // Older segments go first: they play sooner.
        let _ = s.set_priority(-((self.seq & 0x3fff_ffff) as i32));
        self.seq = self.seq.wrapping_add(1);
        s.write_all(&seg.bytes).await.context("segment")?;
        let _ = s.finish();
        let reset = self.reset.clone();
        tokio::spawn(async move {
            let left = Duration::from_nanos((deadline - now_ns()).max(0) as u64);
            if tokio::time::timeout(left, s.stopped()).await.is_err() {
                // Not delivered in time: stop retransmitting audio nobody can play any more.
                if s.reset(0u32.into()).is_ok() {
                    reset.fetch_add(1, Ordering::Relaxed);
                }
            }
        });
        Ok(())
    }

    /// Once a second, if anything was given up on.
    fn report(&mut self) {
        let reset = self.reset.load(Ordering::Relaxed);
        let (skipped0, reset0) = self.reported;
        if self.skipped > skipped0 || reset > reset0 {
            log::warn!(
                "host: {} is behind: {} chunks too late to send, {} reset in flight",
                self.peer.name,
                self.skipped - skipped0,
                reset - reset0
            );
        }
        self.reported = (self.skipped, reset);
    }
}

async fn answer_pings(conn: Connection) {
    loop {
        let Ok(d) = conn.read_datagram().await else { return };
        let t1 = now_ns();
        if let Ok(Dgram::Ping { seq, t0 }) = proto::decode::<Dgram>(&d) {
            let t2 = now_ns();
            if let Ok(b) = proto::encode(&Dgram::Pong { seq, t0, t1, t2 }) {
                let _ = conn.send_datagram(b.into());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Level;

    #[test]
    fn level_in_dbfs() {
        let mut full = Level::default();
        full.add(&[32767, -32768, 32767, -32768]);
        assert!(full.peak_db().abs() < 0.01 && full.rms_db().abs() < 0.01);
        let mut half = Level::default();
        half.add(&[16384, -16384]);
        assert!((half.peak_db() + 6.02).abs() < 0.01 && (half.rms_db() + 6.02).abs() < 0.01);
        assert!(Level::default().rms_db() < -90.0); // silence, no NaN
    }
}
