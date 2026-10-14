//! Bose headphones core: BLE/BMAP session, preferences and Mac output volume, exposed to the native
//! SwiftUI app through a small C ABI (`ffi`). No UI code lives here.

pub mod device;
pub mod ffi;
pub mod prefs;
pub mod volume;
