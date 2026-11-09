//! Maps source frame numbers to host time and back.
//!
//! `host_ns(f) = anchor_host_ns + (f - anchor_frame) * 1e9 / rate`. The host owns it and
//! re-anchors it (keeping it continuous) when it adjusts `rate` to follow a capture clock.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Timeline {
    pub anchor_frame: u64,
    pub anchor_host_ns: i64,
    /// Source frames per second of host time (nominally the sample rate).
    pub rate: f64,
}

impl Timeline {
    pub fn new(start_host_ns: i64, rate: f64) -> Self {
        Self { anchor_frame: 0, anchor_host_ns: start_host_ns, rate }
    }

    pub fn host_ns_at(&self, frame: f64) -> f64 {
        self.anchor_host_ns as f64 + (frame - self.anchor_frame as f64) * 1e9 / self.rate
    }

    pub fn frame_at(&self, host_ns: f64) -> f64 {
        self.anchor_frame as f64 + (host_ns - self.anchor_host_ns as f64) * self.rate / 1e9
    }

    /// Same mapping up to `frame`, new rate after it.
    pub fn rerated(&self, frame: u64, rate: f64) -> Self {
        Self { anchor_frame: frame, anchor_host_ns: self.host_ns_at(frame as f64).round() as i64, rate }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rerate_is_continuous() {
        let t = Timeline::new(1_000_000_000, 48_000.0);
        assert_eq!(t.frame_at(2_000_000_000.0), 48_000.0);
        let t2 = t.rerated(96_000, 48_001.0);
        assert!((t2.host_ns_at(96_000.0) - t.host_ns_at(96_000.0)).abs() < 1.0);
        assert!(t2.host_ns_at(96_000.0 + 48_001.0) - t2.host_ns_at(96_000.0) - 1e9 < 1.0);
    }
}
