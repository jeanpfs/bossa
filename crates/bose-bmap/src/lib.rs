//! BMAP codec (Bose Messaging Application Protocol), as recovered from the Android app.
//! Pure, synchronous, no I/O: packets, BLE segmentation/reassembly and typed payload parsers.
//! Spec: docs/bmap-protocol.md and docs/bmap-functions.json.

use std::fmt;

// ---- Function blocks / functions used so far -------------------------------------------------

pub mod fblock {
    pub const PRODUCT_INFO: u8 = 0;
    pub const SETTINGS: u8 = 1;
    pub const STATUS: u8 = 2;
    pub const DEVICE_MANAGEMENT: u8 = 4;
    pub const AUDIO_MANAGEMENT: u8 = 5;
    pub const AUDIO_MODES: u8 = 31;
}

pub mod func {
    // ProductInfo (0)
    pub const BMAP_VERSION: u8 = 1;
    pub const ALL_FBLOCKS: u8 = 2;
    pub const PRODUCT_ID_VARIANTS: u8 = 3;
    pub const FIRMWARE_VERSION: u8 = 5;
    pub const MAC_ADDRESS: u8 = 6;
    pub const SERIAL_NUMBER: u8 = 7;
    // Settings (1)
    pub const PRODUCT_NAME: u8 = 2;
    pub const CNC: u8 = 5;
    pub const MULTIPOINT: u8 = 10;
    pub const BUTTONS: u8 = 9;
    pub const AUTO_PLAY_PAUSE: u8 = 24;
    pub const DISABLE_CAPTOUCH: u8 = 34;
    // Status (2)
    pub const BATTERY_LEVEL: u8 = 2;
    // AudioManagement (5)
    pub const VOLUME: u8 = 5;
    // AudioModes (31)
    pub const CURRENT_MODE: u8 = 3;
    pub const MODES_CAPABILITIES: u8 = 2;
    pub const MODES_DEFAULT: u8 = 4;
    pub const MODES_FAVORITES: u8 = 8;
    pub const MODES_RESET: u8 = 9;
    pub const MODES_NAMES_SUPPORTED: u8 = 11;
    pub const MODE_CONFIG: u8 = 6;
    pub const MODES_SETTINGS_CONFIG: u8 = 10;
}

// ---- Operators and packets -------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Operator {
    Set = 0,
    Get = 1,
    SetGet = 2,
    Status = 3,
    Error = 4,
    Start = 5,
    Result = 6,
    Processing = 7,
}

impl Operator {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Set,
            1 => Self::Get,
            2 => Self::SetGet,
            3 => Self::Status,
            4 => Self::Error,
            5 => Self::Start,
            6 => Self::Result,
            7 => Self::Processing,
            _ => return None,
        })
    }
    /// Operators that end a request (the device is done answering).
    pub fn is_terminal_response(self) -> bool {
        matches!(self, Self::Status | Self::Result | Self::Error)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BmapError {
    /// Packet shorter than its header or declared payload.
    Truncated { need: usize, have: usize },
    UnknownOperator(u8),
    PayloadTooLong(usize),
    TooManySegments(usize),
    /// Segment header inconsistent with earlier segments of the same message.
    BadSegment(String),
    /// Payload shorter than the layout needs.
    BadPayload { what: &'static str, len: usize },
}

impl fmt::Display for BmapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated { need, have } => write!(f, "truncated packet: need {need} bytes, have {have}"),
            Self::UnknownOperator(v) => write!(f, "unknown operator {v}"),
            Self::PayloadTooLong(n) => write!(f, "payload of {n} bytes exceeds 255"),
            Self::TooManySegments(n) => write!(f, "{n} segments exceeds the 16-segment limit"),
            Self::BadSegment(s) => write!(f, "bad segment: {s}"),
            Self::BadPayload { what, len } => write!(f, "bad {what} payload ({len} bytes)"),
        }
    }
}
impl std::error::Error for BmapError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub fblock: u8,
    pub function: u8,
    pub device: u8, // top 2 bits of byte 2
    pub port: u8,   // bits 5:4 of byte 2
    pub operator: Operator,
    pub payload: Vec<u8>,
}

pub const HEADER_LEN: usize = 4;

impl Packet {
    pub fn new(fblock: u8, function: u8, operator: Operator, payload: Vec<u8>) -> Self {
        Self { fblock, function, device: 0, port: 0, operator, payload }
    }
    pub fn get(fblock: u8, function: u8) -> Self {
        Self::new(fblock, function, Operator::Get, Vec::new())
    }

    pub fn encode(&self) -> Result<Vec<u8>, BmapError> {
        if self.payload.len() > 255 {
            return Err(BmapError::PayloadTooLong(self.payload.len()));
        }
        let mut v = Vec::with_capacity(HEADER_LEN + self.payload.len());
        v.push(self.fblock);
        v.push(self.function);
        v.push((self.device << 6) | ((self.port & 3) << 4) | self.operator as u8);
        v.push(self.payload.len() as u8);
        v.extend_from_slice(&self.payload);
        Ok(v)
    }

    /// Decode one packet from the front of `buf`; returns it and the bytes consumed.
    pub fn decode(buf: &[u8]) -> Result<(Packet, usize), BmapError> {
        if buf.len() < HEADER_LEN {
            return Err(BmapError::Truncated { need: HEADER_LEN, have: buf.len() });
        }
        let len = buf[3] as usize;
        if buf.len() < HEADER_LEN + len {
            return Err(BmapError::Truncated { need: HEADER_LEN + len, have: buf.len() });
        }
        let b2 = buf[2];
        let operator = Operator::from_u8(b2 & 0x0F).ok_or(BmapError::UnknownOperator(b2 & 0x0F))?;
        Ok((
            Packet {
                fblock: buf[0],
                function: buf[1],
                device: b2 >> 6,
                port: (b2 >> 4) & 3,
                operator,
                payload: buf[HEADER_LEN..HEADER_LEN + len].to_vec(),
            },
            HEADER_LEN + len,
        ))
    }

    /// A reassembled BLE message may hold several packets back to back.
    pub fn decode_all(mut buf: &[u8]) -> Result<Vec<Packet>, BmapError> {
        let mut out = Vec::new();
        while !buf.is_empty() {
            let (p, n) = Packet::decode(buf)?;
            out.push(p);
            buf = &buf[n..];
        }
        Ok(out)
    }

    /// Error packets: payload `[code]` or `[0xFF, subcode]` (function-block specific).
    pub fn error_code(&self) -> Option<u8> {
        (self.operator == Operator::Error).then(|| self.payload.first().copied().unwrap_or(0))
    }
}

// ---- BLE segmentation ------------------------------------------------------------------------

/// Split an encoded packet into BLE writes. `chunk` = data bytes per write (ATT payload - 1).
/// Each write is `[(maxIdx << 4) | idx][data...]`; a lone write has header 0x00.
/// (The Android app loses the last chunk when the length is an exact multiple of `chunk`; this doesn't.)
pub fn segment(packet: &[u8], chunk: usize) -> Result<Vec<Vec<u8>>, BmapError> {
    assert!(chunk > 0);
    let pieces: Vec<&[u8]> = if packet.is_empty() { vec![packet] } else { packet.chunks(chunk).collect() };
    if pieces.len() > 16 {
        return Err(BmapError::TooManySegments(pieces.len()));
    }
    let max = (pieces.len() - 1) as u8;
    Ok(pieces
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let mut w = Vec::with_capacity(1 + p.len());
            w.push((max << 4) | i as u8);
            w.extend_from_slice(p);
            w
        })
        .collect())
}

/// Collects notification chunks until the last segment arrives.
#[derive(Default)]
pub struct Reassembler {
    max: Option<u8>,
    parts: Vec<(u8, Vec<u8>)>,
}

impl Reassembler {
    pub fn push(&mut self, chunk: &[u8]) -> Result<Option<Vec<u8>>, BmapError> {
        let Some((&h, data)) = chunk.split_first() else {
            return Err(BmapError::BadSegment("empty notification".into()));
        };
        let (hi, lo) = ((h >> 4) & 0xF, h & 0xF);
        match self.max {
            None => self.max = Some(hi),
            Some(m) if m != hi => {
                self.reset();
                return Err(BmapError::BadSegment(format!("max index changed {m} -> {hi}")));
            }
            _ => {}
        }
        self.parts.push((lo, data.to_vec()));
        // Same completion rule as the app: header 0x00 or idx == maxIdx.
        if h == 0 || hi == lo {
            let mut parts = std::mem::take(&mut self.parts);
            self.max = None;
            if parts.len() != hi as usize + 1 {
                return Err(BmapError::BadSegment(format!("got {} segments, expected {}", parts.len(), hi as usize + 1)));
            }
            parts.sort_by_key(|(i, _)| *i);
            return Ok(Some(parts.into_iter().flat_map(|(_, d)| d).collect()));
        }
        Ok(None)
    }
    pub fn reset(&mut self) {
        self.max = None;
        self.parts.clear();
    }
}

// ---- Typed payloads --------------------------------------------------------------------------

pub fn utf8(payload: &[u8]) -> String {
    String::from_utf8_lossy(payload).trim_end_matches('\0').to_string()
}

/// ProductInfo.ProductIdVariants -> (product id, variant).
pub fn parse_product_id(p: &[u8]) -> Result<(u16, u8), BmapError> {
    if p.len() < 3 {
        return Err(BmapError::BadPayload { what: "product id", len: p.len() });
    }
    Ok((u16::from_be_bytes([p[0], p[1]]), p[2]))
}

/// ProductInfo.AllFblocks bitset: bit N (N = function-block id) is in byte[len-1-N/8], bit N%8.
pub fn parse_fblocks(p: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for n in 0..(p.len() * 8) {
        let byte = p[p.len() - 1 - n / 8];
        if byte & (1 << (n % 8)) != 0 {
            out.push(n as u8);
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Battery {
    pub percentage: u8,
    /// None when the device reports 0xFFFF (unknown) or omits the field.
    pub remaining_minutes: Option<u16>,
    pub component: Option<u8>,
}

/// Status.BatteryLevel: 1..4 bytes is one entry; otherwise repeated 4-byte entries.
pub fn parse_battery(p: &[u8]) -> Result<Vec<Battery>, BmapError> {
    if p.is_empty() {
        return Err(BmapError::BadPayload { what: "battery", len: 0 });
    }
    let one = |e: &[u8]| Battery {
        percentage: e[0],
        remaining_minutes: (e.len() >= 3).then(|| u16::from_be_bytes([e[1], e[2]])).filter(|m| *m != 0xFFFF),
        component: e.get(3).copied(),
    };
    Ok(if p.len() <= 4 { vec![one(p)] } else { p.chunks(4).filter(|c| c.len() >= 1).map(one).collect() })
}

/// AudioManagement.Volume -> (current, max).
pub fn parse_volume(p: &[u8]) -> Result<(u8, u8), BmapError> {
    if p.len() < 2 {
        return Err(BmapError::BadPayload { what: "volume", len: p.len() });
    }
    Ok((p[0], p[1]))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cnc {
    pub num_steps: u8,
    pub current_step: u8,
    pub enabled: bool,
    pub user_can_toggle: bool,
}

pub fn parse_cnc(p: &[u8]) -> Result<Cnc, BmapError> {
    if p.len() < 3 {
        return Err(BmapError::BadPayload { what: "cnc", len: p.len() });
    }
    Ok(Cnc { num_steps: p[0], current_step: p[1], enabled: p[2] & 1 != 0, user_can_toggle: p[2] & 2 == 0 })
}

/// Settings.ProductName -> (is_default, name).
pub fn parse_product_name(p: &[u8]) -> Result<(bool, String), BmapError> {
    let (&flags, name) = p.split_first().ok_or(BmapError::BadPayload { what: "product name", len: 0 })?;
    Ok((flags & 1 != 0, utf8(name)))
}

/// AudioModes.Capabilities (fn 2). Only the counts are certain; the capability bits are not mapped yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModesCapabilities {
    pub bose_modes: u8,
    pub user_modes: u8,
    pub raw_flags: u8,
    pub minimum_favorites: Option<u8>,
}

pub fn parse_modes_capabilities(p: &[u8]) -> Result<ModesCapabilities, BmapError> {
    if p.len() < 6 {
        return Err(BmapError::BadPayload { what: "modes capabilities", len: p.len() });
    }
    Ok(ModesCapabilities { bose_modes: p[0], user_modes: p[1], raw_flags: p[5], minimum_favorites: p.get(6).copied() })
}

/// AudioModes.ModeConfig status for one mode (fn 6, Get [modeIndex]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModeConfig {
    pub index: u8,
    pub prompt: (u8, u8),
    pub user_configurable: bool,
    pub user_configured: bool,
    pub favorite: bool,
    pub name: String,
    /// bit0 cnc, bit1 autoCNC, bit2 spatial, bit3 anr/wind, bit4 anc toggle may be changed by the user.
    pub mutability: u8,
    pub cnc_level: u8,
    pub auto_cnc: bool,
    pub spatial_audio: Option<u8>,
    pub wind_block: Option<u8>,
    pub anc_toggle: Option<u8>,
}

pub fn parse_mode_config(p: &[u8]) -> Result<ModeConfig, BmapError> {
    if p.len() < 44 {
        return Err(BmapError::BadPayload { what: "mode config", len: p.len() });
    }
    Ok(ModeConfig {
        index: p[0],
        prompt: (p[1], p[2]),
        user_configurable: p[3] == 1,
        user_configured: p[4] == 1,
        favorite: p[5] == 1,
        name: utf8(&p[6..38].iter().copied().take_while(|b| *b != 0).collect::<Vec<_>>()),
        mutability: p[41],
        cnc_level: p[42],
        auto_cnc: p[43] == 1,
        spatial_audio: p.get(44).copied(),
        wind_block: p.get(46).copied(),
        anc_toggle: p.get(47).copied(),
    })
}

/// What the user may configure on a user-defined mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModeWrite<'a> {
    pub index: u8,
    /// Voice-prompt id `(byte1, byte2)`; `(0, 0)` = none.
    pub prompt: (u8, u8),
    pub name: &'a str,
    pub cnc_level: u8,
    pub auto_cnc: bool,
    pub spatial_audio: u8,
    pub wind_block: bool,
    pub anc_toggle: bool,
}

/// Payload of ModeConfig SetGet (fn 6): `[idx, p1, p2, name[32], cnc, auto, spatial, wind, anc]`.
/// The name is UTF-8, at most 31 bytes (cut on a character boundary), NUL padded.
pub fn build_mode_config(w: &ModeWrite<'_>) -> Vec<u8> {
    let mut name = [0u8; 32];
    let mut n = 0;
    for ch in w.name.chars() {
        let l = ch.len_utf8();
        if n + l > 31 {
            break;
        }
        ch.encode_utf8(&mut name[n..n + l]);
        n += l;
    }
    let mut out = vec![w.index, w.prompt.0, w.prompt.1];
    out.extend_from_slice(&name);
    out.extend_from_slice(&[w.cnc_level, w.auto_cnc as u8, w.spatial_audio, w.wind_block as u8, w.anc_toggle as u8]);
    out
}

/// Settings.Buttons status (fn 9): `[buttonId, eventType, configuredMode, supported(4), unavailable(4), ...]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ButtonConfig {
    pub button_id: u8,
    pub event_type: u8,
    /// `ActionButtonMode` value (1 Vpa, 14 Disabled, 16 SpotifyGo, 17 ModesCarousel, 19 SpatialAudioMode, ...).
    pub mode: u8,
}

pub fn parse_button_config(p: &[u8]) -> Result<ButtonConfig, BmapError> {
    if p.len() < 3 {
        return Err(BmapError::BadPayload { what: "button config", len: p.len() });
    }
    Ok(ButtonConfig { button_id: p[0], event_type: p[1], mode: p[2] })
}

/// AudioModes.Favorites (fn 8): `[numberOfModes, mask...]`, mode `m` is bit `m % 8` of byte `len - 1 - m / 8`.
pub fn parse_favorites(p: &[u8]) -> Result<Vec<u8>, BmapError> {
    let n = *p.first().ok_or(BmapError::BadPayload { what: "favorites", len: 0 })? as usize;
    let bytes = n.div_ceil(8);
    if p.len() < 1 + bytes {
        return Err(BmapError::BadPayload { what: "favorites", len: p.len() });
    }
    Ok((0..n as u8).filter(|m| p[bytes - (*m as usize / 8)] >> (m % 8) & 1 == 1).collect())
}

pub fn build_favorites(number_of_modes: u8, favorites: &[u8]) -> Vec<u8> {
    let bytes = (number_of_modes as usize).div_ceil(8);
    let mut out = vec![0u8; 1 + bytes];
    out[0] = number_of_modes;
    for m in favorites.iter().copied().filter(|m| *m < number_of_modes) {
        out[bytes - (m as usize / 8)] |= 1 << (m % 8);
    }
    out
}

/// AudioModes.SettingsConfig (fn 10): the working settings of the *current* mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModeSettings {
    pub cnc_level: u8,
    pub auto_cnc: bool,
    pub spatial_audio: u8,
    pub anr_wind: bool,
    pub anc_toggle: bool,
}

pub fn parse_mode_settings(p: &[u8]) -> Result<ModeSettings, BmapError> {
    if p.len() < 5 {
        return Err(BmapError::BadPayload { what: "mode settings", len: p.len() });
    }
    Ok(ModeSettings { cnc_level: p[0], auto_cnc: p[1] == 1, spatial_audio: p[2], anr_wind: p[3] == 1, anc_toggle: p[4] == 1 })
}

pub fn format_mac(p: &[u8]) -> String {
    p.iter().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":")
}

/// A few ids from docs/bmap-protocol.md §9 (`work/pid.json`).
pub fn product_name(id: u16) -> Option<&'static str> {
    Some(match id {
        0x4066 => "Bose QC Ultra Headphones",
        0x4072 => "Bose QC Ultra Earbuds",
        0x4062 => "Bose QC Ultra 2 Earbuds",
        0x4082 => "Bose QC Ultra 2 HP",
        0x4089 => "Bose Ultra Open 2 Earbuds",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bmap_version_get_matches_documented_bytes() {
        let p = Packet::get(fblock::PRODUCT_INFO, func::BMAP_VERSION);
        assert_eq!(p.encode().unwrap(), [0x00, 0x01, 0x01, 0x00]);
    }

    #[test]
    fn decode_status_and_header_bits() {
        let (p, n) = Packet::decode(&[0x00, 0x01, 0x03, 0x05, b'1', b'.', b'2', b'.', b'0', 0xAA]).unwrap();
        assert_eq!(n, 9);
        assert_eq!((p.fblock, p.function, p.operator), (0, 1, Operator::Status));
        assert_eq!(utf8(&p.payload), "1.2.0");
        // device 2, port 1, operator Result
        let (p, _) = Packet::decode(&[5, 5, (2 << 6) | (1 << 4) | 6, 0]).unwrap();
        assert_eq!((p.device, p.port, p.operator), (2, 1, Operator::Result));
        let mut q = p.clone();
        q.payload = vec![];
        assert_eq!(q.encode().unwrap(), [5, 5, 0x96, 0]);
    }

    #[test]
    fn decode_errors() {
        assert!(matches!(Packet::decode(&[0, 1, 3]), Err(BmapError::Truncated { .. })));
        assert!(matches!(Packet::decode(&[0, 1, 3, 4, 1]), Err(BmapError::Truncated { need: 8, have: 5 })));
        assert!(matches!(Packet::decode(&[0, 1, 0x0A, 0]), Err(BmapError::UnknownOperator(10))));
        let big = Packet { payload: vec![0; 256], ..Packet::get(0, 1) };
        assert!(matches!(big.encode(), Err(BmapError::PayloadTooLong(256))));
    }

    #[test]
    fn decode_all_splits_back_to_back_packets() {
        let mut buf = Packet::new(2, 2, Operator::Status, vec![90]).encode().unwrap();
        buf.extend(Packet::new(5, 5, Operator::Status, vec![55, 100]).encode().unwrap());
        let v = Packet::decode_all(&buf).unwrap();
        assert_eq!(v.len(), 2);
        assert_eq!(v[1].payload, [55, 100]);
    }

    #[test]
    fn segmentation_roundtrip_including_exact_multiples() {
        for len in [0usize, 1, 18, 19, 20, 38, 39, 57, 100, 200] {
            let data: Vec<u8> = (0..len).map(|i| i as u8).collect();
            let segs = segment(&data, 19).unwrap();
            let mut r = Reassembler::default();
            let mut out = None;
            for s in &segs {
                out = r.push(s).unwrap();
            }
            assert_eq!(out.unwrap(), data, "len {len}");
        }
        // single write uses header 0x00
        assert_eq!(segment(&[1, 2, 3], 19).unwrap(), vec![vec![0x00, 1, 2, 3]]);
        // 3 segments: headers 0x20, 0x21, 0x22
        let s = segment(&vec![7; 45], 19).unwrap();
        assert_eq!(s.iter().map(|x| x[0]).collect::<Vec<_>>(), [0x20, 0x21, 0x22]);
    }

    #[test]
    fn segmentation_limits_and_reassembly_errors() {
        assert!(matches!(segment(&vec![0; 17 * 19], 19), Err(BmapError::TooManySegments(17))));
        let mut r = Reassembler::default();
        assert!(r.push(&[0x20, 1]).unwrap().is_none());
        assert!(matches!(r.push(&[0x11, 2]), Err(BmapError::BadSegment(_))));
        // missing middle segment is reported, not silently concatenated
        let mut r = Reassembler::default();
        assert!(r.push(&[0x20, 1]).unwrap().is_none());
        assert!(matches!(r.push(&[0x22, 3]), Err(BmapError::BadSegment(_))));
    }

    #[test]
    fn fblock_bitset_uses_reversed_byte_order() {
        // bit0 (ProductInfo) and bit31 (AudioModes) in a 4-byte set: bit31 -> byte[0] bit7
        assert_eq!(parse_fblocks(&[0x80, 0x00, 0x00, 0x03]), vec![0, 1, 31]);
        // bit 9 (Notification) in a 2-byte set lives in byte[0] bit1
        assert_eq!(parse_fblocks(&[0x02, 0x00]), vec![9]);
    }

    #[test]
    fn battery_single_and_multi_entry() {
        assert_eq!(parse_battery(&[90]).unwrap(), vec![Battery { percentage: 90, remaining_minutes: None, component: None }]);
        assert_eq!(parse_battery(&[90, 0x04, 0xB0]).unwrap()[0].remaining_minutes, Some(1200));
        assert_eq!(parse_battery(&[90, 0xFF, 0xFF, 1]).unwrap()[0].remaining_minutes, None);
        let m = parse_battery(&[80, 0, 60, 1, 70, 0xFF, 0xFF, 2]).unwrap();
        assert_eq!((m.len(), m[1].component), (2, Some(2)));
        assert!(parse_battery(&[]).is_err());
    }

    #[test]
    fn mode_config_layout() {
        let mut p = vec![0u8; 48];
        p[0] = 2; // index
        p[3] = 1; // userConfigurable
        p[5] = 1; // favorite
        p[6..6 + 8].copy_from_slice(b"Immersao");
        p[41] = 0b00101;
        p[42] = 7; // cnc level
        p[43] = 1; // autoCNC
        p[44] = 3; // spatial
        let m = parse_mode_config(&p).unwrap();
        assert_eq!((m.index, m.name.as_str(), m.favorite, m.user_configurable, m.user_configured), (2, "Immersao", true, true, false));
        assert_eq!((m.mutability, m.cnc_level, m.auto_cnc, m.spatial_audio), (0b00101, 7, true, Some(3)));
        assert_eq!((m.wind_block, m.anc_toggle), (Some(0), Some(0)));
        assert!(parse_mode_config(&p[..43]).is_err());
        assert_eq!(parse_mode_config(&p[..44]).unwrap().spatial_audio, None);
    }

    #[test]
    fn mode_config_write_payload() {
        let w = ModeWrite { index: 4, prompt: (0, 13), name: "Foco", cnc_level: 6, auto_cnc: false, spatial_audio: 0, wind_block: false, anc_toggle: true };
        let p = build_mode_config(&w);
        assert_eq!(p.len(), 40);
        assert_eq!(&p[..3], &[4, 0, 13]);
        assert_eq!(&p[3..7], b"Foco");
        assert!(p[7..35].iter().all(|b| *b == 0));
        assert_eq!(&p[35..], &[6, 0, 0, 0, 1]);
        // 31-byte cap, never splitting a multi-byte character
        let long = "é".repeat(20);
        let p = build_mode_config(&ModeWrite { name: &long, ..w.clone() });
        assert_eq!(p[3 + 30], 0);
        assert_eq!(std::str::from_utf8(&p[3..3 + 30]).unwrap(), "é".repeat(15));
    }

    #[test]
    fn button_config_from_real_payload() {
        // Captured from a QC Ultra 2 HP.
        let p = [0x80, 0x09, 0x01, 0x00, 0x09, 0x40, 0x02, 0, 0, 0, 0];
        assert_eq!(parse_button_config(&p).unwrap(), ButtonConfig { button_id: 128, event_type: 9, mode: 1 });
        assert!(parse_button_config(&p[..2]).is_err());
    }

    #[test]
    fn favorites_bitmask_layout() {
        // 11 modes -> 2 mask bytes; the LAST byte holds modes 0..7.
        let p = build_favorites(11, &[0, 1, 2, 9]);
        assert_eq!(p, vec![11, 0b10, 0b0000_0111]);
        assert_eq!(parse_favorites(&p).unwrap(), vec![0, 1, 2, 9]);
        assert_eq!(build_favorites(11, &[11, 200]), vec![11, 0, 0]);
        assert!(parse_favorites(&[11, 0]).is_err());
        assert!(parse_favorites(&[]).is_err());
    }

    #[test]
    fn mode_settings_and_capabilities() {
        assert_eq!(
            parse_mode_settings(&[10, 0, 2, 1, 1]).unwrap(),
            ModeSettings { cnc_level: 10, auto_cnc: false, spatial_audio: 2, anr_wind: true, anc_toggle: true }
        );
        assert!(parse_mode_settings(&[1, 2, 3]).is_err());
        let c = parse_modes_capabilities(&[4, 3, 0, 0, 0, 0b10101, 1]).unwrap();
        assert_eq!((c.bose_modes, c.user_modes, c.raw_flags, c.minimum_favorites), (4, 3, 0b10101, Some(1)));
        assert_eq!(parse_modes_capabilities(&[4, 3, 0, 0, 0, 1]).unwrap().minimum_favorites, None);
    }

    #[test]
    fn small_parsers() {
        assert_eq!(parse_volume(&[55, 100]).unwrap(), (55, 100));
        assert!(parse_volume(&[55]).is_err());
        let c = parse_cnc(&[10, 10, 0b01]).unwrap();
        assert_eq!((c.num_steps, c.current_step, c.enabled, c.user_can_toggle), (10, 10, true, true));
        assert!(!parse_cnc(&[10, 3, 0b10]).unwrap().user_can_toggle);
        assert_eq!(parse_product_id(&[0x40, 0x82, 3]).unwrap(), (0x4082, 3));
        assert_eq!(parse_product_name(&[1, b'H', b'P']).unwrap(), (true, "HP".to_string()));
        assert_eq!(format_mac(&[0x68, 0xF2, 0x1F, 0x0C, 0x70, 0x59]), "68:F2:1F:0C:70:59");
    }
}
