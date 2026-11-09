//! Clock synchronisation between a guest and the host (NTP-style, four timestamps).
//!
//! Every ping gives one sample: guest send time `t0`, host receive `t1`, host send `t2`, guest
//! receive `t3`. Offset (host - guest) is `((t1-t0) + (t2-t3)) / 2`, and its error is bounded by
//! half the round trip, so only the fastest round trips are trusted. A line fitted through those
//! (offset against local time) also gives the skew between the two crystals, which matters:
//! 50 ppm is 3 ms per minute.

use std::collections::VecDeque;

/// One four-timestamp exchange.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SyncSample {
    pub t0: i64,
    pub t1: i64,
    pub t2: i64,
    pub t3: i64,
}

impl SyncSample {
    pub fn rtt(&self) -> i64 {
        (self.t3 - self.t0) - (self.t2 - self.t1)
    }
    pub fn offset(&self) -> f64 {
        ((self.t1 - self.t0) as f64 + (self.t2 - self.t3) as f64) / 2.0
    }
    pub fn local_mid(&self) -> i64 {
        self.t0 + (self.t3 - self.t0) / 2
    }
}

/// The current estimate: host_time = local + offset_at(local).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ClockEstimate {
    /// Offset (host - local) in ns at `ref_local`.
    pub offset_ns: f64,
    /// Skew: d(offset)/d(local), dimensionless (1e-6 = 1 ppm).
    pub skew: f64,
    pub ref_local: i64,
    /// Best round trip in the window, ns.
    pub min_rtt_ns: i64,
    pub samples: usize,
    pub valid: bool,
}

impl ClockEstimate {
    pub fn identity() -> Self {
        Self { valid: true, ..Default::default() }
    }

    pub fn offset_at(&self, local: i64) -> f64 {
        self.offset_ns + self.skew * (local - self.ref_local) as f64
    }

    pub fn host_from_local(&self, local: i64) -> f64 {
        local as f64 + self.offset_at(local)
    }

    pub fn local_from_host(&self, host: f64) -> f64 {
        // host = local + offset_ns + skew * (local - ref)  =>  local = (host - offset_ns + skew*ref) / (1+skew)
        (host - self.offset_ns + self.skew * self.ref_local as f64) / (1.0 + self.skew)
    }
}

pub struct ClockSync {
    window: VecDeque<SyncSample>,
    capacity: usize,
    estimate: ClockEstimate,
}

/// Longest stretch of samples kept. Long enough to measure skew well, short enough to follow
/// thermal drift.
const WINDOW_NS: i64 = 60 * 1_000_000_000;
/// Skew is only fitted once the samples span this much time; before that a short-baseline
/// fit is mostly noise.
const MIN_SKEW_SPAN_NS: i64 = 8 * 1_000_000_000;
/// Phones' crystals are within ~100 ppm of each other; anything bigger is a bad fit.
const MAX_SKEW: f64 = 300e-6;

impl Default for ClockSync {
    fn default() -> Self {
        Self::new()
    }
}

impl ClockSync {
    pub fn new() -> Self {
        Self { window: VecDeque::new(), capacity: 400, estimate: ClockEstimate::default() }
    }

    pub fn estimate(&self) -> ClockEstimate {
        self.estimate
    }

    pub fn add(&mut self, s: SyncSample) {
        if s.rtt() < 0 || s.t3 < s.t0 {
            return; // impossible sample (clock went backwards or host bug)
        }
        self.window.push_back(s);
        let newest = s.local_mid();
        while let Some(front) = self.window.front() {
            if newest - front.local_mid() > WINDOW_NS || self.window.len() > self.capacity {
                self.window.pop_front();
            } else {
                break;
            }
        }
        self.recompute();
    }

    fn recompute(&mut self) {
        if self.window.is_empty() {
            return;
        }
        let min_rtt = self.window.iter().map(|s| s.rtt()).min().unwrap_or(0);
        // Keep the samples whose round trip is close to the best one: their offset error is
        // small. The slack grows a little with the best rtt itself (slow links jitter more).
        let slack = 1_500_000 + min_rtt / 2; // 1.5 ms + rtt/2
        let good: Vec<&SyncSample> = self.window.iter().filter(|s| s.rtt() <= min_rtt + slack).collect();
        let newest = self.window.back().unwrap().local_mid();

        // Weighted by how fast the exchange was.
        let weight = |s: &SyncSample| {
            let excess = (s.rtt() - min_rtt) as f64;
            1.0 / (1.0 + excess / 500_000.0).powi(2)
        };

        let span = good.last().map(|l| l.local_mid()).unwrap_or(newest) - good.first().map(|f| f.local_mid()).unwrap_or(newest);
        let (offset, skew) = if good.len() >= 6 && span >= MIN_SKEW_SPAN_NS {
            // Weighted least squares: offset = a + b * (x - newest)
            let (mut sw, mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0, 0.0);
            for s in &good {
                let w = weight(s);
                let x = (s.local_mid() - newest) as f64;
                let y = s.offset();
                sw += w;
                sx += w * x;
                sy += w * y;
                sxx += w * x * x;
                sxy += w * x * y;
            }
            let denom = sw * sxx - sx * sx;
            if denom.abs() < 1e-9 {
                (sy / sw, 0.0)
            } else {
                let b = ((sw * sxy - sx * sy) / denom).clamp(-MAX_SKEW, MAX_SKEW);
                let a = (sy - b * sx) / sw;
                (a, b)
            }
        } else {
            // Not enough baseline for skew: weighted mean of the good offsets, keeping the
            // previous skew estimate if we had one.
            let skew = if self.estimate.valid { self.estimate.skew } else { 0.0 };
            let (mut sw, mut sy) = (0.0, 0.0);
            for s in &good {
                let w = weight(s);
                // project each sample to `newest` with the known skew
                sy += w * (s.offset() + skew * (newest - s.local_mid()) as f64);
                sw += w;
            }
            (sy / sw, skew)
        };

        self.estimate = ClockEstimate {
            offset_ns: offset,
            skew,
            ref_local: newest,
            min_rtt_ns: min_rtt,
            samples: self.window.len(),
            valid: true,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Simulated host clock: host = local * (1 + skew) + offset.
    fn exchange(local_send: i64, offset: i64, skew: f64, up: i64, down: i64, proc_ns: i64) -> SyncSample {
        let host = |l: i64| (l as f64 * (1.0 + skew)) as i64 + offset;
        let t0 = local_send;
        let t1 = host(t0 + up);
        let t2 = t1 + proc_ns;
        // local time when the host's t2 happens, then + down
        let local_at_t2 = ((t2 - offset) as f64 / (1.0 + skew)) as i64;
        let t3 = local_at_t2 + down;
        SyncSample { t0, t1, t2, t3 }
    }

    #[test]
    fn symmetric_path_gives_exact_offset() {
        let mut cs = ClockSync::new();
        for i in 0..20 {
            cs.add(exchange(1_000_000_000 + i * 100_000_000, 5_000_000_000, 0.0, 2_000_000, 2_000_000, 50_000));
        }
        let e = cs.estimate();
        assert!(e.valid);
        assert!((e.offset_ns - 5_000_000_000.0).abs() < 10_000.0, "offset {}", e.offset_ns);
    }

    #[test]
    fn jittery_samples_are_filtered_by_rtt() {
        let mut cs = ClockSync::new();
        let mut seed = 12345u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as i64
        };
        for i in 0..200 {
            // base 3 ms each way, plus random queuing delay up to 40 ms on either leg
            let up = 3_000_000 + if rnd() % 3 == 0 { rnd() % 40_000_000 } else { rnd() % 300_000 };
            let down = 3_000_000 + if rnd() % 3 == 0 { rnd() % 40_000_000 } else { rnd() % 300_000 };
            cs.add(exchange(10_000_000_000 + i * 100_000_000, -7_000_000_000, 0.0, up, down, 20_000));
        }
        let e = cs.estimate();
        let truth = -7_000_000_000.0;
        let err = (e.offset_at(e.ref_local) - truth).abs();
        assert!(err < 400_000.0, "error {} ns", err);
    }

    #[test]
    fn skew_is_tracked() {
        let mut cs = ClockSync::new();
        let skew = 40e-6; // 40 ppm
        for i in 0..300 {
            cs.add(exchange(1_000_000_000 + i * 200_000_000, 123_456_789, skew, 1_500_000, 1_500_000, 10_000));
        }
        let e = cs.estimate();
        assert!((e.skew - skew).abs() < 2e-6, "skew {}", e.skew);
        // predicted host time 10 s past the last sample is still within 0.2 ms
        let local = e.ref_local + 10_000_000_000;
        let truth = local as f64 * (1.0 + skew) + 123_456_789.0;
        assert!((e.host_from_local(local) - truth).abs() < 200_000.0);
        // inverse mapping round-trips
        let back = e.local_from_host(e.host_from_local(local));
        assert!((back - local as f64).abs() < 1.0);
    }
}
