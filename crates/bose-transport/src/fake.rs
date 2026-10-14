//! In-memory fake headphones for tests and UI development (no Bluetooth needed).
//! Answers the functions the CLI/tray use with a believable QC Ultra 2 HP state.

use anyhow::Result;
use bose_bmap::{fblock as fb, func, Operator, Packet};
use parking_lot::Mutex;
use tokio::sync::mpsc;

use crate::Link;

pub struct FakeHeadphones {
    state: Mutex<State>,
    tx: mpsc::UnboundedSender<Vec<u8>>,
    rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
}

struct State {
    battery: u8,
    volume: u8,
    cnc_step: u8,
    mode: u8,
}

impl FakeHeadphones {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self { state: Mutex::new(State { battery: 90, volume: 55, cnc_step: 10, mode: 0 }), tx, rx: tokio::sync::Mutex::new(rx) }
    }

    fn answer(&self, req: &Packet) -> Packet {
        let mut s = self.state.lock();
        let ok = |payload: Vec<u8>| Packet::new(req.fblock, req.function, Operator::Status, payload);
        let err = |code: u8| Packet::new(req.fblock, req.function, Operator::Error, vec![code]);
        match (req.fblock, req.function, req.operator) {
            (fb::PRODUCT_INFO, func::BMAP_VERSION, Operator::Get) => ok(b"1.2.0".to_vec()),
            (fb::PRODUCT_INFO, func::PRODUCT_ID_VARIANTS, Operator::Get) => ok(vec![0x40, 0x82, 1]),
            (fb::PRODUCT_INFO, func::ALL_FBLOCKS, Operator::Get) => {
                // ProductInfo, Settings, Status, DeviceManagement, AudioManagement, Control, AudioModes
                let mut bits = [0u8; 4];
                for n in [0u8, 1, 2, 4, 5, 7, 31] {
                    bits[3 - (n / 8) as usize] |= 1 << (n % 8);
                }
                ok(bits.to_vec())
            }
            (fb::PRODUCT_INFO, func::FIRMWARE_VERSION, Operator::Get) => ok(b"8.2.15".to_vec()),
            (fb::PRODUCT_INFO, func::MAC_ADDRESS, Operator::Get) => ok(vec![0x68, 0xF2, 0x1F, 0x0C, 0x70, 0x59]),
            (fb::STATUS, func::BATTERY_LEVEL, Operator::Get) => ok(vec![s.battery, 0x04, 0xB0]),
            (fb::AUDIO_MANAGEMENT, func::VOLUME, Operator::Get) => ok(vec![s.volume, 100]),
            (fb::AUDIO_MANAGEMENT, func::VOLUME, Operator::SetGet) if !req.payload.is_empty() => {
                s.volume = req.payload[0].min(100);
                ok(vec![s.volume, 100])
            }
            (fb::SETTINGS, func::CNC, Operator::Get) => ok(vec![10, s.cnc_step, 0b01]),
            (fb::SETTINGS, func::CNC, Operator::SetGet) if req.payload.len() >= 2 => {
                s.cnc_step = req.payload[0].min(10);
                ok(vec![10, s.cnc_step, 0b01])
            }
            (fb::SETTINGS, func::PRODUCT_NAME, Operator::Get) => {
                let mut v = vec![1];
                v.extend_from_slice(b"Bose QC Ultra 2 HP");
                ok(v)
            }
            (fb::AUDIO_MODES, func::CURRENT_MODE, Operator::Get) => ok(vec![s.mode]),
            (fb::AUDIO_MODES, func::CURRENT_MODE, Operator::Start) if !req.payload.is_empty() => {
                s.mode = req.payload[0];
                Packet::new(req.fblock, req.function, Operator::Result, vec![s.mode])
            }
            (fb::PRODUCT_INFO | fb::SETTINGS | fb::STATUS | fb::AUDIO_MANAGEMENT | fb::AUDIO_MODES, _, _) => err(4), // FuncNotSupp
            _ => err(3),                                                                                            // FblockNotSupp
        }
    }
}

impl Default for FakeHeadphones {
    fn default() -> Self {
        Self::new()
    }
}

impl Link for FakeHeadphones {
    async fn send(&self, packet: &[u8]) -> Result<()> {
        let req = Packet::decode(packet).map_err(|e| anyhow::anyhow!(e))?.0;
        let resp = self.answer(&req).encode().map_err(|e| anyhow::anyhow!(e))?;
        self.tx.send(resp)?;
        Ok(())
    }
    async fn recv(&self) -> Result<Vec<u8>> {
        self.rx.lock().await.recv().await.ok_or_else(|| anyhow::anyhow!("fake link closed"))
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use bose_bmap::*;

    use super::*;
    use crate::{DeviceError, Session};

    const T: Duration = Duration::from_millis(500);

    #[tokio::test]
    async fn session_reads_and_writes_state() {
        let mut s = Session::new(FakeHeadphones::new());
        let v = s.get(fblock::PRODUCT_INFO, func::BMAP_VERSION, T).await.unwrap();
        assert_eq!(utf8(&v.payload), "1.2.0");
        let b = s.get(fblock::STATUS, func::BATTERY_LEVEL, T).await.unwrap();
        assert_eq!(parse_battery(&b.payload).unwrap()[0].percentage, 90);

        let set = Packet::new(fblock::AUDIO_MANAGEMENT, func::VOLUME, Operator::SetGet, vec![70]);
        assert_eq!(parse_volume(&s.request(set, T).await.unwrap().payload).unwrap(), (70, 100));
        let again = s.get(fblock::AUDIO_MANAGEMENT, func::VOLUME, T).await.unwrap();
        assert_eq!(parse_volume(&again.payload).unwrap().0, 70);
    }

    #[tokio::test]
    async fn error_operator_surfaces_as_device_error() {
        let mut s = Session::new(FakeHeadphones::new());
        let e = s.get(fblock::SETTINGS, 99, T).await.unwrap_err();
        assert_eq!(e.downcast_ref::<DeviceError>().unwrap().code, 4);
        let e = s.get(6, 1, T).await.unwrap_err(); // CallManagement: not implemented by the fake
        assert_eq!(e.downcast_ref::<DeviceError>().unwrap().code, 3);
    }

    #[tokio::test]
    async fn start_operator_returns_result_and_sets_mode() {
        let mut s = Session::new(FakeHeadphones::new());
        let r = s.request(Packet::new(fblock::AUDIO_MODES, func::CURRENT_MODE, Operator::Start, vec![2, 0]), T).await.unwrap();
        assert_eq!((r.operator, r.payload), (Operator::Result, vec![2]));
        let cur = s.get(fblock::AUDIO_MODES, func::CURRENT_MODE, T).await.unwrap();
        assert_eq!(cur.payload, [2]);
    }

    #[tokio::test]
    async fn times_out_when_device_is_silent() {
        struct Silent;
        impl Link for Silent {
            async fn send(&self, _: &[u8]) -> anyhow::Result<()> {
                Ok(())
            }
            async fn recv(&self) -> anyhow::Result<Vec<u8>> {
                std::future::pending().await
            }
        }
        let mut s = Session::new(Silent);
        let e = s.get(0, 1, Duration::from_millis(50)).await.unwrap_err();
        assert!(e.to_string().contains("timeout"), "{e}");
    }
}
