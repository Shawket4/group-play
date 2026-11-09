//! Audio sources for the host. Each produces interleaved stereo i16 at its own sample rate.

use anyhow::{Context, Result};
use std::fs::File;
use std::io::Read;

pub const CHUNK_FRAMES: usize = 960; // 20 ms at 48 kHz

/// A source that can be pulled from ahead of real time (file, test clicks).
pub trait PullSource: Send {
    fn sample_rate(&self) -> u32;
    /// Fills up to `frames` frames of interleaved stereo. Returns frames written; 0 = finished.
    fn pull(&mut self, out: &mut Vec<i16>, frames: usize) -> Result<usize>;
    fn describe(&self) -> String;
}

/// Metronome clicks for checking sync by ear: a short 1.5 kHz blip every beat, accented
/// (2.5 kHz, louder) on the first of every four.
pub struct Clicks {
    rate: u32,
    frame: u64,
    beat_frames: u64,
}

impl Clicks {
    pub fn new(rate: u32, bpm: f64) -> Self {
        let beat_frames = (rate as f64 * 60.0 / bpm.clamp(20.0, 600.0)).round() as u64;
        Self { rate, frame: 0, beat_frames }
    }
}

impl PullSource for Clicks {
    fn sample_rate(&self) -> u32 {
        self.rate
    }
    fn pull(&mut self, out: &mut Vec<i16>, frames: usize) -> Result<usize> {
        let blip = (self.rate as f64 * 0.012) as u64; // 12 ms
        for _ in 0..frames {
            let beat = self.frame / self.beat_frames;
            let in_beat = self.frame % self.beat_frames;
            let v = if in_beat < blip {
                let accent = beat % 4 == 0;
                let freq = if accent { 2500.0 } else { 1500.0 };
                let amp = if accent { 0.8 } else { 0.5 };
                let t = in_beat as f64 / self.rate as f64;
                // sharp attack, short exponential decay: easy to hear flams between phones
                let env = (-(in_beat as f64) / (blip as f64 / 4.0)).exp();
                (amp * env * (2.0 * std::f64::consts::PI * freq * t).sin() * 32767.0) as i16
            } else {
                0
            };
            out.push(v);
            out.push(v);
            self.frame += 1;
        }
        Ok(frames)
    }
    fn describe(&self) -> String {
        format!("Sync test clicks ({} BPM)", (self.rate as f64 * 60.0 / self.beat_frames as f64).round())
    }
}

/// Decodes a local file (mp3, aac/m4a, flac, wav, ogg/vorbis) with symphonia.
pub struct FileSource {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::audio::AudioDecoder>,
    track_id: u32,
    rate: u32,
    pending: Vec<i16>, // decoded stereo not handed out yet
    pending_pos: usize,
    scratch: Vec<f32>,
    name: String,
    done: bool,
}

impl FileSource {
    pub fn open(path: &str) -> Result<Self> {
        use symphonia::core::codecs::audio::AudioDecoderOptions;
        use symphonia::core::formats::probe::Hint;
        use symphonia::core::formats::{FormatOptions, TrackType};
        use symphonia::core::io::MediaSourceStream;
        use symphonia::core::meta::MetadataOptions;

        let file = File::open(path).with_context(|| format!("open {path}"))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = std::path::Path::new(path).extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        let format = symphonia::default::get_probe()
            .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
            .context("unsupported or unreadable audio file")?;
        let track = format.default_track(TrackType::Audio).context("no audio track")?;
        let params = track.codec_params.as_ref().and_then(|p| p.audio()).context("no audio codec parameters")?;
        let rate = params.sample_rate.unwrap_or(44_100);
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(params, &AudioDecoderOptions::default())
            .context("no decoder for this codec")?;
        let track_id = track.id;
        let name = std::path::Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        Ok(Self { format, decoder, track_id, rate, pending: Vec::new(), pending_pos: 0, scratch: Vec::new(), name, done: false })
    }

    fn decode_more(&mut self) -> Result<()> {
        use symphonia::core::errors::Error;
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(p)) => p,
                Ok(None) => {
                    self.done = true;
                    return Ok(());
                }
                Err(Error::ResetRequired) => {
                    self.done = true;
                    return Ok(());
                }
                Err(Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    self.done = true;
                    return Ok(());
                }
                Err(e) => return Err(e.into()),
            };
            if packet.track_id != self.track_id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(buf) => {
                    let ch = buf.spec().channels().count().max(1);
                    let frames = buf.frames();
                    if frames == 0 {
                        continue;
                    }
                    self.scratch.resize(buf.samples_interleaved(), 0.0);
                    buf.copy_to_slice_interleaved(&mut self.scratch);
                    self.pending.clear();
                    self.pending_pos = 0;
                    self.pending.reserve(frames * 2);
                    for f in 0..frames {
                        let l = self.scratch[f * ch];
                        let r = if ch > 1 { self.scratch[f * ch + 1] } else { l };
                        self.pending.push((l.clamp(-1.0, 1.0) * 32767.0) as i16);
                        self.pending.push((r.clamp(-1.0, 1.0) * 32767.0) as i16);
                    }
                    return Ok(());
                }
                Err(Error::DecodeError(e)) => {
                    log::debug!("file: skipping bad packet: {e}");
                    continue;
                }
                Err(e) => return Err(e.into()),
            }
        }
    }
}

impl PullSource for FileSource {
    fn sample_rate(&self) -> u32 {
        self.rate
    }
    fn pull(&mut self, out: &mut Vec<i16>, frames: usize) -> Result<usize> {
        let mut written = 0;
        while written < frames {
            if self.pending_pos >= self.pending.len() {
                if self.done {
                    break;
                }
                self.decode_more()?;
                continue;
            }
            let avail = (self.pending.len() - self.pending_pos) / 2;
            let take = avail.min(frames - written);
            out.extend_from_slice(&self.pending[self.pending_pos..self.pending_pos + take * 2]);
            self.pending_pos += take * 2;
            written += take;
        }
        Ok(written)
    }
    fn describe(&self) -> String {
        self.name.clone()
    }
}

/// Live PCM arriving on a file descriptor (Android capture writes interleaved s16le into a pipe).
pub struct FdReader {
    file: File,
    channels: usize,
    buf: Vec<u8>,
}

impl FdReader {
    /// Takes ownership of `fd`.
    #[cfg(unix)]
    pub fn from_fd(fd: i32, channels: usize) -> Result<Self> {
        use std::os::fd::FromRawFd;
        anyhow::ensure!(fd >= 0, "bad fd {fd}");
        anyhow::ensure!(channels == 1 || channels == 2, "capture must be mono or stereo, got {channels}");
        // SAFETY: the caller hands us an open fd it no longer uses (ParcelFileDescriptor.detachFd()).
        let file = unsafe { File::from_raw_fd(fd) };
        Ok(Self { file, channels, buf: Vec::new() })
    }

    #[cfg(not(unix))]
    pub fn from_fd(_fd: i32, _channels: usize) -> Result<Self> {
        anyhow::bail!("fd sources need a unix platform")
    }

    /// Blocks until `frames` frames arrived (or EOF). Appends stereo i16; returns frames read.
    pub fn read_frames(&mut self, out: &mut Vec<i16>, frames: usize) -> Result<usize> {
        let bytes = frames * self.channels * 2;
        self.buf.resize(bytes, 0);
        let mut filled = 0;
        while filled < bytes {
            let n = self.file.read(&mut self.buf[filled..])?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        let frame_bytes = self.channels * 2;
        let whole = filled / frame_bytes;
        for f in 0..whole {
            let at = f * frame_bytes;
            let l = i16::from_le_bytes([self.buf[at], self.buf[at + 1]]);
            let r = if self.channels == 2 { i16::from_le_bytes([self.buf[at + 2], self.buf[at + 3]]) } else { l };
            out.push(l);
            out.push(r);
        }
        Ok(whole)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clicks_have_beats_where_expected() {
        let mut c = Clicks::new(48_000, 120.0); // beat every 0.5 s = 24 000 frames
        let mut out = Vec::new();
        c.pull(&mut out, 48_000).unwrap();
        let energy = |from: usize, to: usize| out[from * 2..to * 2].iter().map(|s| (*s as i64).abs()).sum::<i64>();
        assert!(energy(0, 576) > 0);
        assert_eq!(energy(1000, 24_000), 0);
        assert!(energy(24_000, 24_576) > 0);
    }

    #[cfg(unix)]
    #[test]
    fn fd_reader_reads_pipe() {
        use std::io::Write;
        use std::os::fd::IntoRawFd;
        let (r, mut w) = std::io::pipe().unwrap();
        let fd = r.into_raw_fd();
        let mut reader = FdReader::from_fd(fd, 2).unwrap();
        let pcm: Vec<u8> = (0..100i16).flat_map(|v| v.to_le_bytes()).collect();
        w.write_all(&pcm).unwrap();
        drop(w);
        let mut out = Vec::new();
        assert_eq!(reader.read_frames(&mut out, 50).unwrap(), 50);
        assert_eq!(out[3], 3);
        assert_eq!(reader.read_frames(&mut out, 50).unwrap(), 0);
    }

    #[test]
    fn decodes_a_wav_file() {
        // write a tiny 16-bit stereo 44.1 kHz wav
        let dir = std::env::temp_dir().join(format!("gp-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.wav");
        let frames = 4410u32;
        let mut data = Vec::new();
        for i in 0..frames {
            let v = ((i as f32 / 20.0).sin() * 10_000.0) as i16;
            data.extend_from_slice(&v.to_le_bytes());
            data.extend_from_slice(&(-v).to_le_bytes());
        }
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&44_100u32.to_le_bytes());
        wav.extend_from_slice(&(44_100u32 * 4).to_le_bytes());
        wav.extend_from_slice(&4u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(&data);
        std::fs::write(&path, wav).unwrap();
        let mut src = FileSource::open(path.to_str().unwrap()).unwrap();
        assert_eq!(src.sample_rate(), 44_100);
        let mut out = Vec::new();
        let mut total = 0;
        loop {
            let n = src.pull(&mut out, 1000).unwrap();
            if n == 0 {
                break;
            }
            total += n;
        }
        assert_eq!(total, frames as usize);
        // left and right are mirrored
        assert_eq!(out[200], -out[201]);
    }
}
