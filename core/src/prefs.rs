//! User preferences (JSON in `~/Library/Application Support/dev.jeanpfs.bossa`) and "open at login".

use std::path::PathBuf;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

pub const IDENTIFIER: &str = "dev.jeanpfs.bossa";
/// Identifier of the app before it was renamed; its preferences are copied over once.
const LEGACY_IDENTIFIER: &str = "dev.local.bosetray";

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
#[serde(default)]
pub struct Prefs {
    pub low_battery_alerts: bool,
}

impl Default for Prefs {
    fn default() -> Self {
        Self { low_battery_alerts: true }
    }
}

pub type SharedPrefs = Mutex<Prefs>;

fn file_for(id: &str) -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support").join(id).join("prefs.json"))
}

fn file() -> Option<PathBuf> {
    file_for(IDENTIFIER)
}

pub fn load() -> Prefs {
    // One-time migration from the pre-rename app.
    if let (Some(new), Some(old)) = (file(), file_for(LEGACY_IDENTIFIER)) {
        if !new.exists() && old.exists() {
            if let Some(dir) = new.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::copy(old, &new);
        }
    }
    file().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

fn save(prefs: &Prefs) -> Result<(), String> {
    let path = file().ok_or("no configuration folder")?;
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(path, serde_json::to_string_pretty(prefs).unwrap()).map_err(|e| e.to_string())
}

#[derive(Serialize)]
pub struct PrefsView {
    pub autostart: bool,
    pub autostart_supported: bool,
    pub low_battery_alerts: bool,
}

pub fn get(prefs: &SharedPrefs) -> PrefsView {
    PrefsView { autostart: autostart::is_enabled(), autostart_supported: autostart::supported(), low_battery_alerts: prefs.lock().low_battery_alerts }
}

pub fn set(prefs: &SharedPrefs, key: &str, value: bool) -> Result<(), String> {
    match key {
        "autostart" => autostart::set(value),
        "low_battery_alerts" => {
            let mut p = prefs.lock();
            p.low_battery_alerts = value;
            save(&p)
        }
        other => Err(format!("unknown preference: {other}")),
    }
}

/// Open at login via a per-user LaunchAgent that `open`s the app bundle (so macOS attributes
/// Bluetooth permission to the app itself, like a normal double-click launch).
#[cfg(target_os = "macos")]
pub mod autostart {
    use std::path::PathBuf;

    const LABEL: &str = "dev.jeanpfs.bossa";

    fn plist_path() -> Option<PathBuf> {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/LaunchAgents").join(format!("{LABEL}.plist")))
    }

    fn bundle_path() -> Option<PathBuf> {
        std::env::current_exe().ok()?.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(|p| p.to_path_buf())
    }

    pub fn supported() -> bool {
        bundle_path().is_some()
    }

    pub fn is_enabled() -> bool {
        plist_path().is_some_and(|p| p.exists())
    }

    pub fn render_plist(bundle: &str) -> String {
        let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LABEL}</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>{}</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
"#,
            esc(bundle)
        )
    }

    pub fn set(enable: bool) -> Result<(), String> {
        let path = plist_path().ok_or("HOME is not set")?;
        if !enable {
            return match std::fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.to_string()),
            };
        }
        let bundle = bundle_path().ok_or("Only works in the installed app, not in a development run.")?;
        std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&path, render_plist(&bundle.to_string_lossy())).map_err(|e| e.to_string())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn plist_escapes_and_runs_open_on_the_bundle() {
            let p = render_plist("/Users/a&b/Apps/Bossa.app");
            assert!(p.contains("<string>/Users/a&amp;b/Apps/Bossa.app</string>"));
            assert!(p.contains("<string>/usr/bin/open</string>"));
            assert!(p.contains("<key>RunAtLoad</key><true/>"));
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub mod autostart {
    pub fn supported() -> bool {
        false
    }
    pub fn is_enabled() -> bool {
        false
    }
    pub fn set(_enable: bool) -> Result<(), String> {
        Err("Launch at login is not available on this platform yet.".into())
    }
}
