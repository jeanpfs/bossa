//! Background task: find the headphones, keep a BMAP session open, poll their state and push it to
//! the UI + tray icon. Reconnects on its own (headphones turned off/on, sleep/wake, Bluetooth toggled).

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use bose_bmap::{self as bmap, fblock, func};
use bose_transport::ble::{self, BleLink};
use bose_transport::Session;
use parking_lot::Mutex;
use serde::Serialize;

use crate::prefs::SharedPrefs;

const WAIT: Duration = Duration::from_secs(4);
const POLL: Duration = Duration::from_secs(5);
/// Pause between connection attempts when the headphones are simply not there.
const RETRY_NOT_FOUND: Duration = Duration::from_secs(3);
const RETRY_ERROR: Duration = Duration::from_secs(8);

/// One audio mode as configured on the headphones (AudioModes.ModeConfig).
#[derive(Clone, Serialize, Debug)]
pub struct ModeInfo {
    pub index: u8,
    pub name: String,
    pub favorite: bool,
    pub user_configurable: bool,
    pub user_configured: bool,
    pub cnc_mutable: bool,
    pub spatial_mutable: bool,
    /// 0 = full noise cancelling ... 10 = full awareness.
    pub cnc_level: u8,
    /// 0 off, 1 fixed, 2 head-tracked (off / fixed / head-tracked).
    pub spatial_audio: u8,
}

/// Working settings of the current mode (AudioModes.SettingsConfig).
#[derive(Clone, Serialize, Default, Debug)]
pub struct ModeSettingsView {
    pub cnc_level: u8,
    pub auto_cnc: bool,
    pub spatial_audio: u8,
    pub anr_wind: bool,
    pub anc_toggle: bool,
}

/// One equalizer slider (Settings.RangeControl, fn 7): 0 bass, 1 mid, 2 treble (3 low-mid / 4 high-mid exist in the protocol).
#[derive(Clone, Serialize, Debug, PartialEq, Eq)]
pub struct EqBand {
    pub id: u8,
    pub min: i8,
    pub max: i8,
    pub current: i8,
}

/// Payload = repeated 4-byte entries `[min, max, current, id]` (signed levels).
pub fn parse_eq(payload: &[u8]) -> Vec<EqBand> {
    payload.chunks_exact(4).map(|c| EqBand { min: c[0] as i8, max: c[1] as i8, current: c[2] as i8, id: c[3] }).collect()
}

#[derive(Clone, Serialize, Default, Debug)]
pub struct Multipoint {
    pub enabled: bool,
    pub supported: bool,
}

/// `status`: searching | connecting | connected | error
#[derive(Clone, Serialize, Debug)]
pub struct DeviceState {
    pub status: &'static str,
    pub message: Option<String>,
    pub name: Option<String>,
    pub firmware: Option<String>,
    /// Classic Bluetooth address, used to find the headphones among the Mac's audio devices.
    pub mac: Option<String>,
    pub battery: Option<u8>,
    pub remaining_minutes: Option<u16>,
    pub modes: Vec<ModeInfo>,
    pub settings: Option<ModeSettingsView>,
    pub multipoint: Option<Multipoint>,
    pub mode: Option<u8>,
    /// `ActionButtonMode` of the shortcut button.
    pub shortcut_mode: Option<u8>,
    /// `ActionButtonMode` values the shortcut button can be set to right now (supported and not unavailable).
    pub shortcut_options: Vec<u8>,
    /// Pause playback when the headphones come off (Settings.AutoPlayPause).
    pub auto_pause: Option<bool>,
    /// Raw Settings.DisableCaptouch value; its meaning for the user is not confirmed yet.
    pub captouch_flag: Option<bool>,
    /// Equalizer sliders; empty when the product does not report them.
    pub eq: Vec<EqBand>,
}

impl Default for DeviceState {
    fn default() -> Self {
        Self { status: "searching", message: None, name: None, firmware: None, mac: None, battery: None, remaining_minutes: None, modes: Vec::new(), settings: None, multipoint: None, mode: None, shortcut_mode: None, shortcut_options: Vec::new(), auto_pause: None, captouch_flag: None, eq: Vec::new() }
    }
}

pub type Shared = Arc<Mutex<DeviceState>>;

/// Requests from the UI to the task that owns the BLE session.
#[derive(Debug, serde::Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    SetMode { index: u8 },
    /// Create a user-defined mode in the first free slot; `prefix` is the localised "Custom" word for its default name.
    CreateMode {
        #[serde(default)]
        prefix: Option<String>,
    },
    /// Change the noise level (0 = full cancelling .. 10 = awareness) and immersive mode of a user-defined mode.
    SaveMode { index: u8, cnc_level: u8, spatial_audio: u8 },
    /// Delete a user-defined mode (frees its slot).
    ResetMode { index: u8 },
    /// Rename a user-defined mode.
    RenameMode { index: u8, name: String },
    /// Add or remove a mode from the favourites (the modes the headphones' button cycles through).
    SetFavorite { index: u8, on: bool },
    /// Set one equalizer band (-10..=10 on a QC Ultra 2 HP).
    SetEq { band: u8, level: i8 },
    /// Skip the wait between connection attempts and look for the headphones right now.
    Rescan,
    /// Change what the shortcut button does (`ActionButtonMode`); must be one of `shortcut_options`.
    SetShortcut { mode: u8 },
}
pub struct Handle(pub tokio::sync::mpsc::UnboundedSender<Command>);
pub type Commands = tokio::sync::mpsc::UnboundedReceiver<Command>;

/// The headphones were not seen during the scan (off, out of range, or connected elsewhere).
#[derive(Debug)]
struct NotFound;
impl std::fmt::Display for NotFound {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no matching Bose device found")
    }
}
impl std::error::Error for NotFound {}

/// An established session stopped answering (headphones switched off, out of range, Bluetooth toggled).
/// Not an error to show: the loop just goes back to searching.
#[derive(Debug)]
struct LinkLost(String);
impl std::fmt::Display for LinkLost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "link lost: {}", self.0)
    }
}
impl std::error::Error for LinkLost {}

// ---- Low-battery alerts ------------------------------------------------------------------------

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Alert {
    Low,
    Critical,
}

pub const LOW_AT: u8 = 20;
pub const CRITICAL_AT: u8 = 10;
/// Alerts re-arm once the battery climbs back above this (hysteresis, so 21 <-> 19 doesn't spam).
pub const REARM_ABOVE: u8 = 25;

#[derive(Default, Debug)]
pub struct AlertState {
    low_sent: bool,
    critical_sent: bool,
}

impl AlertState {
    /// Feed each battery reading; returns an alert at most once per discharge per threshold.
    pub fn check(&mut self, level: u8) -> Option<Alert> {
        if level > REARM_ABOVE {
            *self = Self::default();
            return None;
        }
        if level <= CRITICAL_AT && !self.critical_sent {
            self.critical_sent = true;
            self.low_sent = true;
            return Some(Alert::Critical);
        }
        if level <= LOW_AT && !self.low_sent {
            self.low_sent = true;
            return Some(Alert::Low);
        }
        None
    }
}

/// What the task needs from its host: a way to push events (JSON lines) to the UI, and the preferences.
#[derive(Clone)]
pub struct Ctx {
    pub emit: Arc<dyn Fn(String) + Send + Sync>,
    pub prefs: Arc<SharedPrefs>,
}

impl Ctx {
    fn send(&self, v: serde_json::Value) {
        (self.emit)(v.to_string());
    }

    /// Ask the UI to post a low-battery notification (the UI owns the wording and the language).
    pub fn alert(&self, a: Alert, name: Option<&str>, level: u8) {
        let kind = match a { Alert::Low => "low", Alert::Critical => "critical" };
        self.send(serde_json::json!({ "type": "alert", "kind": kind, "name": name, "level": level }));
    }
}

// ---- Task ---------------------------------------------------------------------------------------

fn publish(app: &Ctx, shared: &Shared, f: impl FnOnce(&mut DeviceState)) {
    let snapshot = {
        let mut s = shared.lock();
        let before = s.status;
        f(&mut s);
        if s.status != before {
            eprintln!("[device] {before} -> {} (battery {:?}, mode {:?})", s.status, s.battery, s.mode);
        }
        s.clone()
    };
    app.send(serde_json::json!({ "type": "state", "state": snapshot }));
}

pub fn spawn(rt: &tokio::runtime::Handle, app: Ctx, shared: Shared, mut rx: Commands) {
    rt.spawn(async move {
        let mut alerts = AlertState::default();
        loop {
            publish(&app, &shared, |s| {
                s.status = "searching";
                s.message = None;
            });
            let wait = match session_once(&app, &shared, &mut rx, &mut alerts).await {
                Ok(()) => RETRY_NOT_FOUND,
                Err(e) if e.downcast_ref::<NotFound>().is_some() || e.downcast_ref::<LinkLost>().is_some() => {
                    // Not an error: the headphones are off or away. Keep searching quietly.
                    eprintln!("[device] {e}");
                    RETRY_NOT_FOUND
                }
                Err(e) => {
                    eprintln!("[device] {e:#}");
                    let msg = friendly(&e);
                    publish(&app, &shared, |s| {
                        s.status = "error";
                        s.message = Some(msg);
                    });
                    RETRY_ERROR
                }
            };
            // Wait before the next attempt, unless the UI asks for an immediate rescan (other commands are dropped while offline).
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = rx.recv() => {}
            }
        }
    });
}

fn friendly(e: &anyhow::Error) -> String {
    let t = format!("{e:#}");
    if t.contains("pairing mode") {
        "To pair this computer, put the headphones in pairing mode.".into()
    } else if t.contains("no Bluetooth adapter") || t.contains("Bluetooth manager") {
        "Bluetooth is unavailable or turned off on this computer.".into()
    } else {
        format!("Connection failed: {t}")
    }
}

async fn session_once(app: &Ctx, shared: &Shared, rx: &mut Commands, alerts: &mut AlertState) -> Result<()> {
    let found = ble::scan(4).await?;
    let dev = found.iter().find(|f| f.is_bose()).ok_or(NotFound)?;
    publish(app, shared, |s| s.status = "connecting");
    let link = BleLink::connect(dev, true).await?;
    let mut sess = Session::new(link);

    while rx.try_recv().is_ok() {} // drop requests queued while we were offline
    let result = run_session(app, shared, &mut sess, rx, alerts).await;
    // Best effort; never let a stuck disconnect block the reconnect loop.
    let _ = tokio::time::timeout(Duration::from_secs(5), sess.link().disconnect()).await;
    result
}

async fn run_session(app: &Ctx, shared: &Shared, sess: &mut Session<BleLink>, rx: &mut Commands, alerts: &mut AlertState) -> Result<()> {
    // Same handshake as the official app: BmapVersion first (short), one long retry.
    if sess.get(fblock::PRODUCT_INFO, func::BMAP_VERSION, Duration::from_secs(3)).await.is_err() {
        sess.get(fblock::PRODUCT_INFO, func::BMAP_VERSION, Duration::from_secs(20)).await?;
    }
    let name = sess.get(fblock::SETTINGS, func::PRODUCT_NAME, WAIT).await.ok().and_then(|p| bmap::parse_product_name(&p.payload).ok()).map(|(_, n)| n);
    let firmware = sess.get(fblock::PRODUCT_INFO, func::FIRMWARE_VERSION, WAIT).await.ok().map(|p| bmap::utf8(&p.payload));
    let mac = sess.get(fblock::PRODUCT_INFO, func::MAC_ADDRESS, WAIT).await.ok().map(|p| bmap::format_mac(&p.payload));
    let mut modes = read_modes(sess).await;
    let mut extras = read_extras(sess).await;
    let mut cycles = 0u32;

    loop {
        cycles += 1;
        if cycles % 12 == 0 {
            let fresh = read_modes(sess).await;
            if !fresh.is_empty() {
                modes = fresh;
            }
            extras = read_extras(sess).await;
        }
        // Mandatory read: if it fails on an established session the link is gone.
        let battery = sess.get(fblock::STATUS, func::BATTERY_LEVEL, WAIT).await.map_err(|e| anyhow::Error::new(LinkLost(format!("{e:#}"))))?;
        let battery = bmap::parse_battery(&battery.payload).map_err(|e| anyhow!(e))?.into_iter().next();
        let settings = sess.get(fblock::AUDIO_MODES, func::MODES_SETTINGS_CONFIG, WAIT).await.ok().and_then(|p| bmap::parse_mode_settings(&p.payload).ok());
        let mp = sess.get(fblock::SETTINGS, func::MULTIPOINT, WAIT).await.ok().and_then(|p| p.payload.first().copied());
        let mode = sess.get(fblock::AUDIO_MODES, func::CURRENT_MODE, WAIT).await.ok().and_then(|p| p.payload.first().copied());
        let eq = sess.get(fblock::SETTINGS, EQ_FN, WAIT).await.ok().map(|p| parse_eq(&p.payload)).unwrap_or_default();

        if let Some(b) = &battery {
            if let Some(alert) = alerts.check(b.percentage) {
                let enabled = app.prefs.lock().low_battery_alerts;
                if enabled {
                    app.alert(alert, name.as_deref(), b.percentage);
                }
            }
        }

        let (name, firmware, mac) = (name.clone(), firmware.clone(), mac.clone());
        publish(app, shared, |s| {
            s.status = "connected";
            s.message = None;
            s.name = name;
            s.firmware = firmware;
            s.mac = mac;
            if let Some(b) = &battery {
                s.battery = Some(b.percentage);
                s.remaining_minutes = b.remaining_minutes;
            }
            s.modes = modes.clone();
            s.settings = settings.map(|m| ModeSettingsView { cnc_level: m.cnc_level, auto_cnc: m.auto_cnc, spatial_audio: m.spatial_audio, anr_wind: m.anr_wind, anc_toggle: m.anc_toggle });
            s.multipoint = mp.map(|f| Multipoint { enabled: f & 1 != 0, supported: f & 2 != 0 });
            s.mode = mode;
            s.shortcut_mode = extras.shortcut_mode;
            s.shortcut_options = extras.shortcut_options.clone();
            s.auto_pause = extras.auto_pause;
            s.captouch_flag = extras.captouch_flag;
            s.eq = eq;
        });
        tokio::select! {
            _ = tokio::time::sleep(POLL) => {}
            Some(cmd) = rx.recv() => {
                eprintln!("[device] command: {cmd:?}");
                let edits_modes = !matches!(cmd, Command::SetMode { .. });
                if let Err(e) = apply(sess, cmd).await {
                    eprintln!("[device] command failed: {e:#}");
                    let msg = format!("Could not apply the change: {e}");
                    publish(app, shared, |s| s.message = Some(msg));
                }
                if edits_modes {
                    let fresh = read_modes(sess).await;
                    if !fresh.is_empty() {
                        modes = fresh;
                    }
                }
                // fall through: re-read the real state right away
            }
        }
        if shared.lock().status != "connected" {
            bail!("state changed unexpectedly");
        }
    }
}

#[derive(Clone, Default)]
struct Extras {
    shortcut_mode: Option<u8>,
    shortcut_options: Vec<u8>,
    auto_pause: Option<bool>,
    captouch_flag: Option<bool>,
}

/// Slow-changing product settings (read-only).
async fn read_extras(sess: &mut Session<BleLink>) -> Extras {
    let buttons = sess.get(fblock::SETTINGS, func::BUTTONS, WAIT).await.ok();
    let shortcut_mode = buttons.as_ref().and_then(|p| bmap::parse_button_config(&p.payload).ok()).map(|b| b.mode);
    let shortcut_options = buttons.as_ref().map(|p| shortcut_modes(&p.payload)).unwrap_or_default();
    let auto_pause = sess.get(fblock::SETTINGS, func::AUTO_PLAY_PAUSE, WAIT).await.ok().and_then(|p| p.payload.first().map(|b| b & 1 == 1));
    let captouch_flag = sess.get(fblock::SETTINGS, func::DISABLE_CAPTOUCH, WAIT).await.ok().and_then(|p| p.payload.first().map(|b| b & 1 == 1));
    Extras { shortcut_mode, shortcut_options, auto_pause, captouch_flag }
}

/// Read every configured mode. Built-in modes are always listed; user slots only once configured.
async fn read_modes(sess: &mut Session<BleLink>) -> Vec<ModeInfo> {
    let Ok(caps) = sess.get(fblock::AUDIO_MODES, func::MODES_CAPABILITIES, WAIT).await else { return Vec::new() };
    let Ok(caps) = bmap::parse_modes_capabilities(&caps.payload) else { return Vec::new() };
    let mut out = Vec::new();
    for i in 0..caps.bose_modes.saturating_add(caps.user_modes) {
        let req = bmap::Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::Get, vec![i]);
        let Ok(p) = sess.request(req, WAIT).await else { continue };
        let Ok(c) = bmap::parse_mode_config(&p.payload) else { continue };
        if i < caps.bose_modes || c.user_configured {
            out.push(ModeInfo {
                index: c.index,
                name: c.name,
                favorite: c.favorite,
                user_configurable: c.user_configurable,
                user_configured: c.user_configured,
                cnc_mutable: c.mutability & 1 != 0,
                spatial_mutable: c.mutability & 4 != 0,
                cnc_level: c.cnc_level,
                spatial_audio: c.spatial_audio.unwrap_or(0),
            });
        }
    }
    out
}

const NEW_MODE_CNC: u8 = 5;
/// Modes the shortcut button accepts: `supportedModes` (bytes 3..7, big-endian bitset) minus `unavailableModes` (bytes 7..11).
pub fn shortcut_modes(p: &[u8]) -> Vec<u8> {
    if p.len() < 7 {
        return Vec::new();
    }
    let sup = u32::from_be_bytes([p[3], p[4], p[5], p[6]]);
    let unavail = if p.len() >= 11 { u32::from_be_bytes([p[7], p[8], p[9], p[10]]) } else { 0 };
    (0u8..32).filter(|b| sup >> b & 1 == 1 && unavail >> b & 1 == 0).collect()
}

/// Settings.RangeControl (the app's equalizer sliders).
const EQ_FN: u8 = 7;

/// Read one mode's raw configuration.
async fn read_mode(sess: &mut Session<BleLink>, index: u8) -> Result<bmap::ModeConfig> {
    let req = bmap::Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::Get, vec![index]);
    let p = sess.request(req, WAIT).await?;
    bmap::parse_mode_config(&p.payload).map_err(|e| anyhow::anyhow!(e))
}

/// Only user slots (`index >= bose_modes`, `user_configurable`) may ever be written; built-in modes are never touched.
async fn user_slot(sess: &mut Session<BleLink>, index: u8) -> Result<bmap::ModeConfig> {
    let caps = sess.get(fblock::AUDIO_MODES, func::MODES_CAPABILITIES, WAIT).await?;
    let caps = bmap::parse_modes_capabilities(&caps.payload).map_err(|e| anyhow::anyhow!(e))?;
    if index < caps.bose_modes || index >= caps.bose_modes.saturating_add(caps.user_modes) {
        bail!("mode {index} is not a custom mode");
    }
    let cfg = read_mode(sess, index).await?;
    if !cfg.user_configurable {
        bail!("mode {index} cannot be customised");
    }
    Ok(cfg)
}

async fn write_mode(sess: &mut Session<BleLink>, cfg: &bmap::ModeConfig, name: &str, cnc_level: u8, spatial_audio: u8) -> Result<()> {
    let w = bmap::ModeWrite {
        index: cfg.index,
        prompt: cfg.prompt,
        name,
        cnc_level,
        auto_cnc: cfg.auto_cnc,
        spatial_audio,
        wind_block: cfg.wind_block == Some(1),
        anc_toggle: cfg.anc_toggle != Some(0),
    };
    let req = bmap::Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::SetGet, bmap::build_mode_config(&w));
    sess.request(req, Duration::from_secs(8)).await?;
    Ok(())
}

async fn apply(sess: &mut Session<BleLink>, cmd: Command) -> Result<()> {
    match cmd {
        Command::CreateMode { prefix } => {
            let caps = sess.get(fblock::AUDIO_MODES, func::MODES_CAPABILITIES, WAIT).await?;
            let caps = bmap::parse_modes_capabilities(&caps.payload).map_err(|e| anyhow::anyhow!(e))?;
            for index in caps.bose_modes..caps.bose_modes.saturating_add(caps.user_modes) {
                let cfg = read_mode(sess, index).await?;
                if cfg.user_configurable && !cfg.user_configured {
                    let name = format!("{} {}", prefix.as_deref().unwrap_or("Custom"), index - caps.bose_modes + 1);
                    return write_mode(sess, &cfg, &name, NEW_MODE_CNC, 0).await;
                }
            }
            bail!("all {} custom modes are already in use", caps.user_modes)
        }
        Command::SaveMode { index, cnc_level, spatial_audio } => {
            let cfg = user_slot(sess, index).await?;
            if !cfg.user_configured {
                bail!("mode {index} has not been created yet");
            }
            let name = cfg.name.clone();
            write_mode(sess, &cfg, &name, cnc_level.min(10), spatial_audio.min(2)).await
        }
        Command::RenameMode { index, name } => {
            let name = name.trim().to_string();
            if name.is_empty() {
                bail!("the name cannot be empty");
            }
            let cfg = user_slot(sess, index).await?;
            if !cfg.user_configured {
                bail!("mode {index} has not been created yet");
            }
            write_mode(sess, &cfg, &name, cfg.cnc_level, cfg.spatial_audio.unwrap_or(0)).await
        }
        Command::SetFavorite { index, on } => {
            let cur = sess.get(fblock::AUDIO_MODES, func::MODES_FAVORITES, WAIT).await?;
            let n = *cur.payload.first().ok_or_else(|| anyhow::anyhow!("empty favourites response"))?;
            let mut favs = bmap::parse_favorites(&cur.payload).map_err(|e| anyhow::anyhow!(e))?;
            favs.retain(|m| *m != index);
            if on {
                favs.push(index);
            }
            let req = bmap::Packet::new(fblock::AUDIO_MODES, func::MODES_FAVORITES, bmap::Operator::SetGet, bmap::build_favorites(n, &favs));
            sess.request(req, Duration::from_secs(8)).await?;
            Ok(())
        }
        Command::ResetMode { index } => {
            user_slot(sess, index).await?;
            let req = bmap::Packet::new(fblock::AUDIO_MODES, func::MODES_RESET, bmap::Operator::Start, vec![index]);
            sess.request(req, Duration::from_secs(10)).await?;
            Ok(())
        }
        Command::Rescan => Ok(()),
        Command::SetShortcut { mode } => {
            let cur = sess.get(fblock::SETTINGS, func::BUTTONS, WAIT).await?;
            let cfg = bmap::parse_button_config(&cur.payload).map_err(|e| anyhow::anyhow!(e))?;
            if !shortcut_modes(&cur.payload).contains(&mode) {
                bail!("the headphones do not accept function {mode} for the shortcut");
            }
            let req = bmap::Packet::new(fblock::SETTINGS, func::BUTTONS, bmap::Operator::SetGet, vec![cfg.button_id, cfg.event_type, mode]);
            sess.request(req, Duration::from_secs(8)).await?;
            Ok(())
        }
        Command::SetEq { band, level } => {
            // Settings.RangeControl SetGet [level (i8), identifier]; the device answers with every band's range/current level.
            let cur = sess.get(fblock::SETTINGS, EQ_FN, WAIT).await?;
            let bands = parse_eq(&cur.payload);
            let b = bands.iter().find(|b| b.id == band).ok_or_else(|| anyhow::anyhow!("the headphones have no band {band}"))?;
            let level = level.clamp(b.min, b.max);
            let req = bmap::Packet::new(fblock::SETTINGS, EQ_FN, bmap::Operator::SetGet, vec![level as u8, band]);
            sess.request(req, Duration::from_secs(8)).await?;
            Ok(())
        }
        Command::SetMode { index } => {
            // AudioModes.CurrentMode Start [modeIndex, persistAsDefault=0]; verified on a QC Ultra 2 HP.
            let req = bmap::Packet::new(fblock::AUDIO_MODES, func::CURRENT_MODE, bmap::Operator::Start, vec![index, 0]);
            sess.request(req, Duration::from_secs(8)).await?;
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcut_options_from_a_real_qc_ultra_2() {
        // Shortcut button 0x80, event 9, currently Vpa; supported 0x00094002, none unavailable.
        assert_eq!(shortcut_modes(&[0x80, 0x09, 0x01, 0x00, 0x09, 0x40, 0x02, 0, 0, 0, 0]), vec![1, 14, 16, 19]);
        assert_eq!(shortcut_modes(&[0x80, 0x09, 0x01, 0x00, 0x09, 0x40, 0x02, 0, 0, 0, 0x02]), vec![14, 16, 19], "unavailable modes are dropped");
    }

    #[test]
    fn eq_payload_from_a_real_qc_ultra_2() {
        let bands = parse_eq(&[0xf6, 0x0a, 0x08, 0x00, 0xf6, 0x0a, 0x00, 0x01, 0xf6, 0x0a, 0x00, 0x02]);
        assert_eq!(bands.len(), 3);
        assert_eq!(bands[0], EqBand { id: 0, min: -10, max: 10, current: 8 });
        assert_eq!(bands[2].id, 2);
    }

    #[test]
    fn alerts_fire_once_per_threshold() {
        let mut a = AlertState::default();
        assert_eq!(a.check(80), None);
        assert_eq!(a.check(21), None);
        assert_eq!(a.check(20), Some(Alert::Low));
        assert_eq!(a.check(19), None, "no repeat while still low");
        assert_eq!(a.check(10), Some(Alert::Critical));
        assert_eq!(a.check(5), None, "no repeat while critical");
    }

    #[test]
    fn jumping_straight_to_critical_skips_the_low_alert() {
        let mut a = AlertState::default();
        assert_eq!(a.check(8), Some(Alert::Critical));
        assert_eq!(a.check(18), None, "low was implied by critical");
    }

    #[test]
    fn hysteresis_prevents_spam_near_the_threshold_and_rearms_after_charging() {
        let mut a = AlertState::default();
        assert_eq!(a.check(20), Some(Alert::Low));
        assert_eq!(a.check(22), None);
        assert_eq!(a.check(19), None, "21..25 does not re-arm");
        assert_eq!(a.check(26), None);
        assert_eq!(a.check(19), Some(Alert::Low), "re-armed after climbing above 25");
    }
}
