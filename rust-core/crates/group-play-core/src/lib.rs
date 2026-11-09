//! The Group Play engine: plain Rust. The Dart-facing layer is the `group-play-frb` crate.

pub mod clock;
pub mod control;
pub mod guest;
pub mod host;
pub mod logging;
pub mod net;
pub mod player;
pub mod proto;
pub mod ring;
pub mod source;
pub mod sync;
pub mod ticket;
pub mod timeline;
pub mod tune;

use parking_lot::Mutex;
use std::sync::OnceLock;

pub enum Role {
    Idle,
    Host(host::Host),
    Guest(guest::Guest),
}

pub struct Engine {
    pub rt: tokio::runtime::Runtime,
    pub role: tokio::sync::Mutex<Role>,
    pub device_name: Mutex<String>,
    pub platform: Mutex<String>,
    /// Local calibration and volume survive role changes.
    pub delay_ms: Mutex<f64>,
    pub volume: Mutex<f64>,
    pub host_local_playback: Mutex<bool>,
    pub last_error: Mutex<Option<String>>,
    /// This device's iroh secret key, kept by the app so its id (and the host's ticket) stays
    /// the same across launches. None = a fresh key per session.
    pub identity: Mutex<Option<[u8; 32]>>,
}

static ENGINE: OnceLock<Engine> = OnceLock::new();

pub fn engine() -> &'static Engine {
    ENGINE.get_or_init(|| {
        logging::init();
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .thread_name("gp-net")
            .enable_all()
            .build()
            .expect("tokio runtime");
        Engine {
            rt,
            role: tokio::sync::Mutex::new(Role::Idle),
            device_name: Mutex::new("Phone".into()),
            platform: Mutex::new(std::env::consts::OS.into()),
            delay_ms: Mutex::new(0.0),
            volume: Mutex::new(1.0),
            host_local_playback: Mutex::new(true),
            last_error: Mutex::new(None),
            identity: Mutex::new(None),
        }
    })
}
