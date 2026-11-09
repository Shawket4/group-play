//! Headless Group Play peer for testing against the app (and for a laptop as a speaker).
//!
//!   cargo run --release --example cli -- join GPLAY1:...     # speaker
//!   cargo run --release --example cli -- host [clicks|FILE]  # host, prints the ticket
//!
//! Prints a status line every second. Audio goes to the default output device if there is one.
//! `GP_KEY=<0-255>`: a fixed identity (the same id every run), for testing remembered sessions.
//! `host none` hosts without playing anything (the app's guest drives nothing; use for tuning).

use std::time::Duration;
use group_play_core::guest::{guest_status, Guest};
use group_play_core::host::Host;
use group_play_core::source::{Clicks, FileSource};
use group_play_core::ticket::Ticket;

#[tokio::main(flavor = "multi_thread", worker_threads = 3)]
async fn main() -> anyhow::Result<()> {
    group_play_core::logging::init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let secs: u64 = std::env::var("GP_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(3600);
    let key: Option<[u8; 32]> = std::env::var("GP_KEY").ok().and_then(|s| s.parse::<u8>().ok()).map(|b| [b; 32]);
    match args.first().map(|s| s.as_str()) {
        Some("join") => {
            let t = Ticket::decode(args.get(1).expect("ticket"))?;
            println!("joining {} at {:?} relay={:?}", t.host_name, t.addrs, t.relay);
            let g = Guest::join(t, "cli".into(), std::env::consts::OS.into(), key, false).await?;
            for _ in 0..secs {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let v = g.view();
                let st = guest_status(&g);
                println!(
                    "{} path={} rtt={:.1}ms | sync off={:.2}ms rtt={:.2}ms skew={:.1}ppm n={} | src={:?} buf={:.0}ms err={:.2}ms underrun={:.0}ms jumps={} delay={:.2}ms lat={:.1}ms",
                    v.state, v.path, v.path_rtt_ms, st.sync_offset_ms, st.rtt_ms, st.skew_ppm, v.sync.samples,
                    v.source, st.buffer_ms, st.err_ms, st.underrun_ms, st.jumps, st.delay_ms, st.latency_ms
                );
            }
            g.leave().await;
        }
        Some("host") => {
            let h = Host::start("cli-host".into(), true, key).await?;
            println!("ticket: {}", h.ticket().encode());
            match args.get(1).map(|s| s.as_str()) {
                None | Some("clicks") => h.play_pull(Box::new(Clicks::new(48_000, 120.0)))?,
                Some("none") => {}
                Some(path) => h.play_pull(Box::new(FileSource::open(path)?))?,
            }
            for _ in 0..secs {
                tokio::time::sleep(Duration::from_secs(1)).await;
                for p in h.snapshot().peers {
                    if let Some(s) = p.status {
                        println!("{} {} {} connected={} rtt={:.1}ms off={:.2}ms buf={:.0}ms err={:.2}ms delay={:.2}ms", p.name, p.platform, p.path, p.connected, s.rtt_ms, s.sync_offset_ms, s.buffer_ms, s.err_ms, s.delay_ms);
                    }
                }
            }
            h.shutdown().await;
        }
        _ => eprintln!("usage: cli join TICKET | cli host [clicks|FILE]"),
    }
    Ok(())
}
