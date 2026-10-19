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
        fn AudioObjectGetPropertyDataSize(object: u32, address: *const Address, qualifier_size: u32, qualifier: *const c_void, size: *mut u32) -> i32;
    }

    const SYSTEM_OBJECT: u32 = 1;
    const GLOBAL: u32 = u32::from_be_bytes(*b"glob");
    const INPUT: u32 = u32::from_be_bytes(*b"inpt");
    const DEFAULT_OUTPUT: u32 = u32::from_be_bytes(*b"dOut");
    const DEVICES: u32 = u32::from_be_bytes(*b"dev#");
    const DEVICE_UID: u32 = u32::from_be_bytes(*b"uid ");
    const STREAMS: u32 = u32::from_be_bytes(*b"stm#");
    const RUNNING_SOMEWHERE: u32 = u32::from_be_bytes(*b"gone");

    fn get_u32(object: u32, selector: u32) -> Option<u32> {
        let mut value: u32 = 0;
        let mut size = std::mem::size_of::<u32>() as u32;
        let addr = Address { selector, scope: GLOBAL, element: 0 };
        // SAFETY: `value` is a valid u32 destination of `size` bytes.
        let err = unsafe { AudioObjectGetPropertyData(object, &addr, 0, std::ptr::null(), &mut size, (&mut value as *mut u32).cast()) };
        (err == 0).then_some(value)
    }

    fn device_uid(device: u32) -> Option<String> {
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

    fn default_output_uid() -> Option<String> {
        get_u32(SYSTEM_OBJECT, DEFAULT_OUTPUT).filter(|&d| d != 0).and_then(device_uid)
    }

    fn devices() -> Vec<u32> {
        let addr = Address { selector: DEVICES, scope: GLOBAL, element: 0 };
        let mut size = 0u32;
        // SAFETY: only writes the property size into `size`.
        if unsafe { AudioObjectGetPropertyDataSize(SYSTEM_OBJECT, &addr, 0, std::ptr::null(), &mut size) } != 0 {
            return Vec::new();
        }
        let mut ids = vec![0u32; size as usize / std::mem::size_of::<u32>()];
        // SAFETY: `ids` holds `size` bytes of u32 slots.
        let err = unsafe { AudioObjectGetPropertyData(SYSTEM_OBJECT, &addr, 0, std::ptr::null(), &mut size, ids.as_mut_ptr().cast()) };
        if err != 0 {
            return Vec::new();
        }
        ids.truncate(size as usize / std::mem::size_of::<u32>());
        ids
    }

    fn has_input_streams(device: u32) -> bool {
        let addr = Address { selector: STREAMS, scope: INPUT, element: 0 };
        let mut size = 0u32;
        // SAFETY: only writes the property size into `size`.
        unsafe { AudioObjectGetPropertyDataSize(device, &addr, 0, std::ptr::null(), &mut size) == 0 && size > 0 }
    }

    /// Some process is recording from the headphones' microphone, i.e. a call (Meet, Teams, FaceTime…)
    /// holds them in the hands-free profile.
    pub fn headset_mic_in_use(mac: &str) -> bool {
        devices().into_iter().any(|d| {
            has_input_streams(d) && device_uid(d).is_some_and(|u| uid_matches(&u, mac)) && get_u32(d, RUNNING_SOMEWHERE).is_some_and(|r| r != 0)
        })
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
    pub fn headset_mic_in_use(_mac: &str) -> bool {
        false
    }
}

pub use imp::{get, headset_mic_in_use, set};

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
