//! The host's EQ and boost. The host sets it; every phone (host and speakers) applies it in its
//! own output, in float, after the volume. Ten peaking bands (RBJ cookbook), a gain boost, and a
//! soft limiter so a boost can't clip. Off = untouched samples.

use serde::{Deserialize, Serialize};

pub const BANDS: usize = 10;
pub const BAND_HZ: [f32; BANDS] = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
pub const MAX_BAND_DB: f32 = 12.0;
pub const MAX_BOOST_DB: f32 = 12.0;
/// Octave-spaced bands: Q of one octave.
const Q: f32 = 1.414;
/// The limiter leaves everything below this alone and bends the rest smoothly into ±1.
const KNEE: f32 = 0.9;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EqSettings {
    pub enabled: bool,
    pub boost_db: f32,
    pub bands_db: [f32; BANDS],
}

impl Default for EqSettings {
    fn default() -> Self {
        Self { enabled: false, boost_db: 0.0, bands_db: [0.0; BANDS] }
    }
}

impl EqSettings {
    /// Clamped to the supported ranges (the host may send anything).
    pub fn sanitized(self) -> Self {
        let mut s = self;
        s.boost_db = if s.boost_db.is_finite() { s.boost_db.clamp(0.0, MAX_BOOST_DB) } else { 0.0 };
        for b in &mut s.bands_db {
            *b = if b.is_finite() { b.clamp(-MAX_BAND_DB, MAX_BAND_DB) } else { 0.0 };
        }
        s
    }

    fn is_flat(&self) -> bool {
        !self.is_active()
    }

    /// On, and actually changes the sound.
    pub fn is_active(&self) -> bool {
        self.enabled && (self.boost_db != 0.0 || self.bands_db.iter().any(|&b| b != 0.0))
    }
}

#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    // per-channel state (stereo), transposed direct form II
    z1: [f32; 2],
    z2: [f32; 2],
}

impl Biquad {
    fn peaking(rate: f32, hz: f32, gain_db: f32) -> Self {
        let hz = hz.min(rate * 0.45); // 16 kHz at a 32 kHz output would sit past Nyquist
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * hz / rate;
        let alpha = w0.sin() / (2.0 * Q);
        let cos = w0.cos();
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos) / a0,
            a2: (1.0 - alpha / a) / a0,
            z1: [0.0; 2],
            z2: [0.0; 2],
        }
    }

    #[inline]
    fn run(&mut self, c: usize, x: f32) -> f32 {
        let y = self.b0 * x + self.z1[c];
        self.z1[c] = self.b1 * x - self.a1 * y + self.z2[c];
        self.z2[c] = self.b2 * x - self.a2 * y;
        y
    }
}

/// Lives in one output stream's renderer (audio thread). `apply` is allocation-free.
pub struct Equalizer {
    rate: f32,
    settings: EqSettings,
    bands: [Biquad; BANDS],
    gain: f32,
    flat: bool,
}

impl Equalizer {
    pub fn new(rate: f32) -> Self {
        let mut eq = Self { rate, settings: EqSettings::default(), bands: [Biquad::default(); BANDS], gain: 1.0, flat: true };
        eq.configure(EqSettings::default());
        eq
    }

    /// New settings. Filter state carries over, so a change while playing doesn't click.
    pub fn configure(&mut self, s: EqSettings) {
        let s = s.sanitized();
        for (i, band) in self.bands.iter_mut().enumerate() {
            let (z1, z2) = (band.z1, band.z2);
            *band = Biquad::peaking(self.rate, BAND_HZ[i], if s.enabled { s.bands_db[i] } else { 0.0 });
            band.z1 = z1;
            band.z2 = z2;
        }
        self.gain = if s.enabled { 10f32.powf(s.boost_db / 20.0) } else { 1.0 };
        self.flat = s.is_flat();
        self.settings = s;
    }

    pub fn settings(&self) -> EqSettings {
        self.settings
    }

    /// Processes interleaved frames in place; only the first two channels are filtered (the
    /// renderer leaves any others silent).
    pub fn apply(&mut self, buf: &mut [f32], channels: usize) {
        if self.flat {
            return;
        }
        let ch = channels.clamp(1, 2);
        for frame in buf.chunks_exact_mut(channels.max(1)) {
            for c in 0..ch {
                let mut x = frame[c];
                for b in &mut self.bands {
                    x = b.run(c, x);
                }
                frame[c] = soft_limit(x * self.gain);
            }
        }
    }
}

/// Identity below the knee, then a tanh curve that approaches but never passes ±1.
#[inline]
fn soft_limit(x: f32) -> f32 {
    let a = x.abs();
    if a <= KNEE {
        return x;
    }
    let over = (a - KNEE) / (1.0 - KNEE);
    (KNEE + (1.0 - KNEE) * over.tanh()).copysign(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: f32, hz: f32, n: usize) -> Vec<f32> {
        (0..n).flat_map(|i| {
            let v = 0.25 * (2.0 * std::f32::consts::PI * hz * i as f32 / rate).sin();
            [v, v]
        }).collect()
    }

    fn rms(buf: &[f32]) -> f32 {
        (buf.iter().map(|s| s * s).sum::<f32>() / buf.len() as f32).sqrt()
    }

    #[test]
    fn off_and_flat_are_untouched() {
        let mut eq = Equalizer::new(48_000.0);
        let src = sine(48_000.0, 440.0, 4800);
        let mut buf = src.clone();
        eq.apply(&mut buf, 2);
        assert_eq!(buf, src);
        eq.configure(EqSettings { enabled: true, boost_db: 0.0, bands_db: [0.0; BANDS] });
        eq.apply(&mut buf, 2);
        assert_eq!(buf, src);
    }

    #[test]
    fn band_gain_lands_at_its_centre() {
        for (i, &hz) in BAND_HZ.iter().enumerate().skip(2) {
            let mut eq = Equalizer::new(48_000.0);
            let mut bands = [0.0; BANDS];
            bands[i] = 6.0;
            eq.configure(EqSettings { enabled: true, boost_db: 0.0, bands_db: bands });
            let src = sine(48_000.0, hz, 48_000);
            let mut buf = src.clone();
            eq.apply(&mut buf, 2);
            // skip the filter's settling time
            let gain_db = 20.0 * (rms(&buf[24_000..]) / rms(&src[24_000..])).log10();
            assert!((gain_db - 6.0).abs() < 0.5, "{hz} Hz: {gain_db:.2} dB");
        }
    }

    #[test]
    fn boost_never_clips() {
        let mut eq = Equalizer::new(48_000.0);
        eq.configure(EqSettings { enabled: true, boost_db: 12.0, bands_db: [12.0; BANDS] });
        let mut buf: Vec<f32> = (0..9600).map(|i| if i % 4 < 2 { 1.0 } else { -1.0 }).collect();
        eq.apply(&mut buf, 2);
        assert!(buf.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
    }

    #[test]
    fn hostile_settings_are_clamped() {
        let s = EqSettings { enabled: true, boost_db: f32::NAN, bands_db: [100.0; BANDS] }.sanitized();
        assert_eq!(s.boost_db, 0.0);
        assert!(s.bands_db.iter().all(|&b| b == MAX_BAND_DB));
    }
}
