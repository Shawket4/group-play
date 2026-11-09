//! The join ticket a host shows as a QR code.
//!
//! `GPLAY1:` + base32 of postcard. Base32 upper-case keeps the QR in alphanumeric mode, which
//! is about 40 % denser than byte mode.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

const PREFIX: &str = "GPLAY1:";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WifiCreds {
    pub ssid: String,
    pub passphrase: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ticket {
    pub endpoint_id: [u8; 32],
    pub addrs: Vec<SocketAddr>,
    pub relay: Option<String>,
    pub host_name: String,
    /// Set when the host runs a local-only hotspot: join this network first.
    pub wifi: Option<WifiCreds>,
}

impl Ticket {
    pub fn encode(&self) -> String {
        let bytes = postcard::to_stdvec(self).expect("ticket serializes");
        format!("{PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&bytes))
    }

    pub fn decode(s: &str) -> Result<Self> {
        let s = s.trim();
        // accept the bare ticket, or one embedded in a link (…#GPLAY1:… or …?t=GPLAY1:…)
        let start = s.to_ascii_uppercase().find(PREFIX).context("not a Group Play ticket")?;
        let body = &s[start + PREFIX.len()..];
        let body: String = body.chars().take_while(|c| c.is_ascii_alphanumeric()).collect::<String>().to_ascii_uppercase();
        let bytes = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).context("ticket is damaged (base32)")?;
        let t: Ticket = postcard::from_bytes(&bytes).context("ticket is damaged")?;
        if t.addrs.is_empty() && t.relay.is_none() {
            bail!("ticket has no address to connect to");
        }
        Ok(t)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_qr_alphabet() {
        let t = Ticket {
            endpoint_id: [7; 32],
            addrs: vec!["192.168.1.20:40000".parse().unwrap(), "[fe80::1]:40000".parse().unwrap()],
            relay: Some("https://euw1-1.relay.iroh.network./".into()),
            host_name: "Pixel 9".into(),
            wifi: Some(WifiCreds { ssid: "AndroidShare_1234".into(), passphrase: "abcd efgh".into() }),
        };
        let s = t.encode();
        assert!(s.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == ':'));
        assert_eq!(Ticket::decode(&s).unwrap(), t);
        assert_eq!(Ticket::decode(&format!("https://x.y/join#{}", s.to_lowercase())).unwrap(), t);
        assert!(Ticket::decode("hello").is_err());
    }
}
