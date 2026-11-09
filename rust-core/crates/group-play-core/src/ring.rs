//! Frame-indexed PCM store shared by the network side (writer) and the audio callback
//! (reader). Slot `f % capacity` holds frame `f`; a tag per slot says which frame is really
//! there, so stale or missing frames read as "absent" instead of as the wrong audio.

use parking_lot::Mutex;
use std::sync::Arc;

pub const CHANNELS: usize = 2;

struct Inner {
    samples: Vec<f32>, // interleaved stereo
    tags: Vec<u64>,    // frame index + 1 stored in each slot (0 = empty)
    capacity: usize,
    highest: u64,     // one past the highest frame written
    generation: u64,  // bumped on clear (new stream)
}

#[derive(Clone)]
pub struct PcmRing {
    inner: Arc<Mutex<Inner>>,
}

impl PcmRing {
    pub fn new(capacity_frames: usize) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                samples: vec![0.0; capacity_frames * CHANNELS],
                tags: vec![0; capacity_frames],
                capacity: capacity_frames,
                highest: 0,
                generation: 0,
            })),
        }
    }

    pub fn clear(&self) {
        let mut g = self.inner.lock();
        g.tags.iter_mut().for_each(|t| *t = 0);
        g.highest = 0;
        g.generation += 1;
    }

    /// Writes interleaved stereo i16 starting at `first_frame`.
    pub fn write_i16(&self, first_frame: u64, pcm: &[i16]) {
        let frames = pcm.len() / CHANNELS;
        let mut g = self.inner.lock();
        let cap = g.capacity;
        for i in 0..frames {
            let f = first_frame + i as u64;
            let slot = (f % cap as u64) as usize;
            g.samples[slot * CHANNELS] = pcm[i * CHANNELS] as f32 / 32768.0;
            g.samples[slot * CHANNELS + 1] = pcm[i * CHANNELS + 1] as f32 / 32768.0;
            g.tags[slot] = f + 1;
        }
        let end = first_frame + frames as u64;
        if end > g.highest {
            g.highest = end;
        }
    }

    /// One past the newest frame received.
    pub fn highest(&self) -> u64 {
        self.inner.lock().highest
    }

    /// Calls `f` with a reader for the duration of one audio callback (one lock).
    pub fn with_reader<R>(&self, f: impl FnOnce(&RingReader<'_>) -> R) -> R {
        let g = self.inner.lock();
        let reader = RingReader { inner: &g };
        f(&reader)
    }
}

pub struct RingReader<'a> {
    inner: &'a Inner,
}

impl RingReader<'_> {
    #[inline]
    pub fn frame(&self, f: i64) -> Option<[f32; 2]> {
        if f < 0 {
            return None;
        }
        let f = f as u64;
        let slot = (f % self.inner.capacity as u64) as usize;
        if self.inner.tags[slot] != f + 1 {
            return None;
        }
        Some([self.inner.samples[slot * 2], self.inner.samples[slot * 2 + 1]])
    }

    pub fn highest(&self) -> u64 {
        self.inner.highest
    }

    /// 4-point, 3rd-order Hermite interpolation at fractional frame `pos`.
    /// Returns None if the frames around `pos` are not there.
    #[inline]
    pub fn sample_at(&self, pos: f64) -> Option<[f32; 2]> {
        let i = pos.floor() as i64;
        let t = (pos - i as f64) as f32;
        let x1 = self.frame(i)?;
        let x2 = self.frame(i + 1).unwrap_or(x1);
        let x0 = self.frame(i - 1).unwrap_or(x1);
        let x3 = self.frame(i + 2).unwrap_or(x2);
        let mut out = [0.0f32; 2];
        for c in 0..2 {
            let c0 = x1[c];
            let c1 = 0.5 * (x2[c] - x0[c]);
            let c2 = x0[c] - 2.5 * x1[c] + 2.0 * x2[c] - 0.5 * x3[c];
            let c3 = 0.5 * (x3[c] - x0[c]) + 1.5 * (x1[c] - x2[c]);
            out[c] = ((c3 * t + c2) * t + c1) * t + c0;
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_reject_stale_frames() {
        let r = PcmRing::new(8);
        r.write_i16(0, &[100, 100, 200, 200]);
        r.with_reader(|rd| {
            assert!(rd.frame(0).is_some());
            assert!(rd.frame(1).is_some());
            assert!(rd.frame(2).is_none());
        });
        // frame 8 lands in slot 0: frame 0 must now read as absent
        r.write_i16(8, &[5, 5]);
        r.with_reader(|rd| {
            assert!(rd.frame(0).is_none());
            assert!(rd.frame(8).is_some());
        });
    }

    #[test]
    fn hermite_hits_samples_exactly() {
        let r = PcmRing::new(64);
        let pcm: Vec<i16> = (0..32).flat_map(|i| [(i * 1000) as i16, -(i * 1000) as i16]).collect();
        r.write_i16(0, &pcm);
        r.with_reader(|rd| {
            let s = rd.sample_at(5.0).unwrap();
            assert!((s[0] - 5000.0 / 32768.0).abs() < 1e-6);
            // linear ramp: halfway is the average
            let h = rd.sample_at(5.5).unwrap();
            assert!((h[0] - 5500.0 / 32768.0).abs() < 1e-4);
        });
    }
}
