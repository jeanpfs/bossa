//! `bose` — scan for Bose headphones and read their state over BMAP.
//!
//!   bose scan [--secs N]                       list nearby BLE devices (Bose ones first/marked)
//!   bose probe [--id ID | --name TEXT] [--secure] [--secs N]
//!   bose demo                                  run the same report against the in-memory fake

use std::time::Duration;

use anyhow::{bail, Result};
use bose_bmap::{self as bmap, fblock, func, Packet};
use bose_transport::ble::{self, BleLink, Found};
use bose_transport::fake::FakeHeadphones;
use bose_transport::{Link, Session};

const WAIT: Duration = Duration::from_secs(4);

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect::<Vec<_>>().join(" ")
}

fn describe_mfg(f: &Found) -> String {
    f.manufacturer.iter().map(|(c, d)| format!("0x{c:04X}:{}", hex(d))).collect::<Vec<_>>().join(" ")
}

async fn cmd_scan(args: &[String]) -> Result<()> {
    let secs = arg(args, "--secs").and_then(|s| s.parse().ok()).unwrap_or(8);
    eprintln!("scanning {secs} s…");
    let found = ble::scan(secs).await?;
    let bose: Vec<_> = found.iter().filter(|f| f.is_bose()).collect();
    println!("{} devices seen, {} look like Bose", found.len(), bose.len());
    for f in &bose {
        println!(
            "* {}  {:<24} rssi {:>4}  id {}\n    mfg {}\n    services {:?}",
            "BOSE",
            f.display_name(),
            f.rssi.map(|r| r.to_string()).unwrap_or("?".into()),
            f.id,
            describe_mfg(f),
            f.services.iter().map(|u| u.to_string()).collect::<Vec<_>>()
        );
    }
    let named: Vec<_> = found.iter().filter(|f| !f.is_bose() && f.name.is_some()).collect();
    if !named.is_empty() {
        println!("other named devices: {}", named.iter().map(|f| f.display_name().to_string()).collect::<Vec<_>>().join(", "));
    }
    if bose.is_empty() {
        println!("No Bose device advertising. Turn the headphones on; if they are connected to a phone, disconnect or enable pairing.");
    }
    Ok(())
}

/// Print every field we can read. Each request is independent: one failure doesn't stop the rest.
async fn report<L: Link>(s: &mut Session<L>) {
    macro_rules! show {
        ($label:expr, $fb:expr, $f:expr, |$p:ident| $body:expr) => {{
            match s.get($fb, $f, WAIT).await {
                Ok(pkt) => {
                    let $p = &pkt.payload;
                    match (|| -> Result<String, bmap::BmapError> { Ok($body) })() {
                        Ok(text) => println!("{:<18} {}", $label, text),
                        Err(e) => println!("{:<18} unparseable ({e}); raw {}", $label, hex(&pkt.payload)),
                    }
                }
                Err(e) => println!("{:<18} {e}", $label),
            }
        }};
    }
    show!("BMAP version", fblock::PRODUCT_INFO, func::BMAP_VERSION, |p| bmap::utf8(p));
    show!("Product", fblock::PRODUCT_INFO, func::PRODUCT_ID_VARIANTS, |p| {
        let (id, variant) = bmap::parse_product_id(p)?;
        format!("0x{id:04X} variant {variant} ({})", bmap::product_name(id).unwrap_or("unknown"))
    });
    show!("Function blocks", fblock::PRODUCT_INFO, func::ALL_FBLOCKS, |p| format!("{:?}", bmap::parse_fblocks(p)));
    show!("Firmware", fblock::PRODUCT_INFO, func::FIRMWARE_VERSION, |p| bmap::utf8(p));
    show!("Classic MAC", fblock::PRODUCT_INFO, func::MAC_ADDRESS, |p| bmap::format_mac(p));
    show!("Name", fblock::SETTINGS, func::PRODUCT_NAME, |p| {
        let (default, name) = bmap::parse_product_name(p)?;
        format!("{name}{}", if default { " (default)" } else { "" })
    });
    show!("Battery", fblock::STATUS, func::BATTERY_LEVEL, |p| {
        bmap::parse_battery(p)?
            .iter()
            .map(|b| {
                let t = b.remaining_minutes.map(|m| format!(", ~{}h{:02}m left", m / 60, m % 60)).unwrap_or_default();
                format!("{}%{t}{}", b.percentage, b.component.map(|c| format!(" (component {c})")).unwrap_or_default())
            })
            .collect::<Vec<_>>()
            .join("; ")
    });
    show!("Volume", fblock::AUDIO_MANAGEMENT, func::VOLUME, |p| {
        let (cur, max) = bmap::parse_volume(p)?;
        format!("{cur}/{max}")
    });
    show!("Noise cancelling", fblock::SETTINGS, func::CNC, |p| {
        let c = bmap::parse_cnc(p)?;
        format!("step {}/{} {}", c.current_step, c.num_steps, if c.enabled { "enabled" } else { "disabled" })
    });
    show!("Multipoint", fblock::SETTINGS, func::MULTIPOINT, |p| {
        let f = *p.first().ok_or(bmap::BmapError::BadPayload { what: "multipoint", len: 0 })?;
        format!("enabled={} supported={}", f & 1 != 0, f & 2 != 0)
    });
    show!("Audio mode", fblock::AUDIO_MODES, func::CURRENT_MODE, |p| format!("index {}", p.first().copied().unwrap_or(0)));
    if !s.unsolicited.is_empty() {
        println!("-- unsolicited packets seen: {}", s.unsolicited.len());
        for p in &s.unsolicited {
            println!("   fblock {} fn {} {:?} {}", p.fblock, p.function, p.operator, hex(&p.payload));
        }
    }
    let _ = Packet::get(0, 0); // keep the import used if the macro changes
}

/// Scan, pick a device and open a BMAP session (secure characteristic unless `--unsecure`).
async fn open_session(args: &[String]) -> Result<Session<BleLink>> {
    let secs = arg(args, "--secs").and_then(|s| s.parse().ok()).unwrap_or(8);
    let secure = !args.iter().any(|a| a == "--unsecure");
    let (want_id, want_name) = (arg(args, "--id"), arg(args, "--name"));
    eprintln!("scanning {secs} s…");
    let found = ble::scan(secs).await?;
    let pick = found
        .iter()
        .find(|f| match (&want_id, &want_name) {
            (Some(id), _) => &f.id == id,
            (None, Some(n)) => f.name.as_deref().is_some_and(|x| x.to_lowercase().contains(&n.to_lowercase())),
            _ => f.is_bose(),
        })
        .ok_or_else(|| anyhow::anyhow!("no matching device found ({} seen). Run `bose scan` first.", found.len()))?;
    println!("device: {} ({})  rssi {:?}", pick.display_name(), pick.id, pick.rssi);
    println!("  mfg: {}", describe_mfg(pick));
    let link = BleLink::connect(pick, secure).await?;
    println!(
        "  characteristic: {} ({}) props {:?}",
        link.characteristic_uuid(),
        if link.uses_secure_characteristic { "secure" } else { "unsecure" },
        link.characteristic_properties()
    );
    let mut s = Session::new(link);
    // The app's first request is BmapVersion with a 2 s timeout, retried once with a long timeout.
    if s.get(fblock::PRODUCT_INFO, func::BMAP_VERSION, Duration::from_secs(2)).await.is_err() {
        eprintln!("no answer in 2 s, retrying (up to 50 s)…");
        if let Err(e) = s.get(fblock::PRODUCT_INFO, func::BMAP_VERSION, Duration::from_secs(50)).await {
            bail!("device never answered BMAP version: {e}");
        }
    }
    Ok(s)
}

async fn cmd_probe(args: &[String]) -> Result<()> {
    let mut s = open_session(args).await?;
    report(&mut s).await;
    Ok(())
}

async fn current_mode<L: Link>(s: &mut Session<L>) -> Result<u8> {
    let p = s.get(fblock::AUDIO_MODES, func::CURRENT_MODE, WAIT).await?;
    p.payload.first().copied().ok_or_else(|| anyhow::anyhow!("empty mode payload"))
}

/// Change the active audio mode, read it back, and optionally put the original mode back.
async fn cmd_set_mode(args: &[String]) -> Result<()> {
    let idx: u8 = args.first().and_then(|s| s.parse().ok()).ok_or_else(|| anyhow::anyhow!("usage: bose set-mode <index> [--revert]"))?;
    let mut s = open_session(&args[1..]).await?;
    let before = current_mode(&mut s).await?;
    println!("current mode: {before}");
    let revert = args.iter().any(|a| a == "--revert");
    let steps: Vec<(&str, u8)> = if revert { vec![("set", idx), ("revert", before)] } else { vec![("set", idx)] };
    for (label, target) in steps {
        let req = Packet::new(fblock::AUDIO_MODES, func::CURRENT_MODE, bmap::Operator::Start, vec![target, 0]);
        match s.request(req, Duration::from_secs(8)).await {
            Ok(r) => println!("{label} -> {target}: {:?} {}", r.operator, hex(&r.payload)),
            Err(e) => println!("{label} -> {target}: {e}"),
        }
        tokio::time::sleep(Duration::from_millis(1200)).await;
        println!("   now reads: {}", current_mode(&mut s).await.map(|m| m.to_string()).unwrap_or_else(|e| format!("error {e}")));
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    Ok(())
}

async fn read_cnc<L: Link>(s: &mut Session<L>) -> Result<bmap::Cnc> {
    let p = s.get(fblock::SETTINGS, func::CNC, WAIT).await?;
    bmap::parse_cnc(&p.payload).map_err(|e| anyhow::anyhow!(e))
}

/// Set the noise-cancelling step (SetGet [step, enabled]), read it back, optionally restore.
async fn cmd_set_cnc(args: &[String]) -> Result<()> {
    let step: u8 = args.first().and_then(|s| s.parse().ok()).ok_or_else(|| anyhow::anyhow!("usage: bose set-cnc <step> [--revert]"))?;
    let mut s = open_session(&args[1..]).await?;
    let before = read_cnc(&mut s).await?;
    println!("current: step {}/{} enabled={}", before.current_step, before.num_steps, before.enabled);
    let revert = args.iter().any(|a| a == "--revert");
    let steps: Vec<(&str, u8, bool)> = if revert { vec![("set", step, true), ("revert", before.current_step, before.enabled)] } else { vec![("set", step, true)] };
    for (label, st, en) in steps {
        let req = Packet::new(fblock::SETTINGS, func::CNC, bmap::Operator::SetGet, vec![st, en as u8]);
        match s.request(req, Duration::from_secs(6)).await {
            Ok(r) => println!("{label} -> step {st}: {:?} {}", r.operator, hex(&r.payload)),
            Err(e) => println!("{label} -> step {st}: {e}"),
        }
        tokio::time::sleep(Duration::from_millis(1200)).await;
        match read_cnc(&mut s).await {
            Ok(c) => println!("   now reads: step {}/{} enabled={}", c.current_step, c.num_steps, c.enabled),
            Err(e) => println!("   now reads: error {e}"),
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    Ok(())
}

/// Read-only dump of the audio-mode configuration (nothing is written).
async fn cmd_modes(args: &[String]) -> Result<()> {
    let mut s = open_session(args).await?;
    match s.get(fblock::AUDIO_MODES, func::MODES_CAPABILITIES, WAIT).await {
        Ok(p) => println!("capabilities     {:?}  raw {}", bmap::parse_modes_capabilities(&p.payload), hex(&p.payload)),
        Err(e) => println!("capabilities     {e}"),
    }
    match s.get(fblock::AUDIO_MODES, func::CURRENT_MODE, WAIT).await {
        Ok(p) => println!("current mode     {}", hex(&p.payload)),
        Err(e) => println!("current mode     {e}"),
    }
    match s.get(fblock::AUDIO_MODES, func::MODES_DEFAULT, WAIT).await {
        Ok(p) => println!("default mode     {}", hex(&p.payload)),
        Err(e) => println!("default mode     {e}"),
    }
    match s.get(fblock::AUDIO_MODES, func::MODES_SETTINGS_CONFIG, WAIT).await {
        Ok(p) => println!("current settings {:?}  raw {}", bmap::parse_mode_settings(&p.payload), hex(&p.payload)),
        Err(e) => println!("current settings {e}"),
    }
    for i in 0..6u8 {
        let req = Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::Get, vec![i]);
        match s.request(req, WAIT).await {
            Ok(p) => println!("mode {i}: {:?}\n        raw {}", bmap::parse_mode_config(&p.payload), hex(&p.payload)),
            Err(e) => println!("mode {i}: {e}"),
        }
    }
    Ok(())
}

async fn read_mode(s: &mut Session<impl Link>, i: u8) -> Result<bmap::ModeConfig> {
    let req = Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::Get, vec![i]);
    let p = s.request(req, WAIT).await?;
    bmap::parse_mode_config(&p.payload).map_err(|e| anyhow::anyhow!(e))
}

/// Reversible write test on one EMPTY user slot: create -> edit noise level -> reset. Built-in modes are never touched.
async fn cmd_mode_lab(args: &[String]) -> Result<()> {
    let slot: u8 = args.first().and_then(|s| s.parse().ok()).ok_or_else(|| anyhow::anyhow!("usage: bose mode-lab <slot>"))?;
    let mut s = open_session(&args[1..]).await?;
    let caps = bmap::parse_modes_capabilities(&s.get(fblock::AUDIO_MODES, func::MODES_CAPABILITIES, WAIT).await?.payload).map_err(|e| anyhow::anyhow!(e))?;
    if slot < caps.bose_modes || slot >= caps.bose_modes + caps.user_modes {
        anyhow::bail!("slot {slot} is not a user slot (user slots are {}..{})", caps.bose_modes, caps.bose_modes + caps.user_modes);
    }
    let before = read_mode(&mut s, slot).await?;
    println!("before: {before:?}");
    if !before.user_configurable || before.user_configured {
        anyhow::bail!("slot {slot} is not an empty user slot; refusing to overwrite it");
    }
    let write = |cnc: u8| bmap::ModeWrite { index: slot, prompt: (0, 0), name: "Teste", cnc_level: cnc, auto_cnc: false, spatial_audio: 0, wind_block: false, anc_toggle: true };
    let mut result: Result<()> = Ok(());
    for (label, cnc) in [("create", 5u8), ("edit", 8u8)] {
        let req = Packet::new(fblock::AUDIO_MODES, func::MODE_CONFIG, bmap::Operator::SetGet, bmap::build_mode_config(&write(cnc)));
        match s.request(req, Duration::from_secs(8)).await {
            Ok(r) => println!("{label} cnc={cnc}: {:?} {}", r.operator, hex(&r.payload)),
            Err(e) => {
                println!("{label} cnc={cnc}: {e}");
                result = Err(e);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(800)).await;
        match read_mode(&mut s, slot).await {
            Ok(m) => println!("   reads: name={:?} cnc={} configured={} fav={} mutability={:#07b}", m.name, m.cnc_level, m.user_configured, m.favorite, m.mutability),
            Err(e) => println!("   read error: {e}"),
        }
    }
    // Always clean up.
    let req = Packet::new(fblock::AUDIO_MODES, func::MODES_RESET, bmap::Operator::Start, vec![slot]);
    match s.request(req, Duration::from_secs(10)).await {
        Ok(r) => println!("reset: {:?} {}", r.operator, hex(&r.payload)),
        Err(e) => println!("reset: {e}"),
    }
    tokio::time::sleep(Duration::from_millis(1200)).await;
    let after = read_mode(&mut s, slot).await?;
    println!("after:  {after:?}");
    println!("restored to empty: {}", !after.user_configured);
    result
}

/// Reversible favourites test: toggle one built-in mode's star, read it back, restore.
async fn cmd_fav_lab(args: &[String]) -> Result<()> {
    let idx: u8 = args.first().and_then(|s| s.parse().ok()).ok_or_else(|| anyhow::anyhow!("usage: bose fav-lab <modeIndex>"))?;
    let mut s = open_session(&args[1..]).await?;
    let raw = s.get(fblock::AUDIO_MODES, func::MODES_FAVORITES, WAIT).await?;
    let n = raw.payload[0];
    let favs = bmap::parse_favorites(&raw.payload).map_err(|e| anyhow::anyhow!(e))?;
    println!("favorites raw {}  -> n={n} favs={favs:?}", hex(&raw.payload));
    let mut toggled = favs.clone();
    if toggled.contains(&idx) { toggled.retain(|m| *m != idx) } else { toggled.push(idx) }
    let mut result: Result<()> = Ok(());
    for (label, list) in [("toggle", toggled), ("restore", favs.clone())] {
        let req = Packet::new(fblock::AUDIO_MODES, func::MODES_FAVORITES, bmap::Operator::SetGet, bmap::build_favorites(n, &list));
        match s.request(req, Duration::from_secs(8)).await {
            Ok(r) => println!("{label}: {:?} {} -> {:?}", r.operator, hex(&r.payload), bmap::parse_favorites(&r.payload)),
            Err(e) => { println!("{label}: {e}"); if label == "toggle" { result = Err(e); } }
        }
        tokio::time::sleep(Duration::from_millis(800)).await;
        println!("   mode {idx} favorite flag: {:?}", read_mode(&mut s, idx).await.map(|m| m.favorite));
    }
    result
}

/// Read-only dump of the Settings fblock functions behind shortcut / touch / head detection / prompts.
async fn cmd_settings(args: &[String]) -> Result<()> {
    let mut s = open_session(args).await?;
    for (name, f) in [("voice prompts", 3u8), ("buttons", 9), ("on-head detection", 16), ("auto play/pause", 24), ("disable captouch", 34)] {
        match s.get(fblock::SETTINGS, f, WAIT).await {
            Ok(p) => println!("{name:<18} fn {f:<2} {:?} {}", p.operator, hex(&p.payload)),
            Err(e) => println!("{name:<18} fn {f:<2} {e}"),
        }
    }
    Ok(())
}

/// Read-only: issue BMAP Get for `peek --secure <fblock> <fn> [<fblock> <fn> ...]` (decimal ids).
async fn cmd_peek(args: &[String]) -> Result<()> {
    let ids: Vec<u8> = args.iter().filter_map(|a| a.parse().ok()).collect();
    let mut s = open_session(args).await?;
    for pair in ids.chunks(2).filter(|c| c.len() == 2) {
        match s.get(pair[0], pair[1], WAIT).await {
            Ok(p) => println!("fblock {} fn {:<2} {:?} {}", pair[0], pair[1], p.operator, hex(&p.payload)),
            Err(e) => println!("fblock {} fn {:<2} {e}", pair[0], pair[1]),
        }
    }
    Ok(())
}

/// Read-only: Get Settings.Buttons (fn 9) for every known button id x event type, decode supported modes.
async fn cmd_buttons(args: &[String]) -> Result<()> {
    let mut s = open_session(args).await?;
    for id in [0u8, 2, 3, 4, 128] {
        for ev in 0u8..=15 {
            let req = bmap::Packet::new(fblock::SETTINGS, 9, bmap::Operator::Get, vec![id, ev]);
            match s.request(req, Duration::from_secs(2)).await {
                Ok(p) if p.payload.len() >= 7 => {
                    let sup = u32::from_be_bytes([p.payload[3], p.payload[4], p.payload[5], p.payload[6]]);
                    let modes: Vec<u32> = (0..32).filter(|b| sup >> b & 1 == 1).collect();
                    println!("button {id:<3} event {ev:<2} configured {} supported {modes:?} raw {}", p.payload.get(2).copied().unwrap_or(255), hex(&p.payload));
                }
                Ok(p) => println!("button {id:<3} event {ev:<2} short {}", hex(&p.payload)),
                Err(e) => println!("button {id:<3} event {ev:<2} {e}"),
            }
        }
    }
    Ok(())
}

/// Read-only: print every packet the headphones send for N seconds (press buttons meanwhile).
async fn cmd_listen(args: &[String]) -> Result<()> {
    let secs: u64 = arg(args, "--listen-secs").and_then(|s| s.parse().ok()).unwrap_or(30);
    let mut s = open_session(args).await?;
    println!("listening {secs}s — press buttons / touch now");
    let end = tokio::time::Instant::now() + Duration::from_secs(secs);
    while let Some(left) = end.checked_duration_since(tokio::time::Instant::now()) {
        match tokio::time::timeout(left, s.link().recv()).await {
            Ok(Ok(raw)) => match bmap::Packet::decode_all(&raw) {
                Ok(ps) => for p in ps { println!("fblock {} fn {} {:?} {}", p.fblock, p.function, p.operator, hex(&p.payload)); },
                Err(_) => println!("raw {}", hex(&raw)),
            },
            _ => break,
        }
    }
    Ok(())
}

async fn cmd_demo() -> Result<()> {
    let mut s = Session::new(FakeHeadphones::new());
    println!("(fake device, no Bluetooth)");
    report(&mut s).await;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("scan") => cmd_scan(&args[1..]).await,
        Some("probe") => cmd_probe(&args[1..]).await,
        Some("set-mode") => cmd_set_mode(&args[1..]).await,
        Some("set-cnc") => cmd_set_cnc(&args[1..]).await,
        Some("modes") => cmd_modes(&args[1..]).await,
        Some("mode-lab") => cmd_mode_lab(&args[1..]).await,
        Some("fav-lab") => cmd_fav_lab(&args[1..]).await,
        Some("settings") => cmd_settings(&args[1..]).await,
        Some("buttons") => cmd_buttons(&args[1..]).await,
        Some("listen") => cmd_listen(&args[1..]).await,
        Some("peek") => cmd_peek(&args[1..]).await,
        Some("demo") => cmd_demo().await,
        _ => {
            eprintln!("usage: bose scan [--secs N] | probe [opts] | set-mode <index> [--revert] | set-cnc <step> [--revert] | demo\n  opts: [--id ID | --name TEXT] [--unsecure] [--secs N]");
            std::process::exit(2)
        }
    }
}
