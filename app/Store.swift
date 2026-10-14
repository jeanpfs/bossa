import AppKit
import Observation
import SwiftUI
import UserNotifications

enum Screen: Hashable { case home, modes, bluetooth, settings, eq, shortcut }
enum SheetKind: Hashable { case noise, immersive }

struct ToastMessage: Equatable {
    var text: String
    var spin = false
    var action: String?
}

let immLabels = ["Off", "Still", "Motion"]
let immKeys = ["off", "still", "motion"]
let immStatus = [
    "Immersive audio is off.",
    "Sound stays fixed in front of you, even if you turn your head.",
    "Sound follows you as you move.",
]
let modeIcons = ["moon", "ear", "imm", "film"]
let shortcutNames: [Int: String] = [0: "Not set", 1: "Voice assistant", 2: "Noise cancelling", 3: "Battery level", 4: "Play/pause", 5: "More cancelling", 6: "Less cancelling", 8: "Switch source device", 9: "Conversation mode", 10: "Next track", 11: "Previous track", 13: "Wind mode", 14: "Off", 16: "Spotify Go", 17: "Cycle through favorite modes", 19: "Immersive audio"]

/// A mode as the UI shows it (noise scale 0 = awareness ... 10 = full cancelling, like the ruler).
struct ModeView: Identifiable, Equatable {
    var index: Int
    var name: String
    var icon: String
    var favorite: Bool
    var nc: Int
    var imm: Int
    var cncMutable: Bool
    var immMutable: Bool
    var user: Bool
    var id: Int { index }
}

func shortcutName(_ mode: Int) -> String { shortcutNames[mode].map { L($0) } ?? L("Function %d", mode) }

func ncLabel(_ v: Int) -> String { v == 10 ? L("Noise cancelling") : v == 0 ? L("Full awareness") : L("Level %d", v) }

func ncHelp(_ nc: Int) -> String {
    if nc == 10 { return "This level blocks most outside sound." }
    if nc == 0 { return "This level lets surrounding sound in, as if you weren't wearing headphones." }
    return nc >= 5 ? "This level cuts a lot of noise and still lets nearby voices through." : "This level lets a good part of your surroundings through."
}

@MainActor @Observable
final class Store {
    static let shared = Store()

    // Device (read from the headphones)
    var device = DeviceState()
    // Mac output volume while the headphones are the output; nil = unavailable
    var volume: Int?
    var prefs: PrefsView?

    // Navigation
    var screen: Screen = .home
    private(set) var stack: [Screen] = []
    var forward = true
    var sheet: SheetKind?
    var toast: ToastMessage?
    var renaming = false
    var deleteArmed = false
    var panelShownTick = 0
    var panelVisible = false
    /// The panel is shorter on the "not connected" home (no tiles to fit), so there is no dead space.
    private(set) var panelHeight: CGFloat = 576
    var onHeightChange: ((CGFloat) -> Void)?

    func updateHeight() {
        var h: CGFloat = 576
        if !connected && screen == .home {
            // "Last known" card is a single row; "How to pair" is a paragraph.
            h = (lastKnown != nil && linkState(now: Date()) != .pairing) ? 464 : 476
        }
        guard h != panelHeight else { return }
        panelHeight = h
        onHeightChange?(h)
    }
    var language: AppLanguage = .saved
    var lastKnown: LastKnown? = LastKnown.load()
    private var offlineSince = Date()
    var onLanguageChange: (() -> Void)?
    private var edits = 0

    // Edits kept visible until the headphones confirm them
    private var holdUntil = Date.distantPast
    private var held: (index: Int, nc: Int, imm: Int)?
    private var volHold = Date.distantPast
    private var toastTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var volTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?
    private var toastAction: (() -> Void)?
    var onStateChange: ((DeviceState) -> Void)?
    var onHidePanel: (() -> Void)?

    // MARK: Derived

    /// Screenshot aid (TRAY_OFFLINE=searching|notfound|btoff|pairing): pretend the headphones are not connected.
    var debugLink: LinkState?
    var connected: Bool { device.connected && debugLink == nil }
    var deviceName: String { device.name ?? "Bose QC Ultra 2 HP" }

    var modes: [ModeView] {
        _ = edits
        return device.modes.map { m in
            var nc = max(0, min(10, 10 - m.cncLevel))
            var imm = max(0, min(2, m.spatialAudio))
            if Date() < holdUntil, let h = held, h.index == m.index { nc = h.nc; imm = h.imm }
            return ModeView(index: m.index, name: L(m.name), icon: m.index < modeIcons.count ? modeIcons[m.index] : "sliders",
                            favorite: m.favorite, nc: nc, imm: imm, cncMutable: m.cncMutable, immMutable: m.spatialMutable, user: m.userConfigured)
        }
    }

    var currentMode: ModeView? {
        guard let i = device.mode else { return nil }
        var m = modes.first { $0.index == i }
        // The working settings of the current mode are fresher than the cached mode list.
        if var mm = m, let s = device.settings, Date() >= holdUntil {
            mm.nc = max(0, min(10, 10 - s.cncLevel)); mm.imm = max(0, min(2, s.spatialAudio)); m = mm
        }
        return m
    }

    // MARK: Core events

    func setLanguage(_ l: AppLanguage) {
        guard l != language else { return }
        applyLanguage(l)
        language = l
        toast = nil
        onLanguageChange?()
    }

    func start() {
        applyLanguage(language)
        Core.start { line in
            DispatchQueue.main.async { Store.shared.handle(line) }
        }
        loadPrefs()
    }

    private func handle(_ line: String) {
        switch CoreEvent.parse(line) {
        case .state(let d): apply(d)
        case .alert(let kind, let name, let level): postBatteryAlert(kind: kind, name: name, level: level)
        case nil: break
        }
    }

    /// Which "not connected" story to tell: derived from the core's status, how long we have been looking, and its last message.
    func linkState(now: Date) -> LinkState {
        if let d = debugLink { return d }
        if let m = device.message {
            if m.hasPrefix("To pair this computer") { return .pairing }
            if m.hasPrefix("Bluetooth is unavailable") { return .bluetoothOff }
        }
        if device.status == "connecting" { return .searching }
        return now.timeIntervalSince(offlineSince) > 9 ? .notFound : .searching
    }

    func rescan() {
        offlineSince = Date()
        Core.command(["cmd": "rescan"])
    }

    func openBluetoothSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(u) }
    }

    private func remember(_ d: DeviceState) {
        guard d.connected, let b = d.battery else { return }
        let name = d.mode.flatMap { i in d.modes.first { $0.index == i }?.name }
        let k = LastKnown(battery: b, mode: name, seenAt: Date())
        lastKnown = k
        k.save()
    }

    private func apply(_ d: DeviceState) {
        let was = device.connected
        if was && !d.connected { offlineSince = Date() }
        device = d
        remember(d)
        updateHeight()
        onStateChange?(d)
        if was && !d.connected { showToast("The connection to the product was lost.", spin: true, timeout: 0) }
        else if !was && d.connected { hideToast() }
        else if let m = d.message { showToast(localizeCoreMessage(m), timeout: d.connected ? 3.5 : 0) }
        if !d.connected { volume = nil }
    }

    // MARK: Navigation

    func go(_ s: Screen) {
        guard s != screen else { return }
        sheet = nil
        stack.append(screen)
        forward = true
        withAnimation(.smooth(duration: 0.3)) { screen = s }
        updateHeight()
    }

    func back() {
        let p = stack.popLast() ?? .home
        sheet = nil
        forward = false
        withAnimation(.smooth(duration: 0.3)) { screen = p }
        updateHeight()
    }

    func openSheet(_ k: SheetKind) {
        guard connected, currentMode != nil else { return showToast("Connect the headphones to adjust this.", timeout: 2.6) }
        renaming = false; deleteArmed = false
        withAnimation(.smooth(duration: 0.36)) { sheet = k }
    }

    func closeSheet() {
        renaming = false
        withAnimation(.smooth(duration: 0.3)) { sheet = nil }
    }

    func escape() {
        if sheet != nil { closeSheet() } else if screen != .home { back() } else { onHidePanel?() }
    }

    func panelShown() {
        panelShownTick += 1
        loadPrefs()
        refreshVolume()
    }

    func soon() { showToast("This option is coming soon to the desktop version.", timeout: 2.6) }

    // MARK: Toast

    func showToast(_ text: String, spin: Bool = false, timeout: Double = 0, action: String? = nil, onAction: (() -> Void)? = nil) {
        toastTask?.cancel()
        toastAction = onAction
        withAnimation(.smooth(duration: 0.3)) { toast = ToastMessage(text: text, spin: spin, action: action) }
        guard timeout > 0 else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { self?.hideToast() }
        }
    }

    func hideToast() {
        toastTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { toast = nil }
    }

    func toastActionTapped() { toastAction?() }

    // MARK: Device commands

    func selectMode(_ index: Int) {
        device.mode = index
        Core.command(["cmd": "set_mode", "index": index])
    }

    func toggleFavorite(_ m: ModeView) {
        let on = !m.favorite
        if let i = device.modes.firstIndex(where: { $0.index == m.index }) { device.modes[i].favorite = on }
        showToast(on ? L("%@ is now a favorite.", m.name) : L("%@ was removed from favorites.", m.name), timeout: 2.2)
        Core.command(["cmd": "set_favorite", "index": m.index, "on": on])
    }

    func createMode() { Core.command(["cmd": "create_mode", "prefix": L("Custom")]) }

    var ncMessage: String {
        currentMode?.cncMutable == false ? "Built-in modes have a fixed noise level. Only custom modes can be adjusted." : "The noise level can't be changed from here yet."
    }
    var immMessage: String {
        currentMode?.immMutable == false ? "This built-in mode has fixed immersive audio." : "Immersive audio can't be changed from here yet."
    }
    var canEditNC: Bool { currentMode?.cncMutable == true }
    var canEditImm: Bool { (currentMode?.immMutable == true) && (currentMode?.user == true) }

    func setNC(_ v: Int) {
        guard canEditNC, let m = currentMode else { return }
        held = (m.index, v, m.imm); scheduleSave()
        touchHold()
    }

    func setImm(_ v: Int) {
        guard canEditImm, let m = currentMode else { return }
        held = (m.index, m.nc, v); scheduleSave()
        touchHold()
    }

    private func touchHold() {
        holdUntil = Date().addingTimeInterval(4)
        edits += 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let h = self.held else { return }
            Core.command(["cmd": "save_mode", "index": h.index, "cnc_level": 10 - h.nc, "spatial_audio": h.imm])
        }
    }

    func rename(_ name: String) {
        guard let m = currentMode, m.user else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let i = device.modes.firstIndex(where: { $0.index == m.index }) { device.modes[i].name = n }
        renaming = false
        Core.command(["cmd": "rename_mode", "index": m.index, "name": n])
    }

    func deleteTapped() {
        guard let m = currentMode, m.user else { return }
        if !deleteArmed {
            deleteArmed = true
            armTask?.cancel()
            armTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self?.deleteArmed = false }
            }
            return
        }
        deleteArmed = false
        closeSheet()
        Core.command(["cmd": "reset_mode", "index": m.index])
    }

    // MARK: Shortcut button (Settings.Buttons: what the headphones' shortcut button does)

    var hasShortcut: Bool { !device.shortcutOptions.isEmpty }

    func setShortcut(_ mode: Int) {
        guard device.shortcutOptions.contains(mode), device.shortcutMode != mode else { return }
        device.shortcutMode = mode
        Core.command(["cmd": "set_shortcut", "mode": mode])
    }

    // MARK: Equalizer (Settings.RangeControl: bass / mid / treble, -10...10)

    private var eqHeld: [Int]?
    private var eqHoldUntil = Date.distantPast
    private var eqTasks: [Int: Task<Void, Never>] = [:]
    var eqGhosts: [[Int]] = []
    var hasEq: Bool { device.eq.count >= 3 }
    var eqMin: Int { device.eq.first?.min ?? -10 }
    var eqMax: Int { device.eq.first?.max ?? 10 }

    /// Levels in band order (bass, mid, treble); a just-edited value stays until the headphones confirm it.
    var eqLevels: [Int] {
        _ = edits
        if Date() < eqHoldUntil, let h = eqHeld { return h }
        return (0..<3).map { i in device.eq.first { $0.id == i }?.current ?? 0 }
    }

    func setEq(_ band: Int, _ level: Int, ghost: Bool = false) {
        guard hasEq, (0..<3).contains(band) else { return }
        var l = eqLevels
        let v = max(eqMin, min(eqMax, level))
        guard l[band] != v else { return }
        if ghost { pushGhost(l) }
        l[band] = v
        eqHeld = l; eqHoldUntil = Date().addingTimeInterval(4); edits += 1
        eqTasks[band]?.cancel()
        eqTasks[band] = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { Core.command(["cmd": "set_eq", "band": band, "level": v]) }
        }
    }

    func setEqAll(_ levels: [Int]) {
        pushGhost(eqLevels)
        for (i, v) in levels.enumerated() { setEq(i, v) }
    }

    func pushGhost(_ prev: [Int]) {
        eqGhosts.append(prev); eqGhosts = Array(eqGhosts.suffix(3))
    }

    // MARK: Volume (Mac output while the headphones are the output device)

    func refreshVolume() {
        guard connected, Date() >= volHold else { return }
        Task.detached {
            let v = try? Core.request(["req": "get_volume"], as: VolumeInfo.self)
            await MainActor.run {
                let s = Store.shared
                guard Date() >= s.volHold, let v else { return }
                s.volume = v.available ? v.level : nil
            }
        }
    }

    func setVolume(_ level: Int) {
        guard volume != nil else { return }
        let l = max(0, min(100, level))
        volume = l
        volHold = Date().addingTimeInterval(2.5)
        volTask?.cancel()
        volTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let r = await Task.detached { () -> String? in
                do { try Core.send(["req": "set_volume", "level": l]); return nil } catch { return error.localizedDescription }
            }.value
            if let r { self?.showToast(localizeCoreMessage(r), timeout: 3) }
        }
    }

    var volumeUnavailableMessage: String { "Volume can only be adjusted when the headphones are the Mac's audio output." }

    // MARK: Prefs

    func loadPrefs() {
        Task.detached {
            let p = try? Core.request(["req": "get_prefs"], as: PrefsView.self)
            await MainActor.run { if let p { Store.shared.prefs = p } }
        }
    }

    func setPref(_ key: String, _ value: Bool) {
        Task.detached {
            do {
                try Core.send(["req": "set_pref", "key": key, "value": value])
                await MainActor.run { Store.shared.loadPrefs() }
            } catch {
                await MainActor.run { Store.shared.showToast(localizeCoreMessage(error.localizedDescription), timeout: 4); Store.shared.loadPrefs() }
            }
        }
    }

    // MARK: Notifications

    private func postBatteryAlert(kind: String, name: String?, level: Int) {
        let who = name ?? L("Your headphones")
        let critical = kind == "critical"
        postNotification(L(critical ? "Battery almost empty" : "Low battery"), L(critical ? "%@ is at %d%%. Charge it now." : "%@ is at %d%%. Charge it soon.", who, level))
    }

    private func postNotification(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
