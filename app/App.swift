import AppKit
import SwiftUI

// MARK: - Menu bar glyph (headphones + battery pill, drawn natively as a template image)

enum TrayGlyph {
    /// Geometry mirrors the design's 37x18pt glyph. Coordinates are in points, y down.
    static func image(level: Int, connected: Bool) -> NSImage {
        let size = connected ? NSSize(width: 37, height: 18) : NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            let headA: CGFloat = connected ? 1 : 0.55
            let band = NSBezierPath()
            band.appendArc(withCenter: NSPoint(x: 9, y: 8.5), radius: 6, startAngle: 180, endAngle: 0, clockwise: false)
            band.move(to: NSPoint(x: 3, y: 8.5)); band.line(to: NSPoint(x: 3, y: 12))
            band.move(to: NSPoint(x: 15, y: 8.5)); band.line(to: NSPoint(x: 15, y: 12))
            band.lineWidth = 1.6; band.lineCapStyle = .round
            NSColor.black.withAlphaComponent(headA).setStroke()
            band.stroke()
            NSColor.black.withAlphaComponent(headA).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 10, width: 4, height: 5.5), xRadius: 1.6, yRadius: 1.6).fill()
            NSBezierPath(roundedRect: NSRect(x: 12.5, y: 10, width: 4, height: 5.5), xRadius: 1.6, yRadius: 1.6).fill()
            if connected {
                let outline = NSBezierPath(roundedRect: NSRect(x: 21.5, y: 5.5, width: 13, height: 7), xRadius: 2, yRadius: 2)
                outline.lineWidth = 1
                NSColor.black.withAlphaComponent(0.55).setStroke(); outline.stroke()
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: NSRect(x: 34.6, y: 7.5, width: 1.4, height: 3), xRadius: 0.6, yRadius: 0.6).fill()
                let fw = 10 * CGFloat(max(0, min(100, level))) / 100
                if fw > 0.3 {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 22, y: 5, width: fw + 0.5, height: 8), xRadius: 1, yRadius: 1).fill()
                }
            } else {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 1.5, y: 2.5)); slash.line(to: NSPoint(x: 16.5, y: 16.5))
                slash.lineWidth = 1.6; slash.lineCapStyle = .round
                NSColor.black.setStroke(); slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Panel

final class GlassPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store.shared
    private var statusItem: NSStatusItem!
    private var panel: GlassPanel!
    private var lastHide = Date.distantPast
    private var hadFocus = false
    private var volumeTimer: Timer?
    private let pinned = ProcessInfo.processInfo.environment["TRAY_PIN"] != nil
    private let showOnStart = ProcessInfo.processInfo.environment["TRAY_SHOW"] != nil || ProcessInfo.processInfo.environment["TRAY_PIN"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Fonts.register()
        buildPanel()
        buildStatusItem()

        store.onHidePanel = { [weak self] in self?.hide() }
        store.onStateChange = { [weak self] d in self?.updateTray(d) }
        store.onHeightChange = { [weak self] h in self?.resizePanel(to: h) }
        store.onLanguageChange = { [weak self] in self?.updateTray(Store.shared.device) }
        store.start()

        volumeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { if Store.shared.connected, NSApp.isActive || Store.shared.panelVisible { Store.shared.refreshVolume() } }
        }
        if showOnStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.show(at: nil) }
            // Screenshot aid: TRAY_GO=modes|bluetooth|settings, TRAY_SHEET=noise|immersive (applied once connected).
            let env = ProcessInfo.processInfo.environment
            switch env["TRAY_OFFLINE"] {
            case "searching": Store.shared.debugLink = .searching
            case "notfound": Store.shared.debugLink = .notFound
            case "btoff": Store.shared.debugLink = .bluetoothOff
            case "pairing": Store.shared.debugLink = .pairing
            default: break
            }
            Store.shared.updateHeight()
            if let l = env["TRAY_SWITCH"].flatMap(AppLanguage.init(rawValue:)) {   // live language-switch smoke test
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { Store.shared.setLanguage(l) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                switch env["TRAY_GO"] {
                case "modes": Store.shared.go(.modes)
                case "bluetooth": Store.shared.go(.bluetooth)
                case "settings": Store.shared.go(.settings)
                case "eq": Store.shared.go(.eq)
                case "shortcut": Store.shared.go(.shortcut)
                default: break
                }
                switch env["TRAY_SHEET"] {
                case "noise": Store.shared.openSheet(.noise)
                case "immersive": Store.shared.openSheet(.immersive)
                default: break
                }
            }
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        b.image = TrayGlyph.image(level: 0, connected: false)
        b.toolTip = L("%@ · searching…", "Bose QC Ultra 2 HP")
        b.target = self
        b.action = #selector(statusClicked(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateTray(_ s: DeviceState) {
        guard let b = statusItem?.button else { return }
        b.image = TrayGlyph.image(level: s.battery ?? 0, connected: s.connected)
        let name = s.name ?? "Bose QC Ultra 2 HP"
        b.toolTip = s.connected ? (s.battery.map { "\(name) · \($0)%" } ?? name) : L(s.status == "error" ? "%@ · disconnected" : "%@ · searching…", name)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("Quit %@", AppInfo.name), action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        // The blur that closes the panel fires before this click; ignore the re-open.
        if Date().timeIntervalSince(lastHide) < 0.25 { return }
        if panel.isVisible { hide() } else { show(at: sender.window?.frame) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Panel

    private func buildPanel() {
        let size = NSSize(width: 360, height: 576)
        panel = GlassPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onEscape = { [weak self] in self?.store.escape() }

        let host = NSHostingView(rootView: PanelView(store: store))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]

        // Liquid Glass window material with a dark tint (the design is dark-first).
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 20
        glass.style = .regular
        glass.tintColor = NSColor(white: 0.04, alpha: 0.38)
        glass.contentView = host
        // Clip everything (hosting view, glass) to the rounded shape so no square backing shows at the corners.
        for v in [host, glass] as [NSView] {
            v.wantsLayer = true
            v.layer?.cornerRadius = 20
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
        }
        panel.contentView = glass

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hadFocus = true; self?.refreshShadow() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hadFocus, !self.pinned else { return }
                self.hide()
            }
        }
    }

    /// Resize keeping the top edge (just under the menu bar) fixed.
    private func resizePanel(to h: CGFloat) {
        guard panel != nil else { return }
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: panel.isVisible)
        refreshShadow()
    }

    private func show(at anchor: NSRect?) {
        store.updateHeight()
        panel.setContentSize(NSSize(width: 360, height: store.panelHeight))
        let size = panel.frame.size
        var origin: NSPoint
        if let a = anchor {
            origin = NSPoint(x: a.midX - size.width / 2, y: a.minY - 6 - size.height)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) }) ?? NSScreen.main {
                let v = screen.visibleFrame
                origin.x = max(v.minX + 8, min(origin.x, v.maxX - size.width - 8))
                origin.y = max(v.minY + 8, origin.y)
            }
        } else {
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: v.maxX - size.width - 60, y: v.maxY - size.height - 6)
        }
        panel.setFrameOrigin(origin)
        hadFocus = false
        store.panelVisible = true
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2
            panel.animator().alphaValue = 1
        }
        store.panelShown()
        refreshShadow()
    }

    /// The window shadow is derived from the content's alpha; recompute it once the glass has rendered and on focus
    /// changes, otherwise the square window backing shows as dark corners.
    private func refreshShadow() {
        panel.invalidateShadow()
        for d in [0.05, 0.25, 0.6] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.panel.invalidateShadow() } }
    }

    private func hide() {
        guard panel.isVisible else { return }
        lastHide = Date()
        store.panelVisible = false
        panel.orderOut(nil)
    }
}

@main
struct BossaMain {
    @MainActor static func main() {
        LegacyDefaults.migrate()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
