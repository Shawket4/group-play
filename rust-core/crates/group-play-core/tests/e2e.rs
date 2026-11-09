//! Host and guest in one process over real iroh connections (direct, loopback/LAN).
//! Both share one clock, so a correct sync estimate is ~0 and both must render the same frame
//! at the same instant.

use std::io::Write;
use std::os::fd::IntoRawFd;
use std::sync::atomic::Ordering;
use std::time::Duration;
use group_play_core::clock::now_ns;
use group_play_core::guest::Guest;
use group_play_core::host::Host;
use group_play_core::player::Renderer;
use group_play_core::source::Clicks;

async fn wait_until(mut f: impl FnMut() -> bool, secs: u64) -> bool {
    let deadline = now_ns() + secs as i64 * 1_000_000_000;
    while now_ns() < deadline {
        if f() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

fn frame_heard_at(shared: &std::sync::Arc<group_play_core::player::PlayerShared>, p0: i64) -> i64 {
    let mut r = Renderer::new(shared.clone(), 48_000.0, 2);
    let mut buf = vec![0.0f32; 960];
    r.render(&mut buf, p0);
    shared.position_frame.load(Ordering::Relaxed)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn guest_plays_in_lockstep_with_host() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), true, None).await.unwrap();
    host.play_pull(Box::new(Clicks::new(48_000, 120.0))).unwrap();
    let ticket = host.ticket();
    assert!(!ticket.addrs.is_empty(), "ticket has addresses: {ticket:?}");

    let guest = Guest::join(ticket, "Guest".into(), "linux".into(), None, false).await.unwrap();
    let ok = wait_until(|| guest.view().state == "connected" && guest.view().sync.samples >= 20, 15).await;
    assert!(ok, "guest connected and synced: {:?}", guest.view());

    let est = guest.view().sync;
    assert!(est.offset_ns.abs() < 1_000_000.0, "same clock => offset ~0, got {} ns", est.offset_ns);

    // wait for audio to be buffered on the guest
    let ok = wait_until(|| guest.local().ring.highest() > 48_000, 10).await;
    assert!(ok, "guest received audio");

    // both render the frame for the same instant
    let p0 = now_ns() + 200_000_000;
    let h = frame_heard_at(host.local(), p0);
    let g = frame_heard_at(guest.local(), p0);
    assert!(h > 0 && g > 0, "both playing: host {h}, guest {g}");
    assert!((h - g).abs() <= 48, "host frame {h} vs guest frame {g} (must be within 1 ms)");

    // the host's per-peer view sees the guest's status reports
    let ok = wait_until(|| host.snapshot().peers.iter().any(|p| p.connected && p.status.is_some()), 5).await;
    assert!(ok, "host sees guest status");

    // host-side calibration reaches the guest
    let peer = host.snapshot().peers[0].id.clone();
    host.set_peer_delay(&peer, 42.0);
    let ok = wait_until(|| guest.local().assigned_delay_ns.load(Ordering::Relaxed) == 42_000_000, 5).await;
    assert!(ok, "delay command applied on guest");

    guest.leave().await;
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn live_fd_capture_streams_and_keeps_rate() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), false, None).await.unwrap();
    host.set_playout_delay_ms(250);
    let (r, mut w) = std::io::pipe().unwrap();
    // a "capture" producing 48 kHz stereo in real time, 10 ms at a time, with a 50 ppm fast clock
    let writer = std::thread::spawn(move || {
        let start = now_ns();
        let mut written: u64 = 0;
        let rate = 48_000.0 * (1.0 + 50e-6);
        for _ in 0..900 {
            let due = ((now_ns() - start) as f64 / 1e9 * rate) as u64;
            if due > written {
                let n = (due - written) as usize;
                let buf: Vec<u8> = (0..n).flat_map(|i| {
                    let v = (((written as usize + i) % 100) as i16 * 100).to_le_bytes();
                    [v[0], v[1], v[0], v[1]]
                }).collect();
                if w.write_all(&buf).is_err() {
                    return;
                }
                written = due;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    });
    host.play_fd(r.into_raw_fd(), 48_000, 2, "test capture".into()).unwrap();
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into(), None, false).await.unwrap();
    let ok = wait_until(|| guest.local().ring.highest() > 48_000 * 3, 15).await;
    assert!(ok, "guest received ~3 s of live audio, has {}", guest.local().ring.highest());
    let p0 = now_ns();
    let h = frame_heard_at(host.local(), p0);
    let g = frame_heard_at(guest.local(), p0);
    assert!((h - g).abs() <= 48, "live: host {h} vs guest {g}");
    // what plays now must already be on the guest, with roughly the playout delay of margin
    let margin_ms = (guest.local().ring.highest() as f64 - g as f64) / 48.0;
    assert!(margin_ms > 100.0 && margin_ms < 600.0, "margin {margin_ms} ms");
    // a bigger buffer mid-stream: everyone moves together, and the margin grows to match
    host.set_playout_delay_ms(700);
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let p1 = now_ns();
    let (h, g) = (frame_heard_at(host.local(), p1), frame_heard_at(guest.local(), p1));
    assert!((h - g).abs() <= 48, "after raising the delay: host {h} vs guest {g}");
    let margin_ms = (guest.local().ring.highest() as f64 - g as f64) / 48.0;
    assert!(margin_ms > 500.0 && margin_ms < 1000.0, "margin after raising {margin_ms} ms");
    writer.join().unwrap();
    guest.leave().await;
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn guest_joins_before_the_stream_starts() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), true, None).await.unwrap();
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into(), None, false).await.unwrap();
    let ok = wait_until(|| guest.view().state == "connected" && guest.view().sync.samples >= 20, 15).await;
    assert!(ok, "connected and synced first");
    tokio::time::sleep(Duration::from_millis(500)).await;
    host.play_pull(Box::new(Clicks::new(48_000, 120.0))).unwrap();
    let n_before = guest.view().sync.samples;
    let ok = wait_until(|| guest.local().ring.highest() > 48_000, 10).await;
    assert!(ok, "guest received audio after joining first (has {})", guest.local().ring.highest());
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(guest.view().sync.samples > n_before, "pings keep flowing during the burst");
    guest.leave().await;
    host.shutdown().await;
}

/// The whole tuning loop over real connections, with a simulated room: the guest's speaker is
/// really 17 ms later than it reports, the host's is exact. A "microphone" thread renders both
/// devices the way their speakers would sound and streams the mix into the tuning pipe, 30 ms
/// late like a real input path. Tuning must delay the host by 17 ms and leave the guest at 0,
/// after which both sound the same frame at the same instant.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn tuning_lines_up_a_late_speaker() {
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    group_play_core::logging::init();
    let host = Host::start("Host".into(), true, None).await.unwrap();
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into(), None, false).await.unwrap();
    let ok = wait_until(|| guest.view().state == "connected" && guest.view().sync.samples >= 20, 15).await;
    assert!(ok, "connected and synced");
    let ok = wait_until(|| host.snapshot().peers.iter().any(|p| p.connected), 5).await;
    assert!(ok, "host sees the guest");

    const GUEST_LATE_NS: i64 = 17_000_000;
    const INPUT_LAG_NS: i64 = 30_000_000;
    let (r, mut w) = std::io::pipe().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let mic = {
        let (hs, gs, stop) = (host.local().clone(), guest.local().clone(), stop.clone());
        std::thread::spawn(move || {
            let mut hr = Renderer::new(hs, 48_000.0, 2);
            let mut gr = Renderer::new(gs, 48_000.0, 2);
            let (mut hb, mut gb) = (vec![0.0f32; 960], vec![0.0f32; 960]);
            let mut t = now_ns() - INPUT_LAG_NS;
            while !stop.load(Ordering::Relaxed) {
                // the block of sound in the air during [t, t + 10 ms), available INPUT_LAG later
                while now_ns() < t + 10_000_000 + INPUT_LAG_NS {
                    std::thread::sleep(Duration::from_millis(2));
                }
                hr.render(&mut hb, t);
                gr.render(&mut gb, t - GUEST_LATE_NS); // what it plays now it thinks was heard 17 ms ago
                let bytes: Vec<u8> = (0..480)
                    .flat_map(|i| (((hb[2 * i] + 0.3 * gb[2 * i]) * 0.8 * 32767.0) as i16).to_le_bytes())
                    .collect();
                if w.write_all(&bytes).is_err() {
                    return;
                }
                t += 10_000_000;
            }
        })
    };
    let job = host.tune_start(r.into_raw_fd(), 48_000, 1).unwrap();
    assert!(host.is_tuning());
    let report = tokio::task::spawn_blocking(move || job.run()).await.unwrap().unwrap();
    stop.store(true, Ordering::Relaxed);
    mic.join().unwrap();
    assert!(!host.is_tuning());
    let late = report.devices[1].late_ms.expect("guest heard");
    assert!((late - 17.0).abs() < 0.5, "measured {late} ms, report {report:?}");
    assert!((host.self_delay_ms() - 17.0).abs() < 0.5, "host delay {}", host.self_delay_ms());
    let ok = wait_until(|| guest.local().assigned_delay_ns.load(Ordering::Relaxed).abs() < 500_000, 5).await;
    assert!(ok, "guest delay {}", guest.local().assigned_delay_ns.load(Ordering::Relaxed));
    assert!(host.snapshot().peers[0].timing.tuned);
    // gates are gone: both play everything again
    host.play_pull(Box::new(Clicks::new(48_000, 120.0))).unwrap();
    let ok = wait_until(|| guest.local().ring.highest() > 48_000, 10).await;
    assert!(ok, "guest received clicks after tuning");
    // what each speaker sounds at real time T: host renders T exactly, the guest renders T - 17 ms
    let t = now_ns() + 200_000_000;
    let h = frame_heard_at(host.local(), t);
    let g = frame_heard_at(guest.local(), t - GUEST_LATE_NS);
    assert!((h - g).abs() <= 48, "after tuning: host frame {h}, guest frame {g}");
    guest.leave().await;
    host.shutdown().await;
}

/// A remembered session: same identity => same host id; when the host ends and starts again,
/// the guest waits instead of giving up and rejoins by itself, and keeps its tuned delay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remembered_session_rejoins_after_the_host_restarts() {
    group_play_core::logging::init();
    let host_key = [7u8; 32];
    let guest_key = [9u8; 32];
    let host = Host::start("Host".into(), true, Some(host_key)).await.unwrap();
    let ticket = host.ticket();
    let guest = Guest::join(ticket.clone(), "Guest".into(), "linux".into(), Some(guest_key), false).await.unwrap();
    let ok = wait_until(|| guest.view().state == "connected", 15).await;
    assert!(ok, "connected");
    assert!(guest.view().host_ticket.is_some(), "welcome carries the ticket to remember");
    let ok = wait_until(|| host.snapshot().peers.iter().any(|p| p.connected), 5).await;
    assert!(ok);
    let guest_id = host.snapshot().peers[0].id.clone();
    host.set_peer_delay(&guest_id, 12.0);
    let ok = wait_until(|| guest.local().assigned_delay_ns.load(Ordering::Relaxed) == 12_000_000, 5).await;
    assert!(ok, "delay applied");

    host.shutdown().await;
    let ok = wait_until(|| guest.view().state == "waiting", 10).await;
    assert!(ok, "guest waits for the host, state {}", guest.view().state);

    let host2 = Host::start("Host".into(), true, Some(host_key)).await.unwrap();
    assert_eq!(host2.ticket().endpoint_id, ticket.endpoint_id, "same identity, same id");
    assert_eq!(host2.ticket().addrs, ticket.addrs, "same port, same addresses");
    host2.set_known_timings(vec![(guest_id.clone(), group_play_core::host::Timing { delay_ms: 12.0, tuned: true })]);
    let ok = wait_until(|| guest.view().state == "connected", 30).await;
    assert!(ok, "guest rejoined by itself, state {}", guest.view().state);
    let ok = wait_until(|| host2.snapshot().peers.iter().any(|p| p.connected && p.id == guest_id), 5).await;
    assert!(ok, "same guest id");
    assert_eq!(guest.local().assigned_delay_ns.load(Ordering::Relaxed), 12_000_000, "remembered delay re-sent");
    guest.leave().await;
    host2.shutdown().await;
}

/// A guest with a stable identity reconnects before the host noticed the old connection die:
/// the old connection's cleanup must not mark the new one as gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn reconnect_with_the_same_identity_stays_connected() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), true, None).await.unwrap();
    let key = [5u8; 32];
    let old = Guest::join(host.ticket(), "Guest".into(), "linux".into(), Some(key), false).await.unwrap();
    let ok = wait_until(|| host.snapshot().peers.iter().any(|p| p.connected), 10).await;
    assert!(ok, "first connection");
    let new = Guest::join(host.ticket(), "Guest".into(), "linux".into(), Some(key), false).await.unwrap();
    let ok = wait_until(|| new.view().state == "connected", 10).await;
    assert!(ok, "second connection");
    old.leave().await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let peers = host.snapshot().peers;
    assert_eq!(peers.len(), 1, "one entry per identity");
    assert!(peers[0].connected, "the newer connection is still connected");
    new.leave().await;
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn eq_reaches_every_guest_including_late_joiners() {
    use group_play_core::eq::{EqSettings, BANDS};
    group_play_core::logging::init();
    let host = Host::start("Host".into(), false, None).await.unwrap();
    let bass = EqSettings { enabled: true, boost_db: 3.0, bands_db: [6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0] };
    host.set_eq(bass); // before anyone joins
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into(), None, false).await.unwrap();
    assert!(wait_until(|| guest.local().eq() == bass, 10).await, "a guest joining later gets the EQ");
    assert_eq!(host.local().eq(), bass, "the host plays through it too");
    let flat = EqSettings { enabled: false, boost_db: 0.0, bands_db: [0.0; BANDS] };
    host.set_eq(flat);
    assert!(wait_until(|| guest.local().eq() == flat, 10).await, "a change reaches a connected guest");
    guest.leave().await;
    host.shutdown().await;
}
