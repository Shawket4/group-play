//! Wire messages. Length-prefixed postcard frames on QUIC streams; pings as datagrams.
//!
//! Streams per guest connection:
//! - control (bi, opened by the guest): `GuestMsg` up, `HostMsg` down.
//! - media (uni, opened by the host): `Media`, strictly ordered, so a chunk never arrives before
//!   the `StreamStart` it belongs to.
//! - datagrams: `Dgram` ping/pong for clock sync (unreliable on purpose: a late answer is useless).

use super::timeline::Timeline;
use super::tune::Gate;
use anyhow::{bail, Context, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

pub const ALPN: &[u8] = b"group-play/1";
pub const PROTOCOL_VERSION: u32 = 2;
const MAX_FRAME: usize = 1 << 20;

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
    /// Tuning: play only these slots of that stream (None = play everything again).
    Gate { gate: Option<Gate> },
    /// `resumable`: the host is going away for now (ended the session, app closed); a guest
    /// that remembers it keeps waiting and rejoins when it is back.
    Kick { reason: String, resumable: bool },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Media {
    StreamStart { id: u32, sample_rate: u32, timeline: Timeline, desc: String },
    /// Interleaved stereo s16le.
    Chunk { id: u32, first_frame: u64, pcm: Vec<u8> },
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

pub fn pcm_to_bytes(pcm: &[i16]) -> Vec<u8> {
    let mut out = Vec::with_capacity(pcm.len() * 2);
    for s in pcm {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

pub fn bytes_to_pcm(bytes: &[u8]) -> Vec<i16> {
    bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let m = Media::Chunk { id: 3, first_frame: 1 << 40, pcm: vec![1, 2, 3, 4] };
        let f = frame(&m).unwrap();
        assert_eq!(u32::from_le_bytes(f[..4].try_into().unwrap()) as usize, f.len() - 4);
        assert_eq!(decode::<Media>(&f[4..]).unwrap(), m);
        let d = Dgram::Pong { seq: 9, t0: -5, t1: 6, t2: 7 };
        assert_eq!(decode::<Dgram>(&encode(&d).unwrap()).unwrap(), d);
        assert_eq!(bytes_to_pcm(&pcm_to_bytes(&[-3, 7, i16::MIN])), vec![-3, 7, i16::MIN]);
    }
}
