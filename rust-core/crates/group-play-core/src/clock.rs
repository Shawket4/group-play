//! One monotonic clock for the whole engine, in nanoseconds.
//!
//! It must be the same clock domain the audio backend uses for its DAC timestamps, so a
//! cpal `playback` instant can be compared with [`now_ns`] directly:
//! - Android/Linux: `CLOCK_MONOTONIC` (cpal's AAudio backend anchors `getTimestamp` to it).
//! - iOS/macOS: `mach_absolute_time` scaled to ns (cpal's CoreAudio backend converts `mHostTime`
//!   the same way). Rust's `Instant` on Darwin uses `CLOCK_UPTIME_RAW`, which is that clock.

#[cfg(any(target_os = "android", target_os = "linux"))]
pub fn now_ns() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime only writes into the timespec we pass.
    let res = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    debug_assert_eq!(res, 0);
    ts.tv_sec as i64 * 1_000_000_000 + ts.tv_nsec as i64
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub fn now_ns() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // CLOCK_UPTIME_RAW == mach_absolute_time() in nanoseconds.
    // SAFETY: as above.
    let res = unsafe { libc::clock_gettime(libc::CLOCK_UPTIME_RAW, &mut ts) };
    debug_assert_eq!(res, 0);
    ts.tv_sec as i64 * 1_000_000_000 + ts.tv_nsec as i64
}

#[cfg(not(any(target_os = "android", target_os = "linux", target_os = "ios", target_os = "macos")))]
pub fn now_ns() -> i64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as i64
}

/// True when cpal's output `playback` timestamps are in the [`now_ns`] domain, so they can be
/// used as-is. Elsewhere (ALSA, PulseAudio...) only `playback - callback` (the latency) is used.
pub const CPAL_SHARES_CLOCK: bool = cfg!(any(target_os = "android", target_os = "ios", target_os = "macos"));

pub const NS_PER_SEC: i64 = 1_000_000_000;

pub fn ms(ns: i64) -> f64 {
    ns as f64 / 1e6
}
