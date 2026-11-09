//! Acoustic tuning: measure how late each phone really is, by ear.
//!
//! Every phone reports when its audio reaches the speaker (AAudio presentation timestamps,
//! AVAudioSession latency), but phones add processing they never report (speaker DSP, codec
//! buffers, Bluetooth), and that differs per model and route. Samsung's Group Play could ignore
//! this because it only ran on Samsung phones with known latencies. We measure instead:
//!
//! 1. Every device (the host first) plays a short chirp in its own time slot. All devices get the
//!    same calibration stream; a [`Gate`] keeps each one silent outside its slot.
//! 2. The host's microphone records the whole sequence.
//! 3. The chirp arrivals in that one recording give each device's lateness relative to the host.
//!    The host's own input latency is common to every chirp, so it cancels.
//!
//! Each device then gets a delay that lines its sound up with the latest device.

use super::source::PullSource;
use anyhow::Result;
use serde::{Deserialize, Serialize};

pub const RATE: u32 = 48_000;
/// Chirp: a 60 ms linear sweep from 1 to 6 kHz. Phone speakers are weak below ~700 Hz and some
/// microphone paths are band-limited at 8 kHz; the 5 kHz sweep gives ~0.2 ms resolution.
const CHIRP_S: f64 = 0.060;
const F0: f64 = 1_000.0;
const F1: f64 = 6_000.0;
const AMPLITUDE: f32 = 0.7;
/// One device's slot. Devices more than ±SLOT/2 off (beyond Bluetooth) cannot be told apart.
const SLOT_S: f64 = 0.6;
/// Silence before the first slot (controllers lock, gates reach the guests).
const LEAD_S: f64 = 0.5;
const TAIL_S: f64 = 0.4;
/// A chirp counts as heard when its correlation peak is this many times the noise floor.
const MIN_SNR: f64 = 5.0;
/// Rounds that disagree by more than this are reported as unsteady.
const MAX_SPREAD_MS: f64 = 4.0;

/// Which part of a calibration stream a device may play. Outside its slots it is silent.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Gate {
    pub stream_id: u32,
    pub origin: u64,
    pub slot_frames: u64,
    pub slots: u32,
    pub index: u32,
    pub rounds: u32,
}

impl Gate {
    pub fn audible(&self, frame: f64) -> bool {
        if frame < self.origin as f64 {
            return false;
        }
        let rel = (frame - self.origin as f64) as u64;
        let period = self.slot_frames * self.slots as u64;
        if period == 0 || rel >= period * self.rounds as u64 {
            return false;
        }
        (rel % period) / self.slot_frames == self.index as u64
    }
}

/// The slot layout of one tuning run, in stream frames at [`RATE`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Plan {
    pub slots: u32,
    pub rounds: u32,
    pub origin: u64,
    pub slot_frames: u64,
}

impl Plan {
    /// `slots` = devices taking part, the host being slot 0.
    pub fn new(slots: u32) -> Self {
        let slots = slots.max(1);
        let rounds = if slots <= 3 { 3 } else { 2 };
        Self { slots, rounds, origin: (LEAD_S * RATE as f64) as u64, slot_frames: (SLOT_S * RATE as f64) as u64 }
    }

    pub fn frame_of(&self, round: u32, slot: u32) -> u64 {
        self.origin + (round as u64 * self.slots as u64 + slot as u64) * self.slot_frames
    }

    pub fn total_frames(&self) -> u64 {
        self.frame_of(self.rounds, 0) + (TAIL_S * RATE as f64) as u64
    }

    pub fn gate(&self, stream_id: u32, index: u32) -> Gate {
        Gate { stream_id, origin: self.origin, slot_frames: self.slot_frames, slots: self.slots, index, rounds: self.rounds }
    }

    pub fn seconds(&self) -> f64 {
        self.total_frames() as f64 / RATE as f64
    }
}

/// The chirp at `rate`, in phase (`quadrature` = false) or 90° shifted. Raised-cosine edges.
pub fn chirp(rate: f64, quadrature: bool) -> Vec<f32> {
    let n = (CHIRP_S * rate).round() as usize;
    let edge = (0.005 * rate) as usize;
    let k = (F1 - F0) / CHIRP_S;
    (0..n)
        .map(|i| {
            let t = i as f64 / rate;
            let phase = 2.0 * std::f64::consts::PI * (F0 * t + 0.5 * k * t * t);
            let w = if i < edge {
                0.5 - 0.5 * (std::f64::consts::PI * i as f64 / edge as f64).cos()
            } else if i + edge >= n {
                0.5 - 0.5 * (std::f64::consts::PI * (n - 1 - i) as f64 / edge as f64).cos()
            } else {
                1.0
            };
            (w * if quadrature { phase.cos() } else { phase.sin() }) as f32
        })
        .collect()
}

/// The calibration stream: a chirp at the start of every slot. Gates decide who plays which.
pub struct TuneSource {
    plan: Plan,
    chirp: Vec<f32>,
    frame: u64,
}

impl TuneSource {
    pub fn new(plan: Plan) -> Self {
        Self { plan, chirp: chirp(RATE as f64, false), frame: 0 }
    }
}

impl PullSource for TuneSource {
    fn sample_rate(&self) -> u32 {
        RATE
    }
    fn pull(&mut self, out: &mut Vec<i16>, frames: usize) -> Result<usize> {
        let end = self.plan.total_frames();
        let start = self.plan.origin;
        let last = self.plan.frame_of(self.plan.rounds, 0);
        let mut n = 0;
        while n < frames && self.frame < end {
            let f = self.frame;
            let v = if f >= start && f < last {
                let in_slot = ((f - start) % self.plan.slot_frames) as usize;
                self.chirp.get(in_slot).map(|s| s * AMPLITUDE).unwrap_or(0.0)
            } else {
                0.0
            };
            let s = (v * 32767.0) as i16;
            out.push(s);
            out.push(s);
            self.frame += 1;
            n += 1;
        }
        Ok(n)
    }
    fn describe(&self) -> String {
        "Tuning".into()
    }
}

/// A microphone recording: mono samples and the host time of sample 0 (an upper bound: the
/// reader only knows when data arrived; the unknown input latency cancels in the analysis).
pub struct Recording {
    pub samples: Vec<f32>,
    pub rate: f64,
    pub anchor_ns: i64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Detection {
    /// Sample index of the chirp's start in the recording (sub-sample).
    pub at: f64,
    pub snr: f64,
}

struct Matched {
    i: Vec<f32>,
    q: Vec<f32>,
}

impl Matched {
    fn new(rate: f64) -> Self {
        Self { i: chirp(rate, false), q: chirp(rate, true) }
    }

    /// Squared envelope of the matched-filter output at `n`.
    fn power(&self, x: &[f32], n: usize) -> f32 {
        let w = &x[n..n + self.i.len()];
        let (mut a, mut b) = (0.0f32, 0.0f32);
        for ((s, ti), tq) in w.iter().zip(&self.i).zip(&self.q) {
            a += s * ti;
            b += s * tq;
        }
        a * a + b * b
    }

    /// The earliest strong chirp arrival in `x[lo..hi]` (the direct sound, not a reflection).
    fn detect(&self, x: &[f32], lo: f64, hi: f64) -> Option<Detection> {
        let len = self.i.len();
        if x.len() <= len {
            return None;
        }
        let lo = lo.max(0.0) as usize;
        let hi = (hi.max(0.0) as usize).min(x.len() - len);
        if lo + 16 >= hi {
            return None;
        }
        // Coarse pass every 4 samples: the envelope's main lobe is ~20 samples wide at 48 kHz.
        const STRIDE: usize = 4;
        let coarse: Vec<f32> = (lo..hi).step_by(STRIDE).map(|n| self.power(x, n)).collect();
        let max = coarse.iter().copied().fold(0.0f32, f32::max);
        if max <= 0.0 {
            return None;
        }
        let mut sorted = coarse.clone();
        sorted.sort_by(|a, b| a.total_cmp(b));
        // Digital silence (some mics start with zeros) must not pass for a quiet room: floor the
        // noise at what -90 dBFS white noise gives through this filter.
        let energy: f32 = self.i.iter().map(|v| v * v).sum();
        let min_floor = 2.0 * 3e-5f32 * 3e-5 * energy;
        let floor = sorted[sorted.len() / 2].max(min_floor);
        let snr = ((max / floor) as f64).sqrt();
        if snr < MIN_SNR {
            return None;
        }
        // first point at half the peak amplitude (a quarter of its power), then climb its lobe
        let mut k = coarse.iter().position(|p| *p >= 0.25 * max)?;
        while k + 1 < coarse.len() && coarse[k + 1] >= coarse[k] {
            k += 1;
        }
        let centre = lo + k * STRIDE;
        let from = centre.saturating_sub(STRIDE * 2).max(lo);
        let to = (centre + STRIDE * 2).min(hi - 1);
        let fine: Vec<(usize, f32)> = (from..=to).map(|n| (n, self.power(x, n).sqrt())).collect();
        let (best, _) = fine.iter().enumerate().max_by(|a, b| a.1 .1.total_cmp(&b.1 .1))?;
        let mut at = fine[best].0 as f64;
        if best > 0 && best + 1 < fine.len() {
            // parabolic peak interpolation on the amplitude envelope
            let (a, b, c) = (fine[best - 1].1 as f64, fine[best].1 as f64, fine[best + 1].1 as f64);
            let d = a - 2.0 * b + c;
            if d.abs() > 1e-12 {
                at += (0.5 * (a - c) / d).clamp(-1.0, 1.0);
            }
        }
        Some(Detection { at, snr })
    }
}

/// What tuning found for one slot.
#[derive(Clone, Debug, PartialEq)]
pub struct SlotResult {
    pub slot: u32,
    /// How much later than the host this device sounds with equal delays, in ms (median over
    /// rounds). None when it was not heard in enough rounds or the rounds disagree.
    pub late_ms: Option<f64>,
    /// Max minus min over the rounds, in ms.
    pub spread_ms: f64,
    pub heard: u32,
    pub snr: f64,
}

/// `expected_ns[round][slot]`: host time each chirp is scheduled to sound, including that
/// device's current delay. Returns one result per slot; slot 0 (the host) is the reference with `late_ms` 0.
pub fn analyze(rec: &Recording, plan: &Plan, expected_ns: &[Vec<f64>]) -> Vec<SlotResult> {
    let m = Matched::new(rec.rate);
    let x = &rec.samples;
    let idx = |t_ns: f64| (t_ns - rec.anchor_ns as f64) / 1e9 * rec.rate;
    let secs = |s: f64| s * rec.rate;

    // 1. The host's own chirps. The anchor is late by the unknown input latency, so look mostly later.
    let host: Vec<Option<Detection>> = (0..plan.rounds)
        .map(|r| {
            let p = idx(expected_ns[r as usize][0]);
            m.detect(x, p - secs(0.15), p + secs(0.35))
        })
        .collect();
    let mut shifts: Vec<f64> = host
        .iter()
        .enumerate()
        .filter_map(|(r, d)| d.map(|d| d.at - idx(expected_ns[r][0])))
        .collect();
    shifts.sort_by(|a, b| a.total_cmp(b));
    let shift = shifts.get(shifts.len() / 2).copied();

    let mut out = Vec::new();
    let host_heard = host.iter().filter(|d| d.is_some()).count() as u32;
    let host_snr = host.iter().flatten().map(|d| d.snr).fold(0.0, f64::max);
    out.push(SlotResult { slot: 0, late_ms: (host_heard >= 1).then_some(0.0), spread_ms: 0.0, heard: host_heard, snr: host_snr });
    let Some(shift) = shift else {
        for slot in 1..plan.slots {
            out.push(SlotResult { slot, late_ms: None, spread_ms: 0.0, heard: 0, snr: 0.0 });
        }
        return out;
    };

    // 2. Everyone else, relative to the host's chirp of the same round.
    let need = if plan.rounds >= 3 { 2 } else { plan.rounds.min(2) };
    for slot in 1..plan.slots {
        let mut lates = Vec::new();
        let mut snr: f64 = 0.0;
        for r in 0..plan.rounds as usize {
            let expect = expected_ns[r][slot as usize];
            let p = idx(expect) + shift;
            let half = secs(SLOT_S / 2.0 - 0.03);
            let Some(d) = m.detect(x, p - half, p + half) else { continue };
            snr = snr.max(d.snr);
            let late_s = match host[r] {
                Some(h) => (d.at - h.at) / rec.rate - (expect - expected_ns[r][0]) / 1e9,
                None => (d.at - p) / rec.rate,
            };
            lates.push(late_s * 1000.0);
        }
        lates.sort_by(|a, b| a.total_cmp(b));
        let heard = lates.len() as u32;
        let spread = if lates.len() >= 2 { lates[lates.len() - 1] - lates[0] } else { 0.0 };
        let late_ms = (heard >= need && spread <= MAX_SPREAD_MS).then(|| median(&lates));
        out.push(SlotResult { slot, late_ms, spread_ms: spread, heard, snr });
    }
    out
}

fn median(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    }
}

/// New delays (ms) that line every device up with the latest one. `current[k]` is slot k's delay
/// now; `late[k]` its lateness relative to the host with delays taken out (what [`analyze`]
/// returns when `expected_ns` includes the current delays; None = not heard). Devices not heard
/// keep their place relative to the host.
pub fn new_delays(current: &[f64], late: &[Option<f64>]) -> Vec<f64> {
    if late.first().copied().flatten().is_none() {
        return current.to_vec(); // without the host's own chirp there is no reference
    }
    let latest = late.iter().flatten().copied().fold(0.0, f64::max);
    late.iter()
        .zip(current)
        .map(|(u, d)| match u {
            Some(u) => latest - u,
            None => d + (latest - current[0]),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Synthesizes what the host's mic hears: each slot's chirp delayed by that device's
    /// lateness, plus a reflection, hum and noise.
    /// `late_ms[slot]`: None = that device does not play at all.
    fn record(plan: &Plan, late_ms: &[Option<f64>], mic_rate: f64, anchor_late_ms: f64) -> (Recording, Vec<Vec<f64>>) {
        let t0 = 5_000_000_000.0; // host time of stream frame 0
        let expected: Vec<Vec<f64>> = (0..plan.rounds)
            .map(|r| (0..plan.slots).map(|s| t0 + plan.frame_of(r, s) as f64 / RATE as f64 * 1e9).collect())
            .collect();
        let rec_start = t0 - 0.2e9; // true host time of mic sample 0
        let n = ((plan.seconds() + 1.0) * mic_rate) as usize;
        let mut x = vec![0.0f32; n];
        let tpl = chirp(mic_rate, false);
        let mut seed = 12345u64;
        for (i, s) in x.iter_mut().enumerate() {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let noise = ((seed >> 33) as f32 / (1u64 << 31) as f32 - 0.5) * 0.05;
            *s = noise + 0.02 * (2.0 * std::f32::consts::PI * 50.0 * i as f32 / mic_rate as f32).sin();
        }
        for (r, row) in expected.iter().enumerate() {
            for (slot, t) in row.iter().enumerate() {
                let Some(late) = late_ms[slot] else { continue };
                let gain = if slot == 0 { 0.8 } else { 0.25 };
                let jitter = ((r * 7 + slot * 3) % 5) as f64 * 0.05; // ±0.1 ms round-to-round
                let at = (t + (late + jitter) * 1e6 - rec_start) / 1e9 * mic_rate;
                for (j, c) in tpl.iter().enumerate() {
                    let k = at as usize + j;
                    if k < n {
                        x[k] += gain * c;
                    }
                    // a weaker reflection 4 ms later
                    let k2 = (at + 0.004 * mic_rate) as usize + j;
                    if k2 < n {
                        x[k2] += 0.4 * gain * c;
                    }
                }
            }
        }
        let anchor = (rec_start + anchor_late_ms * 1e6) as i64;
        (Recording { samples: x, rate: mic_rate, anchor_ns: anchor }, expected)
    }

    #[test]
    fn gate_opens_only_in_own_slot() {
        let p = Plan::new(3);
        let g = p.gate(7, 1);
        assert!(!g.audible(p.frame_of(0, 0) as f64 + 10.0));
        assert!(g.audible(p.frame_of(0, 1) as f64 + 10.0));
        assert!(!g.audible(p.frame_of(0, 2) as f64 + 10.0));
        assert!(g.audible(p.frame_of(2, 1) as f64));
        assert!(!g.audible(p.frame_of(3, 1) as f64), "after the last round");
        assert!(!g.audible(0.0), "lead-in");
    }

    #[test]
    fn source_has_a_chirp_per_slot() {
        let p = Plan::new(2);
        let mut s = TuneSource::new(p);
        let mut out = Vec::new();
        while s.pull(&mut out, 960).unwrap() > 0 {}
        assert_eq!(out.len() as u64, p.total_frames() * 2);
        let energy = |f: u64| out[(f * 2) as usize..(f * 2 + 2000) as usize].iter().map(|v| (*v as i64).abs()).sum::<i64>();
        assert!(energy(p.frame_of(0, 1) + 300) > 0);
        assert_eq!(energy(p.frame_of(0, 1) + 4000), 0);
    }

    #[test]
    fn measures_lateness_to_a_fraction_of_a_millisecond() {
        let plan = Plan::new(3);
        let truth = [0.0, 23.4, -11.7]; // guest 1 late, guest 2 early
        for (rate, anchor_late) in [(48_000.0, 30.0), (44_100.0, 80.0), (16_000.0, 5.0)] {
            let (rec, expected) = record(&plan, &truth.map(Some), rate, anchor_late);
            let res = analyze(&rec, &plan, &expected);
            assert_eq!(res.len(), 3);
            assert_eq!(res[0].late_ms, Some(0.0));
            for k in 1..3 {
                let got = res[k].late_ms.unwrap_or_else(|| panic!("slot {k} not heard at {rate}: {:?}", res[k]));
                assert!((got - truth[k]).abs() < 0.35, "slot {k} at {rate} Hz: got {got}, want {}", truth[k]);
            }
        }
    }

    #[test]
    fn missing_device_is_reported_not_guessed() {
        let plan = Plan::new(2);
        let (rec, expected) = record(&plan, &[Some(0.0), None], 48_000.0, 20.0);
        let res = analyze(&rec, &plan, &expected);
        assert_eq!(res[1].late_ms, None);
        assert_eq!(res[0].late_ms, Some(0.0));
        // digital silence is not a quiet room either
        let zeros = Recording { samples: vec![0.0; 48_000 * 8], rate: 48_000.0, anchor_ns: rec.anchor_ns };
        let res = analyze(&zeros, &plan, &expected);
        assert!(res.iter().all(|r| r.heard == 0), "{res:?}");
    }

    #[test]
    fn delays_line_everyone_up_with_the_latest() {
        // guest 1 is 20 ms late, guest 2 is 5 ms early, nobody had a delay yet
        let d = new_delays(&[0.0, 0.0, 0.0], &[Some(0.0), Some(20.0), Some(-5.0)]);
        assert_eq!(d, vec![20.0, 0.0, 25.0]);
        // measuring again (same intrinsic lateness) keeps them
        let d2 = new_delays(&d, &[Some(0.0), Some(20.0), Some(-5.0)]);
        assert_eq!(d2, d);
        // no reference, no change
        assert_eq!(new_delays(&[3.0, 4.0], &[None, Some(1.0)]), vec![3.0, 4.0]);
        // a device not heard keeps its place relative to the host
        let d3 = new_delays(&[0.0, 7.0], &[Some(0.0), None]);
        assert_eq!(d3, vec![0.0, 7.0]);
        let d4 = new_delays(&[0.0, 7.0, 0.0], &[Some(0.0), None, Some(12.0)]);
        assert_eq!(d4, vec![12.0, 19.0, 0.0]);
    }
}
