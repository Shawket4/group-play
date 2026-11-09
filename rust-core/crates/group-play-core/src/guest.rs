//! The guest: connects with a ticket, keeps its clock synced to the host, plays the stream.
//! Reconnects by itself if the link drops; the player keeps running (silent) meanwhile.

use super::clock::now_ns;
use super::net;
use super::player::{Player, PlayerShared};
use super::proto::{self, Dgram, GuestMsg, GuestStatus, HostMsg, Media, SegmentHeader, PROTOCOL_VERSION};
use super::ring::PcmRing;
use super::sync::{ClockEstimate, ClockSync, SyncSample};
use super::ticket::Ticket;
use anyhow::{Context, Result};
use iroh::endpoint::{Connection, ReadError, ReadExactError};
use iroh::Endpoint;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    /// The host's latest ticket (from its welcome): remember this one to find it next time.
    pub host_ticket: Option<String>,
}

/// Segments of a stream whose StreamStart has not arrived yet, kept at most this many
/// (streams are not ordered with each other, so a segment can beat its own StreamStart).
const MAX_EARLY_SEGMENTS: usize = 256;

#[derive(Default)]
struct MediaState {
    stream_id: Option<u32>,
    early: Vec<(SegmentHeader, Vec<u8>)>,
}

struct Shared {
    view: Mutex<GuestView>,
    sync: Mutex<ClockSync>,
    local: Arc<PlayerShared>,
    media: Mutex<MediaState>,
    /// Frames that arrived too late to play, or that the host gave up sending.
    late_frames: AtomicU64,
    stop: AtomicBool,
    /// The host went away on purpose (ended the session, closed the app): wait for it.
    host_away: AtomicBool,
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
    /// `wait`: do not fail when the host is not there yet (a remembered session at launch):
    /// keep trying in the background, showing "waiting".
    pub async fn join(ticket: Ticket, name: String, platform: String, identity: Option<[u8; 32]>, wait: bool) -> Result<Guest> {
        let endpoint = net::make_endpoint(false, identity).await?;
        let ring = PcmRing::new(48_000 * 12);
        let local = PlayerShared::new(ring);
        // not playable until synced
        local.set_clock(ClockEstimate::default());
        let shared = Arc::new(Shared {
            view: Mutex::new(GuestView { state: "connecting".into(), host_name: ticket.host_name.clone(), ..Default::default() }),
            sync: Mutex::new(ClockSync::new()),
            local: local.clone(),
            media: Mutex::new(MediaState::default()),
            late_frames: AtomicU64::new(0),
            stop: AtomicBool::new(false),
            host_away: AtomicBool::new(wait),
            name,
            platform,
        });
        let addr = net::addr_from_ticket(&ticket)?;
        let conn = if wait {
            shared.view.lock().state = "waiting".into();
            None
        } else {
            Some(
                tokio::time::timeout(Duration::from_secs(20), endpoint.connect(addr.clone(), proto::ALPN))
                    .await
                    .context("timed out reaching the host (same Wi-Fi? hotspot joined?)")?
                    .context("could not reach the host")?,
            )
        };
        let player = Player::start(local);
        let task = {
            let shared = shared.clone();
            let endpoint = endpoint.clone();
            tokio::spawn(async move {
                let mut conn = conn;
                let mut backoff = 1u64;
                while !shared.stop.load(Ordering::Relaxed) {
                    let c = match conn.take() {
                        Some(c) => c,
                        None => {
                            let away = shared.host_away.load(Ordering::Relaxed);
                            shared.view.lock().state = if away { "waiting" } else { "reconnecting" }.into();
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
                    *shared.media.lock() = MediaState::default();
                    if shared.host_away.load(Ordering::Relaxed) {
                        shared.view.lock().state = "waiting".into();
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
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
        HostMsg::Welcome { host_name, ticket, .. } => {
            let mut v = shared.view.lock();
            v.host_name = host_name;
            v.state = "connected".into();
            v.path = net::path_kind(&conn);
            v.host_ticket = Some(ticket);
            shared.host_away.store(false, Ordering::Relaxed);
        }
        HostMsg::Kick { reason, resumable } => {
            if resumable {
                shared.host_away.store(true, Ordering::Relaxed);
            } else {
                shared.view.lock().kicked = Some(reason.clone());
            }
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
                    HostMsg::SetDelay { delay_ms } => shared.local.assigned_delay_ns.store((delay_ms * 1e6) as i64, Ordering::Relaxed),
                    HostMsg::SetVolume { volume } => shared.local.set_volume(volume as f32),
                    HostMsg::SetEq { eq } => shared.local.set_eq(eq),
                    HostMsg::Gate { gate } => shared.local.set_gate(gate),
                    HostMsg::Kick { reason, resumable } => {
                        if resumable {
                            log::info!("guest: {reason}; waiting for the host to come back");
                            shared.host_away.store(true, Ordering::Relaxed);
                        } else {
                            shared.view.lock().kicked = Some(reason);
                        }
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
    shared.local.set_gate(None);
    if shared.host_away.load(Ordering::Relaxed) {
        conn.close(0u32.into(), b"bye");
        return Ok(());
    }
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
        delay_ms: l.total_delay_ns() as f64 / 1e6,
        volume: l.volume() as f64,
        output: l.device_name.lock().clone(),
        // playing = audio for the current position is actually here (not just a timeline)
        playing: pos >= 0 && l.ring.highest() as i64 > pos,
        jumps: l.jumps.load(Ordering::Relaxed),
        late_ms: shared.late_frames.load(Ordering::Relaxed) as f64 / rate * 1000.0,
    }
}

pub fn guest_status(g: &Guest) -> GuestStatus {
    status_of(&g.shared)
}

/// A host that stops answering pings this long is gone (app killed, out of range): drop the
/// connection now instead of waiting for QUIC's idle timeout, and start reconnecting.
const HOST_SILENT_NS: i64 = 5_000_000_000;

async fn ping_loop(conn: Connection, shared: Arc<Shared>) {
    let last_pong = Arc::new(std::sync::atomic::AtomicI64::new(now_ns()));
    let reader = {
        let last_pong = last_pong.clone();
        let conn = conn.clone();
        let shared = shared.clone();
        tokio::spawn(async move {
            while let Ok(d) = conn.read_datagram().await {
                let t3 = now_ns();
                if let Ok(Dgram::Pong { t0, t1, t2, .. }) = proto::decode::<Dgram>(&d) {
                    last_pong.store(t3, Ordering::Relaxed);
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
        if now_ns() - last_pong.load(Ordering::Relaxed) > HOST_SILENT_NS {
            log::info!("guest: host stopped answering, reconnecting");
            conn.close(0u32.into(), b"host silent");
            break;
        }
        // fast at first to converge, then a steady trickle to follow drift
        let elapsed = now_ns() - started;
        let wait = if elapsed < 3_000_000_000 { 40 } else if elapsed < 20_000_000_000 { 150 } else { 400 };
        tokio::time::sleep(Duration::from_millis(wait)).await;
    }
    reader.abort();
}

/// Takes every uni stream the host opens: the meta stream once, then one per audio segment.
async fn media_loop(conn: Connection, shared: Arc<Shared>) {
    while let Ok(recv) = conn.accept_uni().await {
        let shared = shared.clone();
        tokio::spawn(async move { read_uni(recv, &shared).await });
    }
}

async fn read_uni(mut recv: iroh::endpoint::RecvStream, shared: &Shared) {
    let mut kind = [0u8; 1];
    if recv.read_exact(&mut kind).await.is_err() {
        return;
    }
    match kind[0] {
        proto::STREAM_META => {
            let res: Result<()> = async {
                while let Some(msg) = proto::read_msg::<Media>(&mut recv).await? {
                    apply_media(shared, msg);
                }
                Ok(())
            }
            .await;
            if let Err(e) = res {
                // a dropped connection ends it too; the session loop reports that
                let lost = matches!(
                    e.downcast_ref::<ReadExactError>(),
                    Some(ReadExactError::ReadError(ReadError::ConnectionLost(_)))
                );
                if lost {
                    log::debug!("guest: media ended with the connection");
                } else {
                    log::warn!("guest: media ended: {e:#}");
                }
            }
        }
        proto::STREAM_SEGMENT => {
            let mut h = [0u8; proto::SEGMENT_HEADER_LEN];
            if recv.read_exact(&mut h).await.is_err() {
                return;
            }
            let hdr = SegmentHeader::decode(&h);
            if hdr.frames > proto::MAX_SEGMENT_FRAMES {
                log::warn!("guest: segment of {} frames refused", hdr.frames);
                return;
            }
            let mut pcm = vec![0u8; hdr.frames as usize * 4];
            match recv.read_exact(&mut pcm).await {
                Ok(()) => apply_segment(shared, hdr, pcm),
                // the host reset it: it could not arrive in time (a dropped connection is not late audio)
                Err(ReadExactError::ReadError(ReadError::Reset(_))) => {
                    shared.late_frames.fetch_add(hdr.frames as u64, Ordering::Relaxed);
                }
                Err(_) => {}
            }
        }
        k => log::warn!("guest: unknown stream kind {k}"),
    }
}

fn apply_segment(shared: &Shared, hdr: SegmentHeader, pcm: Vec<u8>) {
    // Held while writing, so a StreamStart can't clear the ring between the check and the write.
    let mut m = shared.media.lock();
    match m.stream_id {
        Some(id) if id == hdr.id => {
            // only this stream's position counts: right after a StreamStart the callback may
            // still report where it was in the previous one, and the new stream starts at 0
            if shared.local.current_position().is_some_and(|pos| hdr.first_frame + hdr.frames as u64 <= pos as u64) {
                shared.late_frames.fetch_add(hdr.frames as u64, Ordering::Relaxed);
                return;
            }
            shared.local.ring.write_s16le(hdr.first_frame, &pcm);
        }
        // stream ids only grow: a newer stream whose StreamStart is still on its way
        cur if cur.map_or(true, |c| hdr.id > c) => {
            if m.early.len() >= MAX_EARLY_SEGMENTS {
                m.early.remove(0);
            }
            m.early.push((hdr, pcm));
        }
        _ => {} // from a stream that already ended
    }
}

fn apply_media(shared: &Shared, msg: Media) {
    match msg {
        Media::StreamStart { id, sample_rate, timeline, desc } => {
            let mut m = shared.media.lock();
            if m.stream_id != Some(id) {
                shared.local.ring.clear();
                m.stream_id = Some(id);
                shared.local.set_stream_id(id);
                shared.local.set_timeline(Some(timeline), true);
                // segments that beat this StreamStart
                for (hdr, pcm) in std::mem::take(&mut m.early) {
                    if hdr.id == id {
                        shared.local.ring.write_s16le(hdr.first_frame, &pcm);
                    } else if hdr.id > id {
                        m.early.push((hdr, pcm));
                    }
                }
                log::info!("guest: stream {id} '{desc}' at {sample_rate} Hz");
            } else {
                shared.local.set_timeline(Some(timeline), false);
            }
            drop(m);
            let mut v = shared.view.lock();
            v.source = Some(desc);
            v.sample_rate = sample_rate;
        }
        Media::Timeline { id, timeline } => {
            if shared.media.lock().stream_id == Some(id) {
                shared.local.set_timeline(Some(timeline), false);
            }
        }
        Media::StreamStop { id } => {
            let mut m = shared.media.lock();
            if m.stream_id == Some(id) {
                m.stream_id = None;
                m.early.retain(|(h, _)| h.id > id);
                shared.local.set_timeline(None, false);
                drop(m);
                shared.view.lock().source = None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline::Timeline;

    fn shared() -> Shared {
        Shared {
            view: Mutex::new(GuestView::default()),
            sync: Mutex::new(ClockSync::new()),
            local: PlayerShared::new(PcmRing::new(4800)),
            media: Mutex::new(MediaState::default()),
            late_frames: AtomicU64::new(0),
            stop: AtomicBool::new(false),
            host_away: AtomicBool::new(false),
            name: "t".into(),
            platform: "test".into(),
        }
    }

    fn seg(id: u32, first_frame: u64, frames: u32) -> (SegmentHeader, Vec<u8>) {
        (SegmentHeader { id, first_frame, frames }, vec![0x10; frames as usize * 4])
    }

    fn start(id: u32) -> Media {
        Media::StreamStart { id, sample_rate: 48_000, timeline: Timeline::new(0, 48_000.0), desc: "x".into() }
    }

    /// As if the output callback had played up to `pos` of the current stream.
    fn playing_at(s: &Shared, pos: i64) {
        s.local.position_frame.store(pos, Ordering::Relaxed);
        s.local.position_generation.store(s.local.render.read().generation, Ordering::Relaxed);
    }

    fn has(s: &Shared, f: i64) -> bool {
        s.local.ring.with_reader(|r| r.frame(f).is_some())
    }

    #[test]
    fn segment_before_its_stream_start_is_kept() {
        let s = shared();
        let (h, p) = seg(5, 100, 10);
        apply_segment(&s, h, p); // beat its StreamStart
        assert!(!has(&s, 100));
        apply_media(&s, start(5));
        assert!(has(&s, 100) && has(&s, 109));
        assert!(s.media.lock().early.is_empty());
    }

    #[test]
    fn late_and_stale_segments_are_not_played() {
        let s = shared();
        apply_media(&s, start(5));
        playing_at(&s, 500);
        let (h, p) = seg(5, 100, 10); // ends long before the play position
        apply_segment(&s, h, p);
        assert!(!has(&s, 100));
        assert_eq!(s.late_frames.load(Ordering::Relaxed), 10);
        let (h, p) = seg(4, 600, 10); // an earlier stream's straggler
        apply_segment(&s, h, p);
        assert!(!has(&s, 600) && s.media.lock().early.is_empty());
        let (h, p) = seg(5, 600, 10);
        apply_segment(&s, h, p);
        assert!(has(&s, 600));
    }

    #[test]
    fn a_new_stream_starts_whole_after_another_was_playing() {
        let s = shared();
        apply_media(&s, start(5));
        playing_at(&s, 1_000_000); // 20 s into the previous track
        apply_media(&s, Media::StreamStop { id: 5 });
        apply_media(&s, start(6));
        let (h, p) = seg(6, 0, 10); // the new track's first chunk, before any callback ran
        apply_segment(&s, h, p);
        assert!(has(&s, 0), "the opening of the new stream must not be taken for late audio");
        assert_eq!(s.late_frames.load(Ordering::Relaxed), 0);
    }
}
