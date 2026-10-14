//! BLE GATT transport (btleplug: CoreBluetooth on macOS, WinRT on Windows, BlueZ on Linux).
//! GATT layout and framing: docs/transport-and-auth.md §3.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bose_bmap::{segment, Reassembler};
use btleplug::api::{Central, CharPropFlags, Characteristic, Manager as _, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use tokio::sync::{mpsc, Mutex};
use uuid::Uuid;

use crate::Link;

const BASE: u128 = 0x0000_0000_0000_1000_8000_00805f9b34fb;
pub const SERVICE_FEBE: Uuid = Uuid::from_u128(BASE | (0xFEBE << 96));
pub const SERVICE_FDD2: Uuid = Uuid::from_u128(BASE | (0xFDD2 << 96));
pub const BRAGI_SERVICE: Uuid = Uuid::from_u128(0xf4c93a79_d04f_4565_b05e_79f7ead9df8e);
/// BMAP tx+rx without link encryption.
pub const CHAR_UNSECURE: Uuid = Uuid::from_u128(0xd417c028_9818_4354_99d1_2ac09d074591);
/// BMAP tx+rx; touching it makes the OS pair/encrypt the link.
pub const CHAR_SECURE: Uuid = Uuid::from_u128(0xc65b8f2f_aee2_4c89_b758_bc4892d6f2d8);
/// Bose Corporation's Bluetooth SIG company id.
pub const BOSE_COMPANY_ID: u16 = 0x009E;

/// Data bytes per BLE write: the app's default ATT MTU of 23 leaves 20 bytes, minus the 1-byte segment header.
const SAFE_CHUNK: usize = 19;

#[derive(Clone)]
pub struct Found {
    pub peripheral: Peripheral,
    pub id: String,
    pub name: Option<String>,
    pub rssi: Option<i16>,
    pub manufacturer: Vec<(u16, Vec<u8>)>,
    pub services: Vec<Uuid>,
}

impl Found {
    /// Same intent as the app's `isBoseDevice`: Bose service UUID, or Bose company id in the advert.
    pub fn is_bose(&self) -> bool {
        self.services.iter().any(|u| *u == SERVICE_FEBE || *u == SERVICE_FDD2 || *u == BRAGI_SERVICE)
            || self.manufacturer.iter().any(|(c, _)| *c == BOSE_COMPANY_ID)
    }
    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or("(no name)")
    }
}

async fn adapter() -> Result<Adapter> {
    let manager = Manager::new().await.context("Bluetooth manager (is Bluetooth permission granted to this terminal?)")?;
    manager.adapters().await?.into_iter().next().ok_or_else(|| anyhow!("no Bluetooth adapter"))
}

/// Scan for `secs` seconds and return everything seen (unfiltered; see `Found::is_bose`).
pub async fn scan(secs: u64) -> Result<Vec<Found>> {
    let adapter = adapter().await?;
    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(Duration::from_secs(secs)).await;
    let _ = adapter.stop_scan().await;
    let mut out = Vec::new();
    for p in adapter.peripherals().await? {
        let props = p.properties().await?.unwrap_or_default();
        let mut manufacturer: Vec<_> = props.manufacturer_data.into_iter().collect();
        manufacturer.sort_by_key(|(c, _)| *c);
        out.push(Found { id: p.id().to_string(), name: props.local_name, rssi: props.rssi, manufacturer, services: props.services, peripheral: p });
    }
    out.sort_by_key(|f| std::cmp::Reverse(f.rssi.unwrap_or(i16::MIN)));
    Ok(out)
}

pub struct BleLink {
    peripheral: Peripheral,
    chr: Characteristic,
    rx: Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
    pub uses_secure_characteristic: bool,
}

impl BleLink {
    /// Connect, pick the BMAP characteristic, subscribe and start the reassembly task.
    /// `prefer_secure=false` probes on the unsecure characteristic (no OS pairing prompt).
    pub async fn connect(found: &Found, prefer_secure: bool) -> Result<Self> {
        let p = found.peripheral.clone();
        if !p.is_connected().await? {
            tokio::time::timeout(Duration::from_secs(25), p.connect()).await.map_err(|_| anyhow!("connect timed out after 25 s"))??;
        }
        eprintln!("[ble] connected, discovering services…");
        tokio::time::timeout(Duration::from_secs(20), p.discover_services()).await.map_err(|_| anyhow!("service discovery timed out"))??;
        let chars = p.characteristics();
        let find = |u: Uuid| chars.iter().find(|c| c.uuid == u).cloned();
        let (chr, secure) = match (prefer_secure, find(CHAR_SECURE), find(CHAR_UNSECURE)) {
            (true, Some(s), _) => (s, true),
            (_, _, Some(u)) => (u, false),
            (_, Some(s), None) => (s, true),
            _ => bail!(
                "no BMAP characteristic found; services: {:?}",
                chars.iter().map(|c| c.uuid.to_string()).collect::<Vec<_>>()
            ),
        };
        if !chr.properties.intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE) {
            bail!("BMAP characteristic {} has no notify/indicate property: {:?}", chr.uuid, chr.properties);
        }
        let mut stream = p.notifications().await?;
        eprintln!("[ble] subscribing to {} (the OS may ask you to pair — approve it)…", chr.uuid);
        tokio::time::timeout(Duration::from_secs(40), p.subscribe(&chr))
            .await
            .map_err(|_| anyhow!("subscribe timed out after 40 s (pairing dialog not approved?)"))?
            .context("subscribe to BMAP characteristic")?;
        eprintln!("[ble] subscribed");

        let (tx, rx) = mpsc::unbounded_channel();
        let uuid = chr.uuid;
        tokio::spawn(async move {
            let mut re = Reassembler::default();
            while let Some(n) = stream.next().await {
                if n.uuid != uuid {
                    continue;
                }
                match re.push(&n.value) {
                    Ok(Some(msg)) => {
                        if tx.send(msg).is_err() {
                            break;
                        }
                    }
                    Ok(None) => {}
                    Err(e) => eprintln!("[ble] dropping malformed notification {:02x?}: {e}", n.value),
                }
            }
        });
        Ok(Self { peripheral: p, chr, rx: Mutex::new(rx), uses_secure_characteristic: secure })
    }

    pub fn characteristic_uuid(&self) -> Uuid {
        self.chr.uuid
    }
    pub fn characteristic_properties(&self) -> CharPropFlags {
        self.chr.properties
    }
    pub async fn disconnect(&self) -> Result<()> {
        self.peripheral.disconnect().await?;
        Ok(())
    }
}

impl Link for BleLink {
    async fn send(&self, packet: &[u8]) -> Result<()> {
        for seg in segment(packet, SAFE_CHUNK).map_err(|e| anyhow!(e))? {
            tokio::time::timeout(Duration::from_secs(15), self.peripheral.write(&self.chr, &seg, WriteType::WithResponse))
                .await
                .map_err(|_| {
                    anyhow!("BLE write timed out after 15 s: the encrypted link never completed. Put the headphones in pairing mode (hold the Bluetooth button until the light blinks blue) and retry")
                })??;
        }
        Ok(())
    }
    async fn recv(&self) -> Result<Vec<u8>> {
        self.rx.lock().await.recv().await.ok_or_else(|| anyhow!("BLE notification stream ended (device disconnected?)"))
    }
}
