//! Audio output: one cpal stream per device, rendering the shared timeline.

use super::clock::{now_ns, CPAL_SHARES_CLOCK};
use super::control::Controller;
use super::ring::PcmRing;
use super::sync::ClockEstimate;
use super::timeline::Timeline;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, OutputCallbackInfo, SampleFormat, SizedSample, StreamConfig};
use parking_lot::{Mutex, RwLock};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// What the audio callback reads. Cheap to copy under a short lock.
#[derive(Clone, Copy, Debug)]
pub struct Render {
    pub timeline: Option<Timeline>,
    pub clock: ClockEstimate,
    /// Bumped when a new stream starts so the controller re-locks.
    pub generation: u64,
}

pub struct PlayerShared {
    pub ring: PcmRing,
    pub render: RwLock<Render>,
    /// User calibration: delay this device by this much (ns), positive = later.
    pub delay_ns: AtomicI64,
    /// Volume as f32 bits.
    volume_bits: AtomicU32,
    pub enabled: AtomicBool,
    // stats, written by the callback
    pub underrun_frames: AtomicU64,
    pub played_frames: AtomicU64,
    pub latency_ns: AtomicI64,
    pub err_ns: AtomicI64,
    pub jumps: AtomicU64,
    pub out_rate: AtomicU32,
    pub last_callback_ns: AtomicI64,
    pub position_frame: AtomicI64,
    pub device_name: Mutex<String>,
    pub error: Mutex<Option<String>>,
}

impl PlayerShared {
    pub fn new(ring: PcmRing) -> Arc<Self> {
        Arc::new(Self {
            ring,
            render: RwLock::new(Render { timeline: None, clock: ClockEstimate::identity(), generation: 0 }),
            delay_ns: AtomicI64::new(0),
            volume_bits: AtomicU32::new(1.0f32.to_bits()),
            enabled: AtomicBool::new(true),
            underrun_frames: AtomicU64::new(0),
            played_frames: AtomicU64::new(0),
            latency_ns: AtomicI64::new(0),
            err_ns: AtomicI64::new(0),
            jumps: AtomicU64::new(0),
            out_rate: AtomicU32::new(0),
            last_callback_ns: AtomicI64::new(0),
            position_frame: AtomicI64::new(-1),
            device_name: Mutex::new(String::new()),
            error: Mutex::new(None),
        })
    }

    pub fn set_volume(&self, v: f32) {
        self.volume_bits.store(v.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
    }
    pub fn volume(&self) -> f32 {
        f32::from_bits(self.volume_bits.load(Ordering::Relaxed))
    }
    pub fn set_clock(&self, clock: ClockEstimate) {
        self.render.write().clock = clock;
    }
    pub fn set_timeline(&self, tl: Option<Timeline>, new_stream: bool) {
        let mut r = self.render.write();
        r.timeline = tl;
        if new_stream {
            r.generation += 1;
        }
    }
}

/// Renders one callback's worth of frames. Separate from cpal so it can be tested.
pub struct Renderer {
    shared: Arc<PlayerShared>,
    ctl: Controller,
    generation: u64,
    out_rate: f64,
    channels: usize,
    /// Last gain actually applied, for click-free volume/mute changes.
    gain: f32,
}

impl Renderer {
    pub fn new(shared: Arc<PlayerShared>, out_rate: f64, channels: usize) -> Self {
        Self { shared, ctl: Controller::new(), generation: u64::MAX, out_rate, channels, gain: 0.0 }
    }

    /// Fills `out` (interleaved, `self.channels` per frame) for frames whose first one is heard
    /// at local time `p0`.
    pub fn render(&mut self, out: &mut [f32], p0: i64) {
        let ch = self.channels.max(1);
        let n = out.len() / ch;
        let render = *self.shared.render.read();
        let enabled = self.shared.enabled.load(Ordering::Relaxed);
        let target_gain = if enabled { self.shared.volume() } else { 0.0 };
        let Some(tl) = render.timeline.filter(|_| render.clock.valid) else {
            out.iter_mut().for_each(|s| *s = 0.0);
            self.ctl.reset();
            self.shared.position_frame.store(-1, Ordering::Relaxed);
            return;
        };
        if render.generation != self.generation {
            self.generation = render.generation;
            self.ctl.reset();
        }
        let delay = self.shared.delay_ns.load(Ordering::Relaxed) as f64;
        let plan = self.ctl.plan(p0, n, self.out_rate, &render.clock, &tl, delay);
        if plan.jumped {
            self.shared.jumps.fetch_add(1, Ordering::Relaxed);
            // fade in from silence after a jump
            self.gain = 0.0;
        }
        self.shared.err_ns.store(plan.err_ns as i64, Ordering::Relaxed);
        self.shared.position_frame.store(plan.start as i64, Ordering::Relaxed);
        let mut missing = 0u64;
        let gain_step = (target_gain - self.gain) / n.max(1) as f32;
        self.shared.ring.with_reader(|rd| {
            let mut pos = plan.start;
            for i in 0..n {
                self.gain += gain_step;
                let frame = match rd.sample_at(pos) {
                    Some(s) => s,
                    None => {
                        missing += 1;
                        [0.0, 0.0]
                    }
                };
                let base = i * ch;
                if ch == 1 {
                    out[base] = 0.5 * (frame[0] + frame[1]) * self.gain;
                } else {
                    out[base] = frame[0] * self.gain;
                    out[base + 1] = frame[1] * self.gain;
                    for c in 2..ch {
                        out[base + c] = 0.0;
                    }
                }
                pos += plan.step;
            }
        });
        self.gain = target_gain;
        // Frames before the stream starts are expected silence, not underruns.
        if plan.start >= 0.0 {
            self.shared.underrun_frames.fetch_add(missing, Ordering::Relaxed);
        }
        self.shared.played_frames.fetch_add(n as u64, Ordering::Relaxed);
    }
}

/// Owns the cpal stream on its own thread (cpal streams are not Send everywhere) and rebuilds
/// it when the device goes away (headphones unplugged, Bluetooth switch).
pub struct Player {
    shared: Arc<PlayerShared>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Player {
    pub fn start(shared: Arc<PlayerShared>) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let shared = shared.clone();
            let stop = stop.clone();
            thread::Builder::new()
                .name("gp-output".into())
                .spawn(move || output_thread(shared, stop))
                .expect("spawn output thread")
        };
        Self { shared, stop, thread: Some(thread) }
    }

    pub fn shared(&self) -> &Arc<PlayerShared> {
        &self.shared
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn output_thread(shared: Arc<PlayerShared>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        let failed = Arc::new(AtomicBool::new(false));
        match build_stream(shared.clone(), failed.clone()) {
            Ok(stream) => {
                *shared.error.lock() = None;
                if let Err(e) = stream.play() {
                    log::error!("output: play failed: {e}");
                    *shared.error.lock() = Some(format!("play: {e}"));
                }
                while !stop.load(Ordering::Relaxed) && !failed.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(50));
                    // A stream whose callback stopped for 2 s (device lost without an error) is rebuilt too.
                    let last = shared.last_callback_ns.load(Ordering::Relaxed);
                    if last != 0 && now_ns() - last > 2_000_000_000 {
                        log::warn!("output: callbacks stopped, rebuilding stream");
                        break;
                    }
                }
                drop(stream);
                shared.last_callback_ns.store(0, Ordering::Relaxed);
            }
            Err(e) => {
                log::error!("output: {e:#}");
                *shared.error.lock() = Some(format!("{e:#}"));
            }
        }
        if !stop.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(500));
        }
    }
}

fn build_stream(shared: Arc<PlayerShared>, failed: Arc<AtomicBool>) -> anyhow::Result<cpal::Stream> {
    let host = cpal::default_host();
    let device = host.default_output_device().ok_or_else(|| anyhow::anyhow!("no output device"))?;
    let supported = device.default_output_config()?;
    let format = supported.sample_format();
    let mut config: StreamConfig = supported.into();
    if config.channels == 0 {
        config.channels = 2;
    }
    let name = device.id().map(|d| d.to_string()).unwrap_or_else(|_| "default".into());
    *shared.device_name.lock() = format!("{name} @ {} Hz × {}", config.sample_rate, config.channels);
    log::info!("output: {} ({format:?})", shared.device_name.lock());
    shared.out_rate.store(config.sample_rate, Ordering::Relaxed);
    match format {
        SampleFormat::F32 => run::<f32>(&device, config, shared, failed),
        SampleFormat::I16 => run::<i16>(&device, config, shared, failed),
        SampleFormat::I32 => run::<i32>(&device, config, shared, failed),
        SampleFormat::U16 => run::<u16>(&device, config, shared, failed),
        other => anyhow::bail!("unsupported output sample format {other:?}"),
    }
}

fn run<T>(device: &cpal::Device, config: StreamConfig, shared: Arc<PlayerShared>, failed: Arc<AtomicBool>) -> anyhow::Result<cpal::Stream>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = config.channels as usize;
    let mut renderer = Renderer::new(shared.clone(), config.sample_rate as f64, channels);
    let mut scratch: Vec<f32> = Vec::new();
    let cb_shared = shared.clone();
    let stream = device.build_output_stream::<T, _, _>(
        config,
        move |data: &mut [T], info: &OutputCallbackInfo| {
            let now = now_ns();
            let ts = info.timestamp();
            let latency = ts.playback.as_nanos() as i64 - ts.callback.as_nanos() as i64;
            let mut p0 = now + latency.max(0);
            if CPAL_SHARES_CLOCK {
                let direct = ts.playback.as_nanos() as i64;
                // trust the hardware timestamp if it is in our clock domain (sanity: within 1 s)
                if (direct - now).abs() < 1_000_000_000 {
                    p0 = direct;
                }
            }
            cb_shared.latency_ns.store(p0 - now, Ordering::Relaxed);
            cb_shared.last_callback_ns.store(now, Ordering::Relaxed);
            scratch.resize(data.len(), 0.0);
            renderer.render(&mut scratch, p0);
            for (d, s) in data.iter_mut().zip(scratch.iter()) {
                *d = T::from_sample(s.clamp(-1.0, 1.0));
            }
        },
        move |err| {
            log::warn!("output stream error: {err}");
            failed.store(true, Ordering::Relaxed);
        },
        None,
    )?;
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_scheduled_audio_at_the_right_time() {
        let ring = PcmRing::new(48_000 * 4);
        // frame f has value f (mod 30 000), so the output tells us which frame played
        let pcm: Vec<i16> = (0..48_000).flat_map(|f| [(f % 30_000) as i16, 0]).collect();
        ring.write_i16(0, &pcm);
        let shared = PlayerShared::new(ring);
        // stream frame 0 is heard at host time 1 s; we are the host (identity clock)
        shared.set_timeline(Some(Timeline::new(1_000_000_000, 48_000.0)), true);
        let mut r = Renderer::new(shared.clone(), 48_000.0, 2);
        let mut out = vec![0.0f32; 480 * 2];
        // first callback fades in; the second one plays at full gain
        r.render(&mut out, 1_490_000_000);
        r.render(&mut out, 1_500_000_000); // first frame heard at 1.5 s => frame 24 000
        for i in [0usize, 100, 479] {
            let got = (out[2 * i] * 32768.0).round() as i64;
            assert!((got - (24_000 + i as i64)).abs() <= 1, "frame {i}: {got}");
        }
        assert_eq!(shared.underrun_frames.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn silence_before_start_is_not_an_underrun() {
        let ring = PcmRing::new(48_000);
        let shared = PlayerShared::new(ring);
        shared.set_timeline(Some(Timeline::new(10_000_000_000, 48_000.0)), true);
        let mut r = Renderer::new(shared.clone(), 48_000.0, 2);
        let mut out = vec![1.0f32; 960];
        r.render(&mut out, 1_000_000_000);
        assert!(out.iter().all(|s| *s == 0.0));
        assert_eq!(shared.underrun_frames.load(Ordering::Relaxed), 0);
    }
}
