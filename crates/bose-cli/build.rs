//! macOS aborts any process that touches CoreBluetooth without an NSBluetoothAlwaysUsageDescription
//! in its Info.plist. A bare CLI has no bundle, so embed the plist in the Mach-O.

fn main() {
    println!("cargo:rerun-if-changed=Info.plist");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let plist = format!("{}/Info.plist", std::env::var("CARGO_MANIFEST_DIR").unwrap());
        println!("cargo:rustc-link-arg-bins=-Wl,-sectcreate,__TEXT,__info_plist,{plist}");
    }
}
