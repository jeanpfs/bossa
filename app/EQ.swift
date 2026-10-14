import SwiftUI

private let eqW: CGFloat = 328
private let eqMid: CGFloat = 100
private let eqAmp: CGFloat = 7.8
private let eqXs: [CGFloat] = [eqW / 6, eqW / 2, 5 * eqW / 6]
private let eqBands = ["Bass", "Mid", "Treble"]
private let eqPresets: [(name: String, eq: [Int])] = [
    ("Bass boost", [6, 0, 0]), ("Bass reducer", [-6, 0, 0]),
    ("Treble boost", [0, 0, 6]), ("Treble reducer", [0, 0, -6]),
]

private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : v < 0 ? "−\(abs(v))" : "0" }

/// Catmull-Rom through the three band points, extended flat to both edges (same curve as the web design).
private func eqCurve(_ v: [Int]) -> Path {
    let pts: [CGPoint] = [CGPoint(x: 0, y: eqMid - CGFloat(v[0]) * eqAmp)] + (0..<3).map { CGPoint(x: eqXs[$0], y: eqMid - CGFloat(v[$0]) * eqAmp) } + [CGPoint(x: eqW, y: eqMid - CGFloat(v[2]) * eqAmp)]
    var p = Path()
    p.move(to: pts[0])
    for i in 0..<pts.count - 1 {
        let p0 = i > 0 ? pts[i - 1] : pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = i + 2 < pts.count ? pts[i + 2] : p2
        p.addCurve(to: p2,
                   control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                   control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    return p
}

struct EqScreen: View {
    let store: Store
    @State private var band: Int?
    @State private var start: [Int] = [0, 0, 0]

    var body: some View {
        let v = store.eqLevels
        VStack(spacing: 0) {
            NavBar {
                GlassIconButton(icon: "back", label: "Back") { store.back() }
            } center: { BarTitle(text: "Equalizer") } trailing: {
                TextButton(title: "Reset", disabled: v.allSatisfy { $0 == 0 }) { store.setEqAll([0, 0, 0]) }
            }
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { i in
                            VStack(spacing: 2) {
                                Text(L(eqBands[i])).font(.geist(13, .regular)).foregroundStyle(Pal.muted)
                                Text(signed(v[i])).font(.geist(24, .semibold)).monospacedDigit().foregroundStyle(Pal.fg)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 4).accessibilityHidden(true)

                    graph(v).padding(.top, 6)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(0..<eqPresets.count, id: \.self) { i in
                            let on = eqPresets[i].eq == v
                            Button { store.setEqAll(eqPresets[i].eq) } label: {
                                Text(L(eqPresets[i].name)).font(.geist(13.5)).multilineTextAlignment(.leading)
                                    .foregroundStyle(Pal.fg)
                                    .padding(.vertical, 10).padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                    .background(on ? Pal.raised : Pal.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(on ? Color.white.opacity(0.28) : .clear, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.top, 14)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }

    private func graph(_ v: [Int]) -> some View {
        Canvas { ctx, _ in
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: eqMid)); mid.addLine(to: CGPoint(x: eqW, y: eqMid))
            ctx.stroke(mid, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            for x in eqXs {
                var g = Path(); g.move(to: CGPoint(x: x, y: 20)); g.addLine(to: CGPoint(x: x, y: 180))
                ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            let ghosts = store.eqGhosts
            for (i, gh) in ghosts.enumerated() {
                ctx.stroke(eqCurve(gh), with: .color(Pal.fg.opacity(0.05 + 0.05 * Double(i + 3 - ghosts.count))), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            ctx.stroke(eqCurve(v), with: .color(Pal.fg), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            for i in 0..<3 {
                let c = CGPoint(x: eqXs[i], y: eqMid - CGFloat(v[i]) * eqAmp)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 12.5, y: c.y - 12.5, width: 25, height: 25)), with: .color(Pal.dark))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)), with: .color(Pal.accent))
            }
        }
        .frame(width: eqW, height: 200)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if band == nil { band = max(0, min(2, Int(g.startLocation.x / eqW * 3))); start = store.eqLevels; store.pushGhost(start) }
                if let b = band { store.setEq(b, Int(((eqMid - g.location.y) / eqAmp).rounded())) }
            }
            .onEnded { _ in band = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer")
        .accessibilityValue(zip(eqBands, v).map { "\(L($0)) \(signed($1))" }.joined(separator: ", "))
        .accessibilityAdjustableAction { dir in
            let b = 0
            store.setEq(b, v[b] + (dir == .increment ? 1 : -1), ghost: true)
        }
    }
}
