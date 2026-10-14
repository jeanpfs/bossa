import SwiftUI

// MARK: - Root

struct ShiftFade: ViewModifier {
    let x: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity) }
}

struct PanelView: View {
    let store: Store

    private var transition: AnyTransition {
        let d: CGFloat = 18
        return .asymmetric(
            insertion: .modifier(active: ShiftFade(x: store.forward ? d : -d, opacity: 0), identity: ShiftFade(x: 0, opacity: 1)),
            removal: .modifier(active: ShiftFade(x: store.forward ? -d : d, opacity: 0), identity: ShiftFade(x: 0, opacity: 1)))
    }

    var body: some View {
        ZStack {
            Group {
                switch store.screen {
                case .home: HomeScreen(store: store)
                case .modes: ModesScreen(store: store)
                case .bluetooth: BluetoothScreen(store: store)
                case .settings: SettingsScreen(store: store)
                case .eq: EqScreen(store: store)
                case .shortcut: ShortcutScreen(store: store)
                }
            }
            .id(store.screen)
            .transition(transition)

            if let kind = store.sheet {
                SheetHost(store: store, kind: kind)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastView(store: store, toast: t)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 360, height: store.panelHeight)
        .environment(\.colorScheme, .dark)
        .id(store.language)
        .tint(Pal.accent)
        .onExitCommand { store.escape() }
    }
}

// MARK: - Home

struct Tile: View {
    let icon: String
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(name: icon, size: 22)
                Text(L(title)).font(.geist(14)).lineSpacing(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Pal.fg)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .surface(20)
        .modifier(HoverFill(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
    }
}

struct HomeScreen: View {
    let store: Store

    var body: some View {
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "devices", label: "Switch product") { store.showToast(L("%@ is the only paired product.", store.deviceName), timeout: 2.6) }
            } center: {
                BarTitle(text: store.deviceName)
            } trailing: {
                GlassIconButton(icon: "gear", label: "Settings") { store.go(.settings) }
            }
            if !store.connected {
                DisconnectedView(store: store)
            } else {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Glow(active: store.connected)
                        HeadphoneArt()
                            .frame(width: 196, height: 180)
                            .shadow(color: .black.opacity(0.55), radius: 9, y: 14)
                            .opacity(store.connected ? 1 : 0.4)
                            .saturation(store.connected ? 1 : 0)
                            .animation(.easeOut(duration: 0.3), value: store.connected)
                            .accessibilityLabel("Bose QC Ultra 2 headphones in graphite")
                    }
                    .frame(height: 186).padding(.top, -6)

                    Group {
                        if store.connected, let b = store.device.battery {
                            HStack(spacing: 8) {
                                BatteryGlyph(level: b)
                                Text("\(b)%")
                                if let m = store.currentMode { Text("·").foregroundStyle(Pal.muted); Text(m.name).foregroundStyle(Pal.muted) }
                            }
                        }
                    }
                    .font(.geist(14)).foregroundStyle(Pal.fg)
                    .frame(minHeight: 22).padding(.bottom, 16)

                    VolumeBar(store: store)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        let on = store.connected
                        Tile(icon: "layers", title: "Modes", enabled: on) { store.go(.modes) }
                        Tile(icon: "bt", title: "Source", enabled: on) { store.go(.bluetooth) }
                        Tile(icon: "wave", title: "Noise control", enabled: on) { store.openSheet(.noise) }
                        Tile(icon: "globe", title: "Immersive audio", enabled: on) { store.openSheet(.immersive) }
                        Tile(icon: "sliders", title: "EQ", enabled: on && store.hasEq) { store.go(.eq) }
                        Tile(icon: "bolt", title: "Shortcut", enabled: on && store.hasShortcut) { store.go(.shortcut) }
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            }
        }
    }
}

// MARK: - Modes

struct ModeRow: View {
    let store: Store
    let mode: ModeView
    var body: some View {
        let sel = store.device.mode == mode.index
        HStack(spacing: 2) {
            Button { store.selectMode(mode.index) } label: {
                HStack(spacing: 12) {
                    Icon(name: mode.icon, size: 22)
                    Text(mode.name).font(.geist(15))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Pal.fg)
                .padding(.leading, 16)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(sel ? .isSelected : [])
            if sel {
                PlainIconButton(icon: "more", size: 18, box: 34, fill: Pal.raised2, label: "Ajustar o modo \(mode.name)") { store.openSheet(.noise) }
            }
            PlainIconButton(icon: "star", size: 18, filled: mode.favorite, label: "Favorito: \(mode.name)") { store.toggleFavorite(mode) }
        }
        .padding(.trailing, 8)
        .frame(height: 60)
        .background(sel ? Pal.raised : Pal.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(sel ? 0.35 : 0), radius: 10, y: 6)
        .animation(.easeOut(duration: 0.2), value: sel)
    }
}

struct ModesScreen: View {
    let store: Store
    var body: some View {
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "back", label: "Back") { store.back() }
            } center: { EmptyView() } trailing: { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayTitle(text: "Modes")
                    Text("Each mode stores a noise-cancelling level and an immersive-audio setting. Favorites appear in the headphones' shortcut.")
                        .font(.geist(14, .regular)).lineSpacing(4).foregroundStyle(Pal.muted).padding(.top, 8)
                    VStack(spacing: 8) {
                        ForEach(store.modes) { ModeRow(store: store, mode: $0) }
                    }
                    .padding(.top, 18)
                    Button { store.createMode() } label: {
                        Icon(name: "plus", size: 22).foregroundStyle(Pal.fg).frame(width: 52, height: 52).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(maxWidth: .infinity).padding(.top, 18)
                    .accessibilityLabel("Add mode")
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Bluetooth

struct BluetoothScreen: View {
    let store: Store
    var body: some View {
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "back", label: "Back") { store.back() }
            } center: { BarTitle(text: "Bluetooth connections") } trailing: { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Manage the connections of \(store.deviceName).")
                        .font(.geist(13, .regular)).foregroundStyle(Pal.muted).lineSpacing(3)
                        .padding(.vertical, 12).padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pal.surface)
                        .padding(.horizontal, -16).padding(.bottom, 16)
                    ListCard {
                        ListRow(title: "Multipoint connection", divider: false) { } trail: {
                            Toggle("", isOn: Binding(get: { store.device.multipoint?.enabled ?? false }, set: { _ in store.showToast("Read-only in this version: editing is coming soon.", timeout: 2.6) }))
                                .toggleStyle(.switch).labelsHidden().tint(Pal.on)
                        }
                    }
                    Text("With this on, the headphones stay connected to two devices at once and switch audio between them.")
                        .font(.geist(13, .regular)).foregroundStyle(Pal.muted).lineSpacing(3).padding(.horizontal, 6).padding(.top, 10)
                    SectionLabel(text: "Paired devices")
                    ListCard {
                        ListRow(title: Host.current().localizedName ?? "This Mac", sub: "Connected · this computer", divider: false) {
                            Icon(name: "laptop", size: 18).frame(width: 36, height: 36).background(Pal.raised, in: Circle())
                        } trail: { EmptyView() }
                        RowButton(title: "Add new", action: { store.showToast("Hold the headphones' Bluetooth button until the light flashes blue.", timeout: 3.2) }) {
                            Icon(name: "plus", size: 18).frame(width: 36, height: 36).background(Pal.raised, in: Circle())
                        } trail: { EmptyView() }
                    }
                }
                .foregroundStyle(Pal.fg)
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    let store: Store

    private func yesNo(_ v: Bool?) -> String { v == nil ? "Coming soon" : (v! ? "On" : "Off") }

    private func row(_ title: String, _ sub: String? = nil, first: Bool = false, _ action: @escaping () -> Void) -> some View {
        RowButton(title: title, sub: sub, divider: !first, action: action) { } trail: {
            Icon(name: "chev", size: 18).foregroundStyle(Pal.muted)
        }
    }

    /// Read-only / not-yet-available row: no chevron, no tap, no toast.
    private func info(_ title: String, _ sub: String? = nil, first: Bool = false) -> some View {
        ListRow(title: title, sub: sub, divider: !first) { } trail: { EmptyView() }
    }

    var body: some View {
        let d = store.device
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "back", label: "Back") { store.back() }
            } center: { BarTitle(text: "Settings") } trailing: { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "About").padding(.top, 4)
                    ListCard {
                        info("Product name", store.deviceName, first: true)
                        info("Product update", d.firmware.map { L("Firmware %@", $0) } ?? "Software up to date")
                    }
                    SectionLabel(text: "Connections")
                    ListCard {
                        row("Bluetooth connections", d.multipoint.map { $0.enabled ? "Multipoint on" : "Multipoint off" }, first: true) { store.go(.bluetooth) }
                    }
                    SectionLabel(text: "Product controls")
                    ListCard {
                        row("Shortcut", d.shortcutMode.map { shortcutName($0) }, first: true) { if store.hasShortcut { store.go(.shortcut) } }
                        info("Touch control", yesNo(d.captouchFlag))
                    }
                    SectionLabel(text: "Sound")
                    ListCard {
                        row("Noise control", store.currentMode.map { ncLabel($0.nc) }, first: true) { store.openSheet(.noise) }
                        row("Immersive audio", store.currentMode.map { immLabels[$0.imm] }) { store.openSheet(.immersive) }
                    }
                    SectionLabel(text: "Preferences")
                    ListCard {
                        info("On-head detection", yesNo(d.autoPause), first: true)
                    }
                    SectionLabel(text: "App")
                    ListCard {
                        let p = store.prefs
                        ListRow(title: "Version", sub: AppInfo.versionLabel, divider: false) { } trail: { EmptyView() }
                        ListRow(title: "Language") { } trail: {
                            Picker("", selection: Binding(get: { store.language }, set: { store.setLanguage($0) })) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        ListRow(title: "Open at login", sub: p?.autostartSupported == false ? "Available in the installed app" : nil) { } trail: {
                            Toggle("", isOn: Binding(get: { p?.autostart ?? false }, set: { store.setPref("autostart", $0) }))
                                .toggleStyle(.switch).labelsHidden().tint(Pal.on).disabled(p?.autostartSupported != true)
                        }
                        ListRow(title: "Low battery alerts", sub: "At 20% and 10%") { } trail: {
                            Toggle("", isOn: Binding(get: { p?.lowBatteryAlerts ?? true }, set: { store.setPref("low_battery_alerts", $0) }))
                                .toggleStyle(.switch).labelsHidden().tint(Pal.on)
                        }
                        RowButton(title: L("Quit %@", AppInfo.name), action: { NSApp.terminate(nil) }) { } trail: { EmptyView() }
                    }
                }
                .foregroundStyle(Pal.fg)
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Sheets

struct SheetHost: View {
    let store: Store
    let kind: SheetKind
    @State private var dy: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { store.closeSheet() }
                .transition(.opacity)
            VStack(spacing: 0) {
                Button { store.closeSheet() } label: {
                    Capsule().fill(Color.white.opacity(0.26)).frame(width: 40, height: 5)
                        .frame(maxWidth: .infinity).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .gesture(DragGesture()
                    .onChanged { dy = max(0, $0.translation.height) }
                    .onEnded { g in if g.translation.height > 70 { store.closeSheet() }; withAnimation(.smooth) { dy = 0 } })
                Group {
                    switch kind {
                    case .noise: NoiseSheet(store: store)
                    case .immersive: ImmersiveSheet(store: store)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 24, style: .continuous))
            .offset(y: dy)
            .transition(.move(edge: .bottom))
        }
    }
}

struct NoiseSheet: View {
    let store: Store
    @State private var name = ""

    var body: some View {
        let m = store.currentMode
        VStack(alignment: .leading, spacing: 0) {
            DisplayTitle(text: "Noise control").padding(.top, 6).padding(.bottom, 8)
            Text("Choose how much of your surroundings you want to hear in \(m.map { L($0.name) } ?? "") mode.")
                .font(.geist(14, .regular)).lineSpacing(4).foregroundStyle(Pal.muted)
            HStack {
                Text("Noise control").font(.geist(15))
                Spacer()
                Toggle("", isOn: Binding(get: { true }, set: { _ in store.showToast(store.ncMessage, timeout: 2.6) }))
                    .toggleStyle(.switch).labelsHidden().tint(Pal.on)
            }
            .padding(.leading, 16).padding(.trailing, 14).frame(minHeight: 58)
            .background(Pal.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 16)

            let nc = m?.nc ?? 0
            Text(ncLabel(nc)).font(.geist(14, .semibold)).frame(maxWidth: .infinity).frame(minHeight: 18).padding(.top, 20).padding(.bottom, 10)
            Ruler(value: nc, enabled: store.canEditNC, onChange: { store.setNC($0) }, onBlocked: { store.showToast(store.ncMessage, timeout: 2.6) })
            HStack {
                Text("Awareness"); Spacer(); Text("Cancelling")
            }
            .font(.geist(12, .regular)).foregroundStyle(Pal.muted).padding(.horizontal, 8).padding(.top, 8)
            Text(ncHelp(nc)).font(.geist(13, .regular)).lineSpacing(3).foregroundStyle(Pal.muted)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 39).padding(.top, 12)

            if let m, m.user {
                if store.renaming {
                    HStack(spacing: 8) {
                        TextField("Mode name", text: $name)
                            .textFieldStyle(.plain).font(.geist(15))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                            .onSubmit { store.rename(name) }
                        LinkButton(title: "Save") { store.rename(name) }
                    }
                    .padding(.top, 10)
                } else {
                    HStack(spacing: 18) {
                        LinkButton(title: "Rename this mode") { name = m.name; store.renaming = true }
                        LinkButton(title: store.deleteArmed ? "Tap again to delete" : "Delete this mode") { store.deleteTapped() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Pal.fg)
    }
}

struct ImmersiveSheet: View {
    let store: Store
    @Namespace private var ns

    var body: some View {
        let cur = store.currentMode?.imm ?? 0
        VStack(alignment: .leading, spacing: 0) {
            DisplayTitle(text: "Immersive audio").padding(.top, 6).padding(.bottom, 8)
            Text("Sound spreads around you, as if it came from speakers in front of you.")
                .font(.geist(14, .regular)).lineSpacing(4).foregroundStyle(Pal.muted)
            LinkButton(title: "Watch the demo.") { store.soon() }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let on = cur == i
                    Button {
                        if store.canEditImm { store.setImm(i) } else { store.showToast(store.immMessage, timeout: 2.6) }
                    } label: {
                        VStack(spacing: 7) {
                            Icon(name: ["off", "still", "motion"][i], size: 22)
                            Text(L(immLabels[i])).font(.geist(12.5))
                        }
                        .foregroundStyle(on ? Pal.fg : Pal.muted)
                        .frame(maxWidth: .infinity).frame(height: 74)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.2))
                                    .shadow(color: .black.opacity(0.35), radius: 7, y: 5)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Pal.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .animation(.smooth(duration: 0.2), value: cur)
            .padding(.top, 16)
            Text(L(immStatus[cur])).font(.geist(13.5, .regular)).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 14).padding(.bottom, 4)
            LinkButton(title: "Calibrate the headphones") { store.soon() }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(Pal.fg)
    }
}

// MARK: - Shortcut

struct ShortcutScreen: View {
    let store: Store
    var body: some View {
        let cur = store.device.shortcutMode
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "back", label: "Back") { store.back() }
            } center: { EmptyView() } trailing: { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayTitle(text: "Shortcut")
                    Text("Choose what the headphones' shortcut button does. Only functions this product supports are listed.")
                        .font(.geist(14, .regular)).lineSpacing(4).foregroundStyle(Pal.muted).padding(.top, 8).padding(.bottom, 18)
                    ListCard {
                        ForEach(Array(store.device.shortcutOptions.enumerated()), id: \.element) { i, mode in
                            RowButton(title: shortcutName(mode), divider: i > 0, action: { store.setShortcut(mode) }) { } trail: {
                                if cur == mode { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.accent) }
                            }
                            .accessibilityAddTraits(cur == mode ? .isSelected : [])
                        }
                    }
                }
                .foregroundStyle(Pal.fg)
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }
}
