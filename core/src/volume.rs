//! Listening volume.
//!
//! The headphones do not expose their volume over BMAP (`AudioManagement.Volume` answers `InvalidData` on a
//! QC Ultra 2 HP): Bluetooth volume is owned by the host. So this controls the Mac's output volume, and only
//! while the headphones are the Mac's default output device (matched by their Bluetooth address in the
//! CoreAudio device UID).

use serde::Serialize;

#[derive(Serialize, Debug, Default)]
pub struct VolumeInfo {
    /// The headphones are the current output device and their volume can be controlled.
    pub available: bool,
    /// 0..=100
    pub level: Option<u8>,
}

/// `68:F2:1F:0C:70:59` -> `68-F2-1F-0C-70-59`, the spelling CoreAudio uses in Bluetooth device UIDs.
pub fn uid_form(mac: &str) -> String {
    mac.replace(':', "-").to_uppercase()
}

fn uid_matches(uid: &str, mac: &str) -> bool {
    !mac.is_empty() && uid.to_uppercase().contains(&uid_form(mac))
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use core_foundation::base::TCFType;
    use core_foundation::string::{CFString, CFStringRef};
    use std::ffi::c_void;
    use std::process::Command;

    #[repr(C)]
    struct Address {
        selector: u32,
        scope: u32,
        element: u32,
    }

    #[link(name = "CoreAudio", kind = "framework")]
    extern "C" {
        fn AudioObjectGetPropertyData(object: u32, address: *const Address, qualifier_size: u32, qualifier: *const c_void, size: *mut u32, data: *mut c_void) -> i32;
    }

    const SYSTEM_OBJECT: u32 = 1;
    const GLOBAL: u32 = u32::from_be_bytes(*b"glob");
    const DEFAULT_OUTPUT: u32 = u32::from_be_bytes(*b"dOut");
    const DEVICE_UID: u32 = u32::from_be_bytes(*b"uid ");

    fn default_output_uid() -> Option<String> {
        let mut device: u32 = 0;
        let mut size = std::mem::size_of::<u32>() as u32;
        let addr = Address { selector: DEFAULT_OUTPUT, scope: GLOBAL, element: 0 };
        // SAFETY: `device` is a valid u32 destination of `size` bytes.
        let err = unsafe { AudioObjectGetPropertyData(SYSTEM_OBJECT, &addr, 0, std::ptr::null(), &mut size, (&mut device as *mut u32).cast()) };
        if err != 0 || device == 0 {
            return None;
        }
        let mut uid: CFStringRef = std::ptr::null();
        let mut size = std::mem::size_of::<CFStringRef>() as u32;
        let addr = Address { selector: DEVICE_UID, scope: GLOBAL, element: 0 };
        // SAFETY: the property returns a retained CFString (create rule) into `uid`.
        let err = unsafe { AudioObjectGetPropertyData(device, &addr, 0, std::ptr::null(), &mut size, (&mut uid as *mut CFStringRef).cast()) };
        if err != 0 || uid.is_null() {
            return None;
        }
        // SAFETY: non-null, owned (+1) reference returned by CoreAudio.
        Some(unsafe { CFString::wrap_under_create_rule(uid) }.to_string())
    }

    fn osascript(script: &str) -> Option<String> {
        let out = Command::new("/usr/bin/osascript").args(["-e", script]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    pub fn get(mac: &str) -> VolumeInfo {
        if !default_output_uid().is_some_and(|u| uid_matches(&u, mac)) {
            return VolumeInfo::default();
        }
        match osascript("output volume of (get volume settings)").and_then(|s| s.parse::<u8>().ok()) {
            Some(level) => VolumeInfo { available: true, level: Some(level.min(100)) },
            None => VolumeInfo::default(),
        }
    }

    pub fn set(mac: &str, level: u8) -> Result<(), String> {
        if !default_output_uid().is_some_and(|u| uid_matches(&u, mac)) {
            return Err("The headphones are not the Mac's audio output.".into());
        }
        osascript(&format!("set volume output volume {}", level.min(100))).map(|_| ()).ok_or_else(|| "Could not change the volume.".to_string())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::*;
    pub fn get(_mac: &str) -> VolumeInfo {
        VolumeInfo::default()
    }
    pub fn set(_mac: &str, _level: u8) -> Result<(), String> {
        Err("Volume is not available on this platform yet.".into())
    }
}

pub use imp::{get, set};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_bluetooth_uid_by_address() {
        assert_eq!(uid_form("68:f2:1f:0c:70:59"), "68-F2-1F-0C-70-59");
        assert!(uid_matches("68-F2-1F-0C-70-59:output", "68:F2:1F:0C:70:59"));
        assert!(uid_matches("68-f2-1f-0c-70-59:output", "68:F2:1F:0C:70:59"));
        assert!(!uid_matches("BuiltInSpeakerDevice", "68:F2:1F:0C:70:59"));
        assert!(!uid_matches("anything", ""), "unknown address never matches");
    }
}
