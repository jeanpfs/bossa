//! Transport-agnostic BMAP session. A `Link` moves whole BMAP byte sequences; BLE segmentation
//! and notification reassembly live inside the BLE link, so a `Session` never sees them.

pub mod ble;
pub mod fake;

use std::collections::VecDeque;
use std::future::Future;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use bose_bmap::{Operator, Packet};
use tokio::time::timeout;

#[allow(async_fn_in_trait)]
pub trait Link {
    /// Send one encoded BMAP packet.
    fn send(&self, packet: &[u8]) -> impl Future<Output = Result<()>> + Send;
    /// Next reassembled message from the device (may contain several packets).
    fn recv(&self) -> impl Future<Output = Result<Vec<u8>>> + Send;
}

/// A device answered with an Error operator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceError {
    pub fblock: u8,
    pub function: u8,
    pub code: u8,
    pub payload: Vec<u8>,
}
impl std::fmt::Display for DeviceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "device error {} (fblock {}, fn {}, payload {:02x?})", error_name(self.code), self.fblock, self.function, self.payload)
    }
}
impl std::error::Error for DeviceError {}

/// BmapPacketError names, docs/bmap-protocol.md §3.
pub fn error_name(code: u8) -> String {
    let n = match code {
        0 => "Unknown",
        1 => "Length",
        2 => "Chksum",
        3 => "FblockNotSupp",
        4 => "FuncNotSupp",
        5 => "OpNotSupp",
        6 => "InvalidData",
        7 => "DataUnavailable",
        8 => "Runtime",
        9 => "Timeout",
        10 => "InvalidState",
        11 => "DeviceNotFound",
        12 => "Busy",
        20 => "InsecureTransport",
        0xFF => "FblockSpecific",
        _ => return format!("code {code}"),
    };
    format!("{n} ({code})")
}

pub struct Session<L: Link> {
    link: L,
    /// Packets received while waiting for something else (notifications, late responses).
    pub unsolicited: VecDeque<Packet>,
    pending: VecDeque<Packet>,
}

impl<L: Link> Session<L> {
    pub fn new(link: L) -> Self {
        Self { link, unsolicited: VecDeque::new(), pending: VecDeque::new() }
    }

    /// Send `req` and wait for the matching Status/Result/Error. `Processing` is a keep-alive.
    pub async fn request(&mut self, req: Packet, wait: Duration) -> Result<Packet> {
        self.link.send(&req.encode().map_err(|e| anyhow!(e))?).await?;
        let (fb, f) = (req.fblock, req.function);
        let started = tokio::time::Instant::now();
        loop {
            while let Some(p) = self.pending.pop_front() {
                if p.fblock == fb && p.function == f {
                    match p.operator {
                        Operator::Processing => continue,
                        op if op.is_terminal_response() => {
                            if op == Operator::Error {
                                return Err(DeviceError { fblock: fb, function: f, code: p.error_code().unwrap_or(0), payload: p.payload }.into());
                            }
                            return Ok(p);
                        }
                        _ => {}
                    }
                }
                self.unsolicited.push_back(p);
            }
            let left = wait.checked_sub(started.elapsed()).ok_or_else(|| anyhow!("timeout waiting for fblock {fb} fn {f}"))?;
            let raw = match timeout(left, self.link.recv()).await {
                Ok(r) => r?,
                Err(_) => bail!("timeout waiting for fblock {fb} fn {f} after {wait:?}"),
            };
            for p in Packet::decode_all(&raw).map_err(|e| anyhow!(e))? {
                self.pending.push_back(p);
            }
        }
    }

    pub async fn get(&mut self, fblock: u8, function: u8, wait: Duration) -> Result<Packet> {
        self.request(Packet::get(fblock, function), wait).await
    }

    pub fn link(&self) -> &L {
        &self.link
    }
}
