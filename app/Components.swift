import SwiftUI

// MARK: - Shapes / fills

struct Surface: ViewModifier {
    var radius: CGFloat = 20
    var fill: Color = Pal.surface
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Pal.border, lineWidth: 0.5))
    }
}

extension View {
    func surface(_ radius: CGFloat = 20, fill: Color = Pal.surface) -> some View { modifier(Surface(radius: radius, fill: fill)) }
}

/// Highlights a plain control under the pointer, like the web design's hover state.
struct HoverFill<S: Shape>: ViewModifier {
    let shape: S
    var color: Color = Pal.raised
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? color : .clear, in: shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Buttons

/// Round 40pt navigation button on Liquid Glass.
struct GlassIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 22)
                .foregroundStyle(Pal.fg)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(L(label))
        .help(L(label))
    }
}

struct PlainIconButton: View {
    let icon: String
    var size: CGFloat = 22
    var box: CGFloat = 40
    var filled = false
    var tint: Color = Pal.fg
    var fill: Color?
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: size, filled: filled)
                .foregroundStyle(tint)
                .frame(width: box, height: box)
                .background(fill ?? .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HoverFill(shape: Circle()))
        .accessibilityLabel(L(label))
        .help(L(label))
    }
}

struct TextButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(L(title)).font(.geist(14)).foregroundStyle(Pal.muted).padding(.horizontal, 12).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .modifier(HoverFill(shape: RoundedRectangle(cornerRadius: 12)))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(L(title)).font(.geist(14)).foregroundStyle(Pal.accent).underline(hovering, color: Pal.accent).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Navigation bar

struct NavBar<L: View, C: View, T: View>: View {
    @ViewBuilder var leading: L
    @ViewBuilder var center: C
    @ViewBuilder var trailing: T
    var body: some View {
        ZStack {
            center
            HStack { leading; Spacer(minLength: 0); trailing }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
    }
}

struct BarTitle: View {
    let text: String
    var body: some View { Text(L(text)).font(.geist(15, .semibold)).foregroundStyle(Pal.fg).lineLimit(1) }
}

struct DisplayTitle: View {
    let text: String
    /// Two tones like the offline headline: the first word is bright, the rest is dimmed.
    var body: some View {
        let t = L(text)
        let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let dim = Color(red: 0.961, green: 0.961, blue: 0.969).opacity(0.38)
        (parts.count > 1 ? Text(parts[0] + " ").foregroundColor(Pal.fg) + Text(parts[1]).foregroundColor(dim) : Text(t).foregroundColor(Pal.fg))
            .font(.anton(32)).tracking(0.3).accessibilityAddTraits(.isHeader).accessibilityLabel(t)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(L(text).uppercased()).font(.geist(11, .semibold)).tracking(0.9).foregroundStyle(Pal.muted)
            .padding(.horizontal, 6).padding(.top, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lists

struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .surface(22)
    }
}

struct ListRow<Lead: View, Trail: View>: View {
    let title: String
    var sub: String?
    var divider = true
    @ViewBuilder var lead: Lead
    @ViewBuilder var trail: Trail
    var body: some View {
        HStack(spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.geist(14.5)).foregroundStyle(Pal.fg).multilineTextAlignment(.leading)
                if let sub { Text(L(sub)).font(.geist(12.5, .regular)).foregroundStyle(Pal.muted).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 0)
            trail
        }
        .padding(.vertical, 10).padding(.leading, 16).padding(.trailing, 12)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Pal.border).frame(height: 0.5) } }
    }
}

struct RowButton<Lead: View, Trail: View>: View {
    let title: String
    var sub: String?
    var divider = true
    let action: () -> Void
    @ViewBuilder var lead: Lead
    @ViewBuilder var trail: Trail
    var body: some View {
        Button(action: action) {
            ListRow(title: title, sub: sub, divider: divider, lead: { lead }, trail: { trail })
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverFill(shape: Rectangle()))
    }
}

// MARK: - Volume

struct VolumeBar: View {
    let store: Store
    @State private var dragging = false
    @State private var warned = false

    private var enabled: Bool { store.connected && store.volume != nil }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let v = store.volume ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.clear)
                Capsule()
                    .fill(enabled ? Pal.volFill : Color(white: 0.3))
                    .frame(width: 52 + (w - 52) * CGFloat(v) / 100)
                    .overlay(alignment: .leading) {
                        Icon(name: "speaker", size: 22).foregroundStyle(Pal.dark).padding(.leading, 15)
                    }
                    .animation(dragging ? nil : .easeOut(duration: 0.12), value: v)
                Text(store.volume.map { "\($0)%" } ?? L("Unavailable"))
                    .font(.geist(13)).monospacedDigit()
                    .foregroundStyle(v > 84 && enabled ? Color(white: 0.3) : Pal.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else {
                        if !warned { warned = true; store.showToast(store.volumeUnavailableMessage, timeout: 2.6) }
                        return
                    }
                    dragging = true
                    store.setVolume(Int((max(0, min(1, (g.location.x - 26) / (w - 52))) * 100).rounded()))
                }
                .onEnded { _ in dragging = false; warned = false })
        }
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .opacity(store.connected ? 1 : 0.38)
        .focusable(enabled)
        .onKeyPress(.leftArrow) { step(-5) }
        .onKeyPress(.rightArrow) { step(5) }
        .onKeyPress(.downArrow) { step(-5) }
        .onKeyPress(.upArrow) { step(5) }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(store.volume.map { "\($0)%" } ?? L("Unavailable"))
        .accessibilityAdjustableAction { dir in
            switch dir { case .increment: _ = step(5); case .decrement: _ = step(-5); @unknown default: break }
        }
    }

    private func step(_ d: Int) -> KeyPress.Result {
        guard enabled, let v = store.volume else { return .ignored }
        store.setVolume(v + d)
        return .handled
    }
}

// MARK: - Noise ruler

struct Ruler: View {
    let value: Int
    let enabled: Bool
    let onChange: (Int) -> Void
    let onBlocked: () -> Void
    @State private var warned = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.raised)
                HStack(spacing: 0) {
                    ForEach(0..<11, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(i <= value ? 0.62 : 0.22)).frame(width: 2, height: i % 5 == 0 ? 22 : 12)
                        if i < 10 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 22)
                Capsule().fill(Pal.fg)
                    .frame(width: 6, height: 38)
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 3)
                    .offset(x: 20 + (w - 46) * CGFloat(value) / 10)
                    .animation(.smooth(duration: 0.18), value: value)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else {
                        if !warned { warned = true; onBlocked() }
                        return
                    }
                    onChange(Int((max(0, min(1, (g.location.x - 23) / (w - 46))) * 10).rounded()))
                }
                .onEnded { _ in warned = false })
        }
        .frame(height: 56)
        .opacity(enabled ? 1 : 0.4)
        .focusable()
        .onKeyPress(.leftArrow) { key(-1) }
        .onKeyPress(.downArrow) { key(-1) }
        .onKeyPress(.rightArrow) { key(1) }
        .onKeyPress(.upArrow) { key(1) }
        .accessibilityElement()
        .accessibilityLabel("Noise-cancelling level")
        .accessibilityValue(ncLabel(value))
        .accessibilityAdjustableAction { dir in
            switch dir { case .increment: _ = key(1); case .decrement: _ = key(-1); @unknown default: break }
        }
    }

    private func key(_ d: Int) -> KeyPress.Result {
        guard enabled else { onBlocked(); return .handled }
        onChange(max(0, min(10, value + d)))
        return .handled
    }
}

// MARK: - Toast

struct ToastView: View {
    let store: Store
    let toast: ToastMessage
    var body: some View {
        HStack(spacing: 12) {
            if toast.spin { ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16) }
            Text(L(toast.text)).font(.geist(13.5)).foregroundStyle(Pal.fg).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if let a = toast.action {
                Button(a) { store.toastActionTapped() }
                    .buttonStyle(.glassProminent).controlSize(.small).font(.geist(13, .semibold))
            }
        }
        .padding(.vertical, 8).padding(.leading, 16).padding(.trailing, 8)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .padding(.horizontal, 12).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
