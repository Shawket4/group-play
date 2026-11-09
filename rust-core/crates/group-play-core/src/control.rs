//! The playback controller: which source frame each output frame should play.
//!
//! For every audio callback we know (from the backend) the local time the first frame will
//! reach the DAC. Through the clock estimate and the timeline that gives the source frame that
//! *should* be heard then. The read position follows that target smoothly: its speed is the
//! target's own slope (which already contains clock skew and the sample-rate ratio) plus a small
//! correction, at most ±0.2 % (≈3 cents, inaudible), that pulls the remaining error to zero.
//! A big error (start, stall, seek, clock step) jumps instead.

use super::sync::ClockEstimate;
use super::timeline::Timeline;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Plan {
    /// Source frame for the first output frame.
    pub start: f64,
    /// Source frames to advance per output frame.
    pub step: f64,
    /// Target minus actual, in ns, before this callback's correction (positive = behind).
    pub err_ns: f64,
    pub jumped: bool,
}

pub struct Controller {
    pos: f64,
    active: bool,
    /// Errors above this jump instead of slewing.
    hard_ns: f64,
    /// Time constant to pull a small error to zero.
    tau_s: f64,
    max_corr: f64,
}

impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self { pos: 0.0, active: false, hard_ns: 25e6, tau_s: 1.5, max_corr: 0.002 }
    }

    pub fn reset(&mut self) {
        self.active = false;
    }

    /// `p0`: local ns when output frame 0 of this callback is heard; `n` frames at `out_rate`.
    /// `delay_ns`: extra delay for this device (user calibration), positive = later.
    pub fn plan(&mut self, p0: i64, n: usize, out_rate: f64, clock: &ClockEstimate, tl: &Timeline, delay_ns: f64) -> Plan {
        let dur = n as f64 * 1e9 / out_rate;
        let h0 = clock.host_from_local(p0) - delay_ns;
        let h1 = clock.host_from_local(p0 + dur as i64) - delay_ns;
        let f0 = tl.frame_at(h0);
        let f1 = tl.frame_at(h1);
        let slope = if n > 0 { (f1 - f0) / n as f64 } else { tl.rate / out_rate };
        let err_frames = f0 - self.pos;
        let err_ns = err_frames / tl.rate * 1e9;
        let mut jumped = false;
        if !self.active || err_ns.abs() > self.hard_ns {
            self.pos = f0;
            self.active = true;
            jumped = true;
        }
        let corr = if jumped { 0.0 } else { (err_ns / 1e9 / self.tau_s).clamp(-self.max_corr, self.max_corr) };
        let step = slope * (1.0 + corr);
        let start = self.pos;
        self.pos += step * n as f64;
        Plan { start, step, err_ns: if jumped { 0.0 } else { err_ns }, jumped }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locks_to_target_and_follows_skew() {
        let mut c = Controller::new();
        let tl = Timeline::new(1_000_000_000, 48_000.0);
        // guest clock runs 60 ppm slow relative to host, plus a fixed offset
        let clock = ClockEstimate { offset_ns: 3e9, skew: 60e-6, ref_local: 0, min_rtt_ns: 1_000_000, samples: 10, valid: true };
        let out_rate = 44_100.0;
        let n = 441; // 10 ms
        let mut p0 = 0i64;
        let mut last = None;
        for _ in 0..3000 {
            let plan = c.plan(p0, n, out_rate, &clock, &tl, 0.0);
            last = Some(plan);
            p0 += 10_000_000;
        }
        let plan = last.unwrap();
        assert!(plan.err_ns.abs() < 1_000.0, "err {} ns", plan.err_ns); // within 1 µs
        let expected_step = 48_000.0 / 44_100.0 * (1.0 + 60e-6);
        assert!((plan.step / expected_step - 1.0).abs() < 1e-6);
    }

    #[test]
    fn small_clock_step_is_slewed_not_jumped() {
        let mut c = Controller::new();
        let tl = Timeline::new(0, 48_000.0);
        let mut clock = ClockEstimate { offset_ns: 0.0, skew: 0.0, ref_local: 0, min_rtt_ns: 0, samples: 1, valid: true };
        let mut p0 = 0i64;
        for _ in 0..100 {
            c.plan(p0, 480, 48_000.0, &clock, &tl, 0.0);
            p0 += 10_000_000;
        }
        clock.offset_ns += 4e6; // the estimate moves by 4 ms
        let plan = c.plan(p0, 480, 48_000.0, &clock, &tl, 0.0);
        assert!(!plan.jumped);
        assert!((plan.err_ns - 4e6).abs() < 1e3);
        assert!((plan.step - 1.002).abs() < 1e-9, "max correction speed");
        // converges within ~8 s
        let mut err = plan.err_ns;
        for _ in 0..800 {
            p0 += 10_000_000;
            err = c.plan(p0, 480, 48_000.0, &clock, &tl, 0.0).err_ns;
        }
        assert!(err.abs() < 100_000.0, "residual {err}");
    }

    #[test]
    fn big_error_jumps() {
        let mut c = Controller::new();
        let tl = Timeline::new(0, 48_000.0);
        let clock = ClockEstimate::identity();
        c.plan(0, 480, 48_000.0, &clock, &tl, 0.0);
        let plan = c.plan(10_000_000, 480, 48_000.0, &clock, &tl, 100e6); // user adds 100 ms delay
        assert!(plan.jumped);
        assert!((plan.start - (480.0 - 4800.0)).abs() < 1e-6);
    }
}
