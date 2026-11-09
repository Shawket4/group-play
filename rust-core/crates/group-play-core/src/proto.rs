//! Wire messages. Length-prefixed postcard frames on QUIC streams; pings as datagrams.
//!
//! Streams per guest connection:
//! - control (bi, opened by the guest): `GuestMsg` up, `HostMsg` down.
//! - meta (uni, opened by the host, first byte `STREAM_META`): `Media`, reliable and ordered.
//! - segments (uni, one per chunk of audio, first byte `STREAM_SEGMENT`): a `SegmentHeader` and
//!   raw PCM. Independent of each other, so one lost packet only delays its own segment, and the
//!   host resets a segment that can no longer arrive in time instead of queueing stale audio.
//! - datagrams: `Dgram` ping/pong for clock sync (unreliable on purpose: a late answer is useless).

use super::eq::EqSettings;
use super::timeline::Timeline;
use super::tune::Gate;
use anyhow::{bail, Context, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

pub const ALPN: &[u8] = b"group-play/1";
pub const PROTOCOL_VERSION: u32 = 4;
const MAX_FRAME: usize = 1 << 20;

/// First byte of every uni stream the host opens.
pub const STREAM_META: u8 = 0;
pub const STREAM_SEGMENT: u8 = 1;
pub const SEGMENT_HEADER_LEN: usize = 16;
/// Largest segment a guest accepts (frames); chunks are 10-20 ms.
pub const MAX_SEGMENT_FRAMES: u32 = 48_000;

/// Which audio a segment stream carries. Its payload is `frames` interleaved stereo s16le frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SegmentHeader {
    pub id: u32,
    pub first_frame: u64,
    pub frames: u32,
}

impl SegmentHeader {
    /// The whole stream payload: kind byte, header, PCM.
    pub fn stream_bytes(&self, pcm: &[i16]) -> Vec<u8> {
        let mut out = Vec::with_capacity(1 + SEGMENT_HEADER_LEN + pcm.len() * 2);
        out.push(STREAM_SEGMENT);
        out.extend_from_slice(&self.id.to_le_bytes());
        out.extend_from_slice(&self.first_frame.to_le_bytes());
        out.extend_from_slice(&self.frames.to_le_bytes());
        for s in pcm {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    pub fn decode(b: &[u8; SEGMENT_HEADER_LEN]) -> Self {
        Self {
            id: u32::from_le_bytes(b[0..4].try_into().unwrap()),
            first_frame: u64::from_le_bytes(b[4..12].try_into().unwrap()),
            frames: u32::from_le_bytes(b[12..16].try_into().unwrap()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GuestStatus {
    pub sync_offset_ms: f64,
    pub rtt_ms: f64,
    pub skew_ppm: f64,
    pub buffer_ms: f64,
    pub underrun_ms: f64,
    pub latency_ms: f64,
    pub err_ms: f64,
    pub delay_ms: f64,
    pub volume: f64,
    pub output: String,
    pub playing: bool,
    pub jumps: u64,
    /// Audio that arrived too late to play, or that the host gave up sending (ms, cumulative).
    pub late_ms: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum GuestMsg {
    Hello { name: String, platform: String, version: u32 },
    Status(GuestStatus),
    Bye,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum HostMsg {
    /// `ticket`: the host's current ticket, so the guest can find it again next time.
    Welcome { host_name: String, version: u32, ticket: String },
    /// The delay the host assigns this guest (tuning or the host's fine adjustment).
    SetDelay { delay_ms: f64 },
    SetVolume { volume: f64 },
    /// The host's EQ and boost; every speaker applies it to its own output.
    SetEq { eq: EqSettings },
    /// Tuning: play only these slots of that stream (None = play everything again).
    Gate { gate: Option<Gate> },
    /// `resumable`: the host is going away for now (ended the session, app closed); a guest
    /// that remembers it keeps waiting and rejoins when it is back.
    Kick { reason: String, resumable: bool },
}

/// Meta-stream messages. The audio itself travels in segment streams.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Media {
    StreamStart { id: u32, sample_rate: u32, timeline: Timeline, desc: String },
    Timeline { id: u32, timeline: Timeline },
    StreamStop { id: u32 },
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub enum Dgram {
    Ping { seq: u32, t0: i64 },
    Pong { seq: u32, t0: i64, t1: i64, t2: i64 },
}

pub fn encode<T: Serialize>(msg: &T) -> Result<Vec<u8>> {
    Ok(postcard::to_stdvec(msg)?)
}

pub fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    Ok(postcard::from_bytes(bytes)?)
}

pub fn frame<T: Serialize>(msg: &T) -> Result<Vec<u8>> {
    let body = encode(msg)?;
    let mut out = Vec::with_capacity(body.len() + 4);
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub async fn write_msg<T: Serialize>(send: &mut iroh::endpoint::SendStream, msg: &T) -> Result<()> {
    let bytes = frame(msg)?;
    send.write_all(&bytes).await.context("write")?;
    Ok(())
}

/// Returns None on a clean end of stream.
pub async fn read_msg<T: DeserializeOwned>(recv: &mut iroh::endpoint::RecvStream) -> Result<Option<T>> {
    let mut len = [0u8; 4];
    match recv.read_exact(&mut len).await {
        Ok(()) => {}
        Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(e).context("read length"),
    }
    let len = u32::from_le_bytes(len) as usize;
    if len > MAX_FRAME {
        bail!("frame too large: {len}");
    }
    let mut body = vec![0u8; len];
    recv.read_exact(&mut body).await.context("read body")?;
    Ok(Some(decode(&body)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let m = Media::StreamStop { id: 3 };
        let f = frame(&m).unwrap();
        assert_eq!(u32::from_le_bytes(f[..4].try_into().unwrap()) as usize, f.len() - 4);
        assert_eq!(decode::<Media>(&f[4..]).unwrap(), m);
        let d = Dgram::Pong { seq: 9, t0: -5, t1: 6, t2: 7 };
        assert_eq!(decode::<Dgram>(&encode(&d).unwrap()).unwrap(), d);
    }

    #[test]
    fn segment_layout() {
        let h = SegmentHeader { id: 7, first_frame: 1 << 40, frames: 2 };
        let b = h.stream_bytes(&[-3, 7, i16::MIN, i16::MAX]);
        assert_eq!(b[0], STREAM_SEGMENT);
        assert_eq!(b.len(), 1 + SEGMENT_HEADER_LEN + 8);
        assert_eq!(SegmentHeader::decode(b[1..1 + SEGMENT_HEADER_LEN].try_into().unwrap()), h);
        assert_eq!(&b[1 + SEGMENT_HEADER_LEN..], &[0xfd, 0xff, 7, 0, 0, 0x80, 0xff, 0x7f]);
    }
}
