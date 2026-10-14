import SwiftUI

/// What the "not connected" screen is telling the user.
enum LinkState { case searching, notFound, bluetoothOff, pairing }

/// The last time the headphones were seen, kept across launches so the offline screen is useful.
struct LastKnown: Codable, Equatable {
    var battery: Int
    var mode: String?          // device-reported (English) mode name
    var seenAt: Date

    static let key = "lastKnownDevice"
    static func load() -> LastKnown? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LastKnown.self, from: $0) }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Splits "Not|connected" (one translatable key, two tones) into its lines.
private func twoTone(_ key: String) -> (String, String) {
    let parts = L(key).split(separator: "|", maxSplits: 1).map(String.init)
    return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
}

struct StatusDot: View {
    let state: LinkState
    @State private var on = false
    var body: some View {
        let accent = state == .searching || state == .pairing
        ZStack {
            if state == .searching {
                Circle().fill(Pal.accent).frame(width: 8, height: 8)
                    .scaleEffect(on ? 3.2 : 1).opacity(on ? 0 : 0.6)
            }
            Circle().fill(accent ? Pal.accent : Pal.muted).frame(width: 8, height: 8)
                .opacity(state == .pairing ? (on ? 0.25 : 1) : 1)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            withAnimation(state == .pairing ? .linear(duration: 1).repeatForever(autoreverses: true) : .easeOut(duration: 2).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

struct DisconnectedView: View {
    let store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(state: store.linkState(now: ctx.date), now: ctx.date)
        }
    }

    private func content(state: LinkState, now: Date) -> some View {
        let head: (String, String) = {
            switch state {
            case .searching, .notFound: return twoTone("Not|connected")
            case .bluetoothOff: return twoTone("Bluetooth|is off")
            case .pairing: return twoTone("Not|paired yet")
            }
        }()
        let eyebrow: String = {
            switch state {
            case .searching: return store.device.status == "connecting" ? "Connecting…" : "Searching nearby…"
            case .notFound: return "Not in range"
            case .bluetoothOff: return "Bluetooth unavailable"
            case .pairing: return "Waiting for pairing mode"
            }
        }()
        let sub: String = {
            switch state {
            case .searching: return "We'll connect as soon as your headphones are on and nearby."
            case .notFound: return "They may be off, out of range, or connected to another device."
            case .bluetoothOff: return "Turn on Bluetooth on this Mac to connect."
            case .pairing: return "First time here? Put your headphones in pairing mode."
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(state: state)
                Text(L(eyebrow)).font(.geist(12)).foregroundStyle(Pal.muted)
            }
            .frame(height: 20).padding(.top, 8)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 0) {
                Text(head.0.uppercased()).foregroundStyle(Pal.fg).frame(height: 56)
                Text(head.1.uppercased()).foregroundStyle(Color(red: 0.961, green: 0.961, blue: 0.969).opacity(0.38)).frame(height: 56)
            }
            .font(.anton(60)).tracking(0.3)
            .padding(.top, 20)
            .accessibilityElement(children: .combine)

            Text(L(sub)).font(.geist(13, .regular)).lineSpacing(3).foregroundStyle(Pal.muted)
                .frame(maxWidth: 280, minHeight: 38, alignment: .topLeading).padding(.top, 14)

            Spacer(minLength: 16)

            card(state: state, now: now)

            actions(state: state).padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func card(state: LinkState, now: Date) -> some View {
        let known = store.lastKnown
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L(state == .pairing || known == nil ? "How to pair" : "Last known")).font(.geist(12)).foregroundStyle(Pal.muted)
                Spacer()
                Canvas { c, _ in
                    let s: CGFloat = 28 / 240
                    var g = c; g.scaleBy(x: s, y: s)
                    var band = Path()
                    band.move(to: CGPoint(x: 45, y: 128)); band.addLine(to: CGPoint(x: 45, y: 95))
                    band.addArc(center: CGPoint(x: 120, y: 95), radius: 75, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    band.addLine(to: CGPoint(x: 195, y: 128))
                    g.stroke(band, with: .color(Pal.muted), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    for (cx, rot) in [(62.0, -9.0), (178.0, 9.0)] {
                        var t = g; t.translateBy(x: cx, y: 176); t.rotate(by: .degrees(rot)); t.translateBy(x: -cx, y: -176)
                        t.stroke(Path(ellipseIn: CGRect(x: cx - 24, y: 176 - 35, width: 48, height: 70)), with: .color(Pal.muted), lineWidth: 12)
                    }
                }
                .frame(width: 28, height: 26)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

            if state == .pairing || known == nil {
                Text(L("Hold the power button until the light flashes blue. Keep them close to this Mac."))
                    .font(.geist(13, .regular)).lineSpacing(3).foregroundStyle(Pal.fg)
                    .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
            } else if let k = known {
                HStack(spacing: 0) {
                    cell("Battery") { HStack(spacing: 6) { BatteryGlyph(level: k.battery).scaleEffect(0.77); Text("\(k.battery)%") } }
                    Rectangle().fill(Pal.border).frame(width: 0.5)
                    cell("Mode") { Text(k.mode.map { L($0) } ?? "—") }
                    Rectangle().fill(Pal.border).frame(width: 0.5)
                    cell("Seen") { Text(Self.relative(k.seenAt, now: now)) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(14)
    }

    private func cell<C: View>(_ label: String, @ViewBuilder _ value: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(label)).font(.geist(11, .regular)).foregroundStyle(Pal.muted)
            value().font(.geist(17, .semibold)).monospacedDigit().foregroundStyle(Pal.fg).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func actions(state: LinkState) -> some View {
        let bt = { store.openBluetoothSettings() }
        switch state {
        case .searching:
            HStack(spacing: 8) {
                ActionPill(title: "Searching", spinner: true, disabled: true) {}
                ActionPill(title: "Bluetooth", icon: "bt", action: bt)
            }
        case .notFound:
            HStack(spacing: 8) {
                ActionPill(title: "Try again", systemIcon: "arrow.clockwise") { store.rescan() }
                ActionPill(title: "Bluetooth", icon: "bt", action: bt)
            }
        case .bluetoothOff:
            ActionPill(title: "Open Bluetooth settings", icon: "bt", action: bt)
        case .pairing:
            ActionPill(title: "Look for headphones", systemIcon: "arrow.clockwise") { store.rescan() }
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L("Just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: AppLanguage.saved == .system ? (Locale.preferredLanguages.first ?? "en") : AppLanguage.saved.rawValue)
        return f.localizedString(for: date, relativeTo: now)
    }
}

struct ActionPill: View {
    let title: String
    var icon: String?
    var systemIcon: String?
    var spinner = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if spinner { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                if let icon { Icon(name: icon, size: 16) }
                if let systemIcon { Image(systemName: systemIcon).font(.system(size: 13, weight: .semibold)) }
                Text(L(title)).font(.geist(14))
            }
            .foregroundStyle(disabled ? Pal.fg.opacity(0.62) : Pal.fg)
            .frame(maxWidth: .infinity).frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .glassEffect(disabled ? .clear : .regular.interactive(), in: .capsule)
    }
}
