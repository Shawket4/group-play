//! The guest: connects with a ticket, keeps its clock synced to the host, plays the stream.
//! Reconnects by itself if the link drops; the player keeps running (silent) meanwhile.

use super::clock::now_ns;
use super::net;
use super::player::{Player, PlayerShared};
use super::proto::{self, Dgram, GuestMsg, GuestStatus, HostMsg, Media, PROTOCOL_VERSION};
use super::ring::PcmRing;
use super::sync::{ClockEstimate, ClockSync, SyncSample};
use super::ticket::Ticket;
use anyhow::{Context, Result};
use iroh::endpoint::Connection;
use iroh::Endpoint;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Samples needed before the clock estimate is trusted for playback.
const MIN_SYNC_SAMPLES: usize = 5;

#[derive(Clone, Debug, Default)]
pub struct GuestView {
    pub state: String,
    pub host_name: String,
    pub path: String,
    pub path_rtt_ms: f64,
    pub source: Option<String>,
    pub sample_rate: u32,
    pub sync: ClockEstimate,
    pub kicked: Option<String>,
}

struct Shared {
    view: Mutex<GuestView>,
    sync: Mutex<ClockSync>,
    local: Arc<PlayerShared>,
    stream_id: Mutex<Option<u32>>,
    stop: AtomicBool,
    name: String,
    platform: String,
}

pub struct Guest {
    shared: Arc<Shared>,
    _player: Player,
    task: tokio::task::JoinHandle<()>,
    endpoint: Endpoint,
}

impl Guest {
    /// Connects once (so the caller gets a clear error), then keeps the session alive.
    pub async fn join(ticket: Ticket, name: String, platform: String) -> Result<Guest> {
        let endpoint = net::make_endpoint(false).await?;
        let ring = PcmRing::new(48_000 * 12);
        let local = PlayerShared::new(ring);
        // not playable until synced
        local.set_clock(ClockEstimate::default());
        let shared = Arc::new(Shared {
            view: Mutex::new(GuestView { state: "connecting".into(), host_name: ticket.host_name.clone(), ..Default::default() }),
            sync: Mutex::new(ClockSync::new()),
            local: local.clone(),
            stream_id: Mutex::new(None),
            stop: AtomicBool::new(false),
            name,
            platform,
        });
        let addr = net::addr_from_ticket(&ticket)?;
        let conn = tokio::time::timeout(Duration::from_secs(20), endpoint.connect(addr.clone(), proto::ALPN))
            .await
            .context("timed out reaching the host (same Wi-Fi? hotspot joined?)")?
            .context("could not reach the host")?;
        let player = Player::start(local);
        let task = {
            let shared = shared.clone();
            let endpoint = endpoint.clone();
            tokio::spawn(async move {
                let mut conn = Some(conn);
                let mut backoff = 1u64;
                while !shared.stop.load(Ordering::Relaxed) {
                    let c = match conn.take() {
                        Some(c) => c,
                        None => {
                            shared.view.lock().state = "reconnecting".into();
                            match tokio::time::timeout(Duration::from_secs(10), endpoint.connect(addr.clone(), proto::ALPN)).await {
                                Ok(Ok(c)) => c,
                                _ => {
                                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                                    backoff = (backoff * 2).min(5);
                                    continue;
                                }
                            }
                        }
                    };
                    backoff = 1;
                    match run_session(c, shared.clone()).await {
                        Ok(()) => {}
                        Err(e) => log::info!("guest: session ended: {e:#}"),
                    }
                    if shared.view.lock().kicked.is_some() {
                        shared.view.lock().state = "ended".into();
                        break;
                    }
                    shared.local.set_timeline(None, false);
                    *shared.stream_id.lock() = None;
                }
            })
        };
        Ok(Guest { shared, _player: player, task, endpoint })
    }

    pub fn local(&self) -> &Arc<PlayerShared> {
        &self.shared.local
    }

    pub fn view(&self) -> GuestView {
        let mut v = self.shared.view.lock().clone();
        v.sync = self.shared.sync.lock().estimate();
        v
    }

    pub async fn leave(self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.task.abort();
        self.endpoint.close().await;
    }
}

async fn run_session(conn: Connection, shared: Arc<Shared>) -> Result<()> {
    // a fresh connection starts a fresh sync window (the host may have restarted)
    *shared.sync.lock() = ClockSync::new();
    shared.local.set_clock(ClockEstimate::default());
    let pinger = tokio::spawn(ping_loop(conn.clone(), shared.clone()));

    let (mut send, mut recv) = conn.open_bi().await.context("control stream")?;
    proto::write_msg(&mut send, &GuestMsg::Hello { name: shared.name.clone(), platform: shared.platform.clone(), version: PROTOCOL_VERSION }).await?;
    match proto::read_msg::<HostMsg>(&mut recv).await?.context("host closed")? {
        HostMsg::Welcome { host_name, .. } => {
            let mut v = shared.view.lock();
            v.host_name = host_name;
            v.state = "connected".into();
            v.path = net::path_kind(&conn);
        }
        HostMsg::Kick { reason } => {
            shared.view.lock().kicked = Some(reason.clone());
            anyhow::bail!("host refused: {reason}");
        }
        other => anyhow::bail!("unexpected {other:?}"),
    }
    log::info!("guest: joined {}", shared.view.lock().host_name);

    let media = tokio::spawn(media_loop(conn.clone(), shared.clone()));
    let control = {
        let shared = shared.clone();
        tokio::spawn(async move {
            while let Ok(Some(msg)) = proto::read_msg::<HostMsg>(&mut recv).await {
                match msg {
                    HostMsg::SetDelay { delay_ms } => shared.local.delay_ns.store((delay_ms * 1e6) as i64, Ordering::Relaxed),
                    HostMsg::SetVolume { volume } => shared.local.set_volume(volume as f32),
                    HostMsg::Kick { reason } => {
                        shared.view.lock().kicked = Some(reason);
                        break;
                    }
                    HostMsg::Welcome { .. } => {}
                }
            }
        })
    };
    let reporter = {
        let shared = shared.clone();
        let conn = conn.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_millis(1000)).await;
                {
                    let mut v = shared.view.lock();
                    v.path = net::path_kind(&conn);
                    v.path_rtt_ms = net::path_rtt_ms(&conn);
                }
                let st = status_of(&shared);
                if proto::write_msg(&mut send, &GuestMsg::Status(st)).await.is_err() {
                    break;
                }
            }
        })
    };

    let mut control = control;
    tokio::select! {
        _ = conn.closed() => {}
        _ = &mut control => {}
    }
    pinger.abort();
    media.abort();
    reporter.abort();
    control.abort();
    if shared.view.lock().kicked.is_none() {
        anyhow::bail!("connection lost");
    }
    Ok(())
}

fn status_of(shared: &Shared) -> GuestStatus {
    let est = shared.sync.lock().estimate();
    let l = &shared.local;
    let rate = shared.view.lock().sample_rate.max(1) as f64;
    let pos = l.position_frame.load(Ordering::Relaxed);
    let buffer_ms = if pos >= 0 { (l.ring.highest() as f64 - pos as f64) / rate * 1000.0 } else { 0.0 };
    let out_rate = l.out_rate.load(Ordering::Relaxed).max(1) as f64;
    GuestStatus {
        sync_offset_ms: est.offset_ns / 1e6,
        rtt_ms: est.min_rtt_ns as f64 / 1e6,
        skew_ppm: est.skew * 1e6,
        buffer_ms,
        underrun_ms: l.underrun_frames.load(Ordering::Relaxed) as f64 / out_rate * 1000.0,
        latency_ms: l.latency_ns.load(Ordering::Relaxed) as f64 / 1e6,
        err_ms: l.err_ns.load(Ordering::Relaxed) as f64 / 1e6,
        delay_ms: l.delay_ns.load(Ordering::Relaxed) as f64 / 1e6,
        volume: l.volume() as f64,
        output: l.device_name.lock().clone(),
        playing: pos >= 0,
        jumps: l.jumps.load(Ordering::Relaxed),
    }
}

pub fn guest_status(g: &Guest) -> GuestStatus {
    status_of(&g.shared)
}

async fn ping_loop(conn: Connection, shared: Arc<Shared>) {
    let reader = {
        let conn = conn.clone();
        let shared = shared.clone();
        tokio::spawn(async move {
            while let Ok(d) = conn.read_datagram().await {
                let t3 = now_ns();
                if let Ok(Dgram::Pong { t0, t1, t2, .. }) = proto::decode::<Dgram>(&d) {
                    let est = {
                        let mut s = shared.sync.lock();
                        s.add(SyncSample { t0, t1, t2, t3 });
                        s.estimate()
                    };
                    if est.samples >= MIN_SYNC_SAMPLES {
                        shared.local.set_clock(est);
                    }
                }
            }
        })
    };
    let mut seq = 0u32;
    let started = now_ns();
    loop {
        let t0 = now_ns();
        if let Ok(b) = proto::encode(&Dgram::Ping { seq, t0 }) {
            if conn.send_datagram(b.into()).is_err() {
                break;
            }
        }
        seq = seq.wrapping_add(1);
        // fast at first to converge, then a steady trickle to follow drift
        let elapsed = now_ns() - started;
        let wait = if elapsed < 3_000_000_000 { 40 } else if elapsed < 20_000_000_000 { 150 } else { 400 };
        tokio::time::sleep(Duration::from_millis(wait)).await;
    }
    reader.abort();
}

async fn media_loop(conn: Connection, shared: Arc<Shared>) {
    let res: Result<()> = async {
        let mut recv = conn.accept_uni().await.context("media stream")?;
        while let Some(msg) = proto::read_msg::<Media>(&mut recv).await? {
            apply_media(&shared, msg);
        }
        Ok(())
    }
    .await;
    if let Err(e) = res {
        log::debug!("guest: media ended: {e:#}");
    }
}

fn apply_media(shared: &Shared, msg: Media) {
    match msg {
        Media::StreamStart { id, sample_rate, timeline, desc } => {
            let mut cur = shared.stream_id.lock();
            if *cur != Some(id) {
                shared.local.ring.clear();
                *cur = Some(id);
                shared.local.set_timeline(Some(timeline), true);
                log::info!("guest: stream {id} '{desc}' at {sample_rate} Hz");
            } else {
                shared.local.set_timeline(Some(timeline), false);
            }
            let mut v = shared.view.lock();
            v.source = Some(desc);
            v.sample_rate = sample_rate;
        }
        Media::Chunk { id, first_frame, pcm } => {
            if *shared.stream_id.lock() == Some(id) {
                shared.local.ring.write_i16(first_frame, &proto::bytes_to_pcm(&pcm));
            }
        }
        Media::Timeline { id, timeline } => {
            if *shared.stream_id.lock() == Some(id) {
                shared.local.set_timeline(Some(timeline), false);
            }
        }
        Media::StreamStop { id } => {
            let mut cur = shared.stream_id.lock();
            if *cur == Some(id) {
                *cur = None;
                shared.local.set_timeline(None, false);
                shared.view.lock().source = None;
            }
        }
    }
}
