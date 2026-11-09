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
    let host = Host::start("Host".into(), true).await.unwrap();
    host.play_pull(Box::new(Clicks::new(48_000, 120.0))).unwrap();
    let ticket = host.ticket();
    assert!(!ticket.addrs.is_empty(), "ticket has addresses: {ticket:?}");

    let guest = Guest::join(ticket, "Guest".into(), "linux".into()).await.unwrap();
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
    let ok = wait_until(|| guest.local().delay_ns.load(Ordering::Relaxed) == 42_000_000, 5).await;
    assert!(ok, "delay command applied on guest");

    guest.leave().await;
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn live_fd_capture_streams_and_keeps_rate() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), false).await.unwrap();
    host.set_playout_delay_ms(250);
    let (r, mut w) = std::io::pipe().unwrap();
    // a "capture" producing 48 kHz stereo in real time, 10 ms at a time, with a 50 ppm fast clock
    let writer = std::thread::spawn(move || {
        let start = now_ns();
        let mut written: u64 = 0;
        let rate = 48_000.0 * (1.0 + 50e-6);
        for _ in 0..600 {
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
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into()).await.unwrap();
    let ok = wait_until(|| guest.local().ring.highest() > 48_000 * 3, 15).await;
    assert!(ok, "guest received ~3 s of live audio, has {}", guest.local().ring.highest());
    let p0 = now_ns();
    let h = frame_heard_at(host.local(), p0);
    let g = frame_heard_at(guest.local(), p0);
    assert!((h - g).abs() <= 48, "live: host {h} vs guest {g}");
    // what plays now must already be on the guest, with roughly the playout delay of margin
    let margin_ms = (guest.local().ring.highest() as f64 - g as f64) / 48.0;
    assert!(margin_ms > 100.0 && margin_ms < 600.0, "margin {margin_ms} ms");
    writer.join().unwrap();
    guest.leave().await;
    host.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn guest_joins_before_the_stream_starts() {
    group_play_core::logging::init();
    let host = Host::start("Host".into(), true).await.unwrap();
    let guest = Guest::join(host.ticket(), "Guest".into(), "linux".into()).await.unwrap();
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
