//! C ABI used by the Swift app (see `include/bose_core.h`).
//!
//! * `bose_start` spawns the device task; every state change / alert is pushed to the callback as one JSON line.
//! * `bose_command` queues a write for the BLE session (`{"cmd":"set_mode","index":1}`).
//! * `bose_request` answers synchronous queries (prefs, Mac volume) with a JSON string the caller must `bose_free`.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, OnceLock};

use serde_json::{json, Value};

use crate::device::{self, Command, Ctx, Shared};
use crate::prefs::{self, SharedPrefs};
use crate::volume;

type EventCb = extern "C" fn(ctx: *mut c_void, json: *const c_char);

struct Core {
    rt: tokio::runtime::Runtime,
    shared: Shared,
    tx: tokio::sync::mpsc::UnboundedSender<Command>,
    prefs: Arc<SharedPrefs>,
}

static CORE: OnceLock<Core> = OnceLock::new();

/// Start the background task once. `cb` is called from a Rust thread, never re-entrantly with itself for one event.
#[no_mangle]
pub extern "C" fn bose_start(cb: Option<EventCb>, ctx: *mut c_void) {
    let Some(cb) = cb else { return };
    let ctx_addr = ctx as usize;
    CORE.get_or_init(|| {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().thread_name("bose-core").build().expect("tokio runtime");
        let shared = Shared::default();
        let prefs = Arc::new(parking_lot::Mutex::new(prefs::load()));
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let emit: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |line: String| {
            if let Ok(c) = CString::new(line) {
                cb(ctx_addr as *mut c_void, c.as_ptr());
            }
        });
        device::spawn(rt.handle(), Ctx { emit, prefs: prefs.clone() }, shared.clone(), rx);
        Core { rt, shared, tx, prefs }
    });
}

unsafe fn read(json: *const c_char) -> Option<Value> {
    if json.is_null() {
        return None;
    }
    serde_json::from_str(&CStr::from_ptr(json).to_string_lossy()).ok()
}

/// Returns 0 when queued, -1 when the core is not running or the JSON is not a known command.
///
/// # Safety
/// `json` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn bose_command(json: *const c_char) -> i32 {
    let (Some(core), Some(v)) = (CORE.get(), read(json)) else { return -1 };
    match serde_json::from_value::<Command>(v) {
        Ok(cmd) => core.tx.send(cmd).map(|_| 0).unwrap_or(-1),
        Err(e) => {
            eprintln!("[ffi] bad command: {e}");
            -1
        }
    }
}

fn handle(core: &Core, v: &Value) -> Result<Value, String> {
    let _guard = core.rt.enter();
    match v.get("req").and_then(Value::as_str).ok_or("missing 'req'")? {
        "get_prefs" => serde_json::to_value(prefs::get(&core.prefs)).map_err(|e| e.to_string()),
        "set_pref" => {
            let key = v.get("key").and_then(Value::as_str).ok_or("missing 'key'")?;
            let value = v.get("value").and_then(Value::as_bool).ok_or("missing 'value'")?;
            prefs::set(&core.prefs, key, value).map(|_| json!(null))
        }
        "get_volume" => {
            let mac = core.shared.lock().mac.clone();
            serde_json::to_value(mac.map(|m| volume::get(&m)).unwrap_or_default()).map_err(|e| e.to_string())
        }
        "set_volume" => {
            let level = v.get("level").and_then(Value::as_u64).ok_or("missing 'level'")?.min(100) as u8;
            let mac = core.shared.lock().mac.clone().ok_or("Headphones are not connected yet.")?;
            volume::set(&mac, level).map(|_| json!(null))
        }
        other => Err(format!("unknown request: {other}")),
    }
}

/// Synchronous request; returns `{"ok": ...}` or `{"error": "..."}`. Free with `bose_free`.
///
/// # Safety
/// `json` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn bose_request(json: *const c_char) -> *mut c_char {
    let out = match (CORE.get(), read(json)) {
        (Some(core), Some(v)) => match handle(core, &v) {
            Ok(ok) => json!({ "ok": ok }),
            Err(error) => json!({ "error": error }),
        },
        _ => json!({ "error": "core not started" }),
    };
    CString::new(out.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `p` must come from `bose_request` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn bose_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
