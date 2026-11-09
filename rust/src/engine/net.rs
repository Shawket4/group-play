//! iroh endpoint setup and addresses.

use super::proto::ALPN;
use super::ticket::Ticket;
use anyhow::{Context, Result};
use iroh::{endpoint::presets, Endpoint, EndpointAddr, TransportAddr};
use std::net::{IpAddr, SocketAddr};

/// One endpoint per session. N0 preset: n0's relays (so a guest on another network can still
/// reach the host) plus direct paths, which are used whenever both are on the same LAN/hotspot.
pub async fn make_endpoint(accept: bool) -> Result<Endpoint> {
    let mut b = Endpoint::builder(presets::N0);
    if accept {
        b = b.alpns(vec![ALPN.to_vec()]);
    }
    b.bind().await.context("bind endpoint")
}

/// Non-loopback interface addresses (IPv4 first, then global/ULA IPv6).
pub fn local_ips() -> Vec<IpAddr> {
    let mut out = Vec::new();
    #[cfg(unix)]
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) == 0 {
            let mut cur = ifap;
            while !cur.is_null() {
                let ifa = &*cur;
                let up = (ifa.ifa_flags & libc::IFF_UP as u32) != 0;
                let loopback = (ifa.ifa_flags & libc::IFF_LOOPBACK as u32) != 0;
                if up && !loopback && !ifa.ifa_addr.is_null() {
                    let family = (*ifa.ifa_addr).sa_family as i32;
                    if family == libc::AF_INET {
                        let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                        let ip = std::net::Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                        if !ip.is_link_local() && !ip.is_unspecified() {
                            out.push(IpAddr::V4(ip));
                        }
                    } else if family == libc::AF_INET6 {
                        let sin6 = &*(ifa.ifa_addr as *const libc::sockaddr_in6);
                        let ip = std::net::Ipv6Addr::from(sin6.sin6_addr.s6_addr);
                        // link-local v6 needs a scope id we cannot put in a ticket portably
                        if !ip.is_unicast_link_local() && !ip.is_loopback() && !ip.is_unspecified() {
                            out.push(IpAddr::V6(ip));
                        }
                    }
                }
                cur = ifa.ifa_next;
            }
            libc::freeifaddrs(ifap);
        }
    }
    out.sort_by_key(|ip| (ip.is_ipv6(), !is_private(ip)));
    out.dedup();
    out
}

fn is_private(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private(),
        IpAddr::V6(v6) => (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

/// Builds the ticket: our id, every local address on our UDP ports, iroh's own view, the relay.
pub fn ticket_for(endpoint: &Endpoint, host_name: &str, wifi: Option<super::ticket::WifiCreds>) -> Ticket {
    let bound = endpoint.bound_sockets();
    let v4_port = bound.iter().find(|s| s.is_ipv4()).map(|s| s.port());
    let v6_port = bound.iter().find(|s| s.is_ipv6()).map(|s| s.port());
    let mut addrs: Vec<SocketAddr> = Vec::new();
    for ip in local_ips() {
        match (ip, v4_port, v6_port) {
            (IpAddr::V4(_), Some(p), _) => addrs.push(SocketAddr::new(ip, p)),
            (IpAddr::V6(_), _, Some(p)) => addrs.push(SocketAddr::new(ip, p)),
            _ => {}
        }
    }
    let ea = endpoint.addr();
    for a in ea.ip_addrs() {
        if !addrs.contains(a) && !a.ip().is_loopback() {
            addrs.push(*a);
        }
    }
    // keep the QR small: at most 6 addresses
    addrs.truncate(6);
    let relay = ea.relay_urls().next().map(|u| u.to_string());
    Ticket { endpoint_id: *endpoint.id().as_bytes(), addrs, relay, host_name: host_name.to_string(), wifi }
}

pub fn addr_from_ticket(t: &Ticket) -> Result<EndpointAddr> {
    let id = iroh::EndpointId::from_bytes(&t.endpoint_id).context("bad endpoint id in ticket")?;
    let mut parts: Vec<TransportAddr> = t.addrs.iter().copied().map(TransportAddr::Ip).collect();
    if let Some(r) = &t.relay {
        if let Ok(url) = r.parse() {
            parts.push(TransportAddr::Relay(url));
        }
    }
    Ok(EndpointAddr::from_parts(id, parts))
}

/// "direct" / "relay" / "" for the selected path of a connection.
pub fn path_kind(conn: &iroh::endpoint::Connection) -> String {
    let paths = conn.paths();
    for p in paths.iter() {
        if p.is_selected() {
            return if p.is_relay() { "relay".into() } else { "direct".into() };
        }
    }
    String::new()
}

pub fn path_rtt_ms(conn: &iroh::endpoint::Connection) -> f64 {
    let paths = conn.paths();
    for p in paths.iter() {
        if p.is_selected() {
            return p.rtt().as_secs_f64() * 1000.0;
        }
    }
    0.0
}
