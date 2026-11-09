//! The host: owns the timeline, runs the source, fans media out to every guest, answers pings.

use super::clock::now_ns;
use super::net;
use super::player::{Player, PlayerShared};
use super::proto::{self, Dgram, GuestMsg, GuestStatus, HostMsg, Media, PROTOCOL_VERSION};
use super::ring::PcmRing;
use super::source::{FdReader, PullSource};
use super::sync::ClockEstimate;
use super::ticket::{Ticket, WifiCreds};
use super::timeline::Timeline;
use anyhow::{Context, Result};
use iroh::endpoint::Connection;
use iroh::Endpoint;
use parking_lot::Mutex;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
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

#[derive(Clone)]
struct Frame {
    bytes: Arc<Vec<u8>>,
    /// For chunks: the stream frame one past the end; for others 0.
    end_frame: u64,
}

struct StreamInfo {
    id: u32,
    sample_rate: u32,
    timeline: Timeline,
    desc: String,
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
}

struct Shared {
    stream: Mutex<Option<StreamInfo>>,
    recent: Mutex<VecDeque<Frame>>,
    bus: broadcast::Sender<Frame>,
    peers: Mutex<HashMap<String, PeerInfo>>,
    local: Arc<PlayerShared>,
    next_stream_id: AtomicU32,
    host_name: String,
}

impl Shared {
    fn publish(&self, msg: &Media, end_frame: u64) {
        let bytes = match proto::frame(msg) {
            Ok(b) => Arc::new(b),
            Err(e) => {
                log::error!("host: encode media: {e}");
                return;
            }
        };
        let frame = Frame { bytes, end_frame };
        if matches!(msg, Media::Chunk { .. }) {
            // Lock order everywhere: `stream` before `recent`.
            let cutoff = self
                .stream
                .lock()
                .as_ref()
                .map(|s| s.timeline.frame_at((now_ns() - RECENT_NS) as f64).max(0.0) as u64)
                .unwrap_or(0);
            let mut recent = self.recent.lock();
            recent.push_back(frame.clone());
            // drop chunks that played more than RECENT_NS ago
            while recent.front().map(|f| f.end_frame < cutoff).unwrap_or(false) {
                recent.pop_front();
            }
            while recent.len() > 2000 {
                recent.pop_front();
            }
        }
        let _ = self.bus.send(frame);
    }

    fn start_stream(&self, sample_rate: u32, timeline: Timeline, desc: String) -> u32 {
        let id = self.next_stream_id.fetch_add(1, Ordering::Relaxed);
        self.recent.lock().clear();
        *self.stream.lock() = Some(StreamInfo { id, sample_rate, timeline, desc: desc.clone() });
        self.local.ring.clear();
        self.local.set_timeline(Some(timeline), true);
        self.publish(&Media::StreamStart { id, sample_rate, timeline, desc }, 0);
        id
    }

    fn chunk(&self, id: u32, first_frame: u64, pcm: &[i16]) {
        self.local.ring.write_i16(first_frame, pcm);
        let end = first_frame + (pcm.len() / 2) as u64;
        self.publish(&Media::Chunk { id, first_frame, pcm: proto::pcm_to_bytes(pcm) }, end);
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
        self.publish(&Media::Timeline { id, timeline }, 0);
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
        self.publish(&Media::StreamStop { id }, 0);
    }

    /// The stream frame being heard right now (0 when nothing plays).
    fn playing_frame(&self) -> u64 {
        self.stream.lock().as_ref().map(|s| s.timeline.frame_at(now_ns() as f64).max(0.0) as u64).unwrap_or(0)
    }

    /// What a guest needs to join the current stream: StreamStart + chunks not yet played.
    fn snapshot(&self) -> Vec<Frame> {
        let stream = self.stream.lock();
        let Some(s) = stream.as_ref() else { return Vec::new() };
        let mut out = Vec::new();
        let start = Media::StreamStart { id: s.id, sample_rate: s.sample_rate, timeline: s.timeline, desc: s.desc.clone() };
        if let Ok(b) = proto::frame(&start) {
            out.push(Frame { bytes: Arc::new(b), end_frame: 0 });
        }
        let playing_now = s.timeline.frame_at(now_ns() as f64).max(0.0) as u64;
        for f in self.recent.lock().iter() {
            if f.end_frame > playing_now {
                out.push(f.clone());
            }
        }
        out
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
    wifi: Mutex<Option<WifiCreds>>,
    playout_delay_ns: Mutex<i64>,
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
}

impl Host {
    pub async fn start(host_name: String, local_playback: bool) -> Result<Host> {
        let endpoint = net::make_endpoint(true).await?;
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
        });
        let player = Some(Player::start(local));
        let accept = tokio::spawn(accept_loop(endpoint.clone(), shared.clone()));
        log::info!("host: listening as {}", endpoint.id());
        Ok(Host {
            endpoint,
            shared,
            _player: player,
            source: Mutex::new(None),
            accept,
            wifi: Mutex::new(None),
            playout_delay_ns: Mutex::new(300_000_000),
        })
    }

    pub fn ticket(&self) -> Ticket {
        net::ticket_for(&self.endpoint, &self.shared.host_name, self.wifi.lock().clone())
    }

    pub fn set_wifi(&self, wifi: Option<WifiCreds>) {
        *self.wifi.lock() = wifi;
    }

    pub fn local(&self) -> &Arc<PlayerShared> {
        &self.shared.local
    }

    pub fn set_playout_delay_ms(&self, ms: u32) {
        *self.playout_delay_ns.lock() = ms.clamp(60, 3000) as i64 * 1_000_000;
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
        let delay = *self.playout_delay_ns.lock();
        let thread = thread::Builder::new().name("gp-capture".into()).spawn(move || {
            if let Err(e) = run_fd(reader, sample_rate, label, delay, &shared, &st) {
                log::error!("capture: {e:#}");
            }
        })?;
        *self.source.lock() = Some(SourceHandle { stop, thread: Some(thread) });
        Ok(())
    }

    pub fn set_peer_delay(&self, peer: &str, ms: f64) {
        if let Some(p) = self.shared.peers.lock().get(peer) {
            let _ = p.cmd.send(HostMsg::SetDelay { delay_ms: ms });
        }
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

    pub async fn shutdown(self) {
        self.stop_source();
        for p in self.shared.peers.lock().values() {
            let _ = p.cmd.send(HostMsg::Kick { reason: "host ended the session".into() });
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
        self.accept.abort();
        self.endpoint.close().await;
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

/// Live capture. Frames arrive in real time on the *capture* clock; the timeline's rate is
/// adjusted (PI loop) so the margin between arrival and playout stays at `delay_ns`.
fn run_fd(mut reader: FdReader, rate: u32, label: String, delay_ns: i64, shared: &Shared, stop: &AtomicBool) -> Result<()> {
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
    while !stop.load(Ordering::Relaxed) {
        pcm.clear();
        let n = reader.read_frames(&mut pcm, chunk)?;
        if n == 0 {
            log::info!("capture: stream ended");
            break;
        }
        let now = now_ns();
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
        proto::write_msg(&mut ctl_send, &HostMsg::Kick { reason: format!("version mismatch: host {PROTOCOL_VERSION}, guest {version}") }).await?;
        anyhow::bail!("guest {name} speaks protocol {version}");
    }
    proto::write_msg(&mut ctl_send, &HostMsg::Welcome { host_name: shared.host_name.clone(), version: PROTOCOL_VERSION }).await?;
    log::info!("host: {name} ({platform}) joined");
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<HostMsg>();
    shared.peers.lock().insert(
        peer_id.clone(),
        PeerInfo { id: peer_id.clone(), name: name.clone(), platform, connected: true, path: net::path_kind(&conn), path_rtt_ms: net::path_rtt_ms(&conn), status: None, cmd: cmd_tx },
    );

    // media pump
    let media = {
        let conn = conn.clone();
        let shared = shared.clone();
        tokio::spawn(async move {
            let res: Result<()> = async {
                let mut send = conn.open_uni().await.context("media stream")?;
                let mut rx = shared.bus.subscribe();
                for f in shared.snapshot() {
                    send.write_all(&f.bytes).await?;
                }
                let mut skipped: u64 = 0;
                loop {
                    match rx.recv().await {
                        Ok(f) => {
                            // A slow link (relay, congested Wi-Fi) must not queue audio that is
                            // already too late to play: skip it and catch up instead.
                            if f.end_frame != 0 && f.end_frame < shared.playing_frame() {
                                skipped += 1;
                                if skipped % 50 == 1 {
                                    log::warn!("host: guest is behind, skipped {skipped} late chunks");
                                }
                                continue;
                            }
                            send.write_all(&f.bytes).await?
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            log::warn!("host: guest lagged {n} frames, resyncing");
                            for f in shared.snapshot() {
                                send.write_all(&f.bytes).await?;
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => return Ok(()),
                    }
                }
            }
            .await;
            if let Err(e) = res {
                log::debug!("host: media pump ended: {e:#}");
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
                    if let Some(p) = shared.peers.lock().get_mut(&peer_id) {
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
    if let Some(p) = shared.peers.lock().get_mut(&peer_id) {
        p.connected = false;
    }
    media.abort();
    commander.abort();
    pinger.abort();
    conn.close(0u32.into(), b"bye");
    result
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
