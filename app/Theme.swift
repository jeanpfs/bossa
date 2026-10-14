import AppKit
import CoreText
import SwiftUI

// MARK: - Palette (same hues as the web design; surfaces are translucent so the glass shows through)

enum Pal {
    static let fg = Color(red: 0.961, green: 0.961, blue: 0.969)          // #F5F5F7
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.651)       // #A1A1A6
    static let accent = Color(red: 0.478, green: 0.635, blue: 1.0)        // #7AA2FF
    static let on = Color(red: 0.188, green: 0.820, blue: 0.345)          // #30D158
    static let surface = Color.white.opacity(0.075)
    static let raised = Color.white.opacity(0.13)
    static let raised2 = Color.white.opacity(0.19)
    static let border = Color.white.opacity(0.10)
    static let volFill = Color(white: 0.87)
    static let dark = Color(red: 0.043, green: 0.043, blue: 0.047)         // #0B0B0C
}

// MARK: - Fonts (Anton for headlines, Geist for UI; bundled TTFs registered at launch)

enum Fonts {
    static func register() {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")]
        for dir in dirs.compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
            if !files.isEmpty { return }
        }
    }
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name = weight == .semibold || weight == .bold ? "Geist-SemiBold" : weight == .regular ? "Geist-Regular" : "Geist-Medium"
        return .custom(name, size: size)
    }
    static func anton(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size) }
}

// MARK: - Icons (the design's 24x24 stroke icons, rendered natively from SVG)

enum IconArt {
    static let paths: [String: String] = [
        "back": "<path d='M15 5l-7 7 7 7'/>",
        "chev": "<path d='M10 6l6 6-6 6'/>",
        "gear": "<circle cx='12' cy='12' r='3'/><path d='M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z'/>",
        "devices": "<rect x='2.5' y='5' width='13' height='9.5' rx='1.5'/><path d='M1.5 18h15'/><rect x='17.5' y='8' width='5' height='11' rx='1.2'/>",
        "speaker": "<path d='M4 9.5h3.2L11.5 6v12l-4.3-3.5H4z'/><path d='M15 9.2a4 4 0 0 1 0 5.6M17.6 6.8a7.5 7.5 0 0 1 0 10.4'/>",
        "layers": "<path d='M12 3.5l8.5 4.6L12 12.7 3.5 8.1z'/><path d='M3.5 12.3l8.5 4.6 8.5-4.6M3.5 16.2l8.5 4.6 8.5-4.6'/>",
        "bt": "<path d='M7 7.5l10 9-5 4.5V3l5 4.5-10 9'/>",
        "wave": "<path d='M3 12h1.5M7 8.5v7M10.5 5v14M14 8v8M17.5 10v4M21 12h-.5'/>",
        "globe": "<circle cx='12' cy='12' r='8.5'/><ellipse cx='12' cy='12' rx='8.5' ry='3.4'/><ellipse cx='12' cy='12' rx='3.4' ry='8.5'/>",
        "sliders": "<path d='M6 4v8M6 16v4M12 4v2M12 10v10M18 4v10M18 18v2'/><circle cx='6' cy='14' r='2'/><circle cx='12' cy='8' r='2'/><circle cx='18' cy='16' r='2'/>",
        "bolt": "<path d='M13 3L5 13.5h6L10 21l8-10.5h-6z'/>",
        "bulb": "<path d='M9.5 18h5M10.5 21h3'/><path d='M12 3a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.3 1.1 2.2h5c0-.9.4-1.6 1.1-2.2A6 6 0 0 0 12 3z'/>",
        "buoy": "<circle cx='12' cy='12' r='8.5'/><circle cx='12' cy='12' r='3.5'/><path d='M6 6l3.5 3.5M14.5 14.5L18 18M18 6l-3.5 3.5M9.5 14.5L6 18'/>",
        "star": "<path d='M12 3.6l2.6 5.2 5.8.9-4.2 4.1 1 5.7L12 16.8l-5.2 2.7 1-5.7-4.2-4.1 5.8-.9z'/>",
        "more": "<circle cx='6' cy='12' r='1'/><circle cx='12' cy='12' r='1'/><circle cx='18' cy='12' r='1'/>",
        "plus": "<path d='M12 5v14M5 12h14'/>",
        "moon": "<path d='M19.5 14.5A7.8 7.8 0 0 1 9.5 4.5a7.8 7.8 0 1 0 10 10z'/>",
        "ear": "<path d='M7 9a5 5 0 0 1 10 0c0 3-3 4-3 7a3 3 0 0 1-5.5 1.6'/><path d='M10 9.5a2 2 0 0 1 4 0c0 1.2-1 1.6-1.5 2.5'/>",
        "imm": "<circle cx='12' cy='12' r='1.8'/><path d='M8 8a5.7 5.7 0 0 0 0 8M16 8a5.7 5.7 0 0 1 0 8M5.2 5.2a9.6 9.6 0 0 0 0 13.6M18.8 5.2a9.6 9.6 0 0 1 0 13.6'/>",
        "film": "<rect x='3' y='5' width='18' height='14' rx='2'/><path d='M7.5 5v14M16.5 5v14M3 9.7h4.5M3 14.3h4.5M16.5 9.7H21M16.5 14.3H21'/>",
        "off": "<circle cx='12' cy='12' r='8'/><path d='M6.4 17.6L17.6 6.4'/>",
        "still": "<circle cx='12' cy='8' r='3.5'/><path d='M5.5 20c1-3.4 3.6-5.4 6.5-5.4s5.5 2 6.5 5.4'/>",
        "motion": "<circle cx='12' cy='8' r='3.5'/><path d='M5.5 20c1-3.4 3.6-5.4 6.5-5.4s5.5 2 6.5 5.4M3.2 5.5a6.5 6.5 0 0 0 0 5.5M20.8 5.5a6.5 6.5 0 0 1 0 5.5'/>",
        "laptop": "<rect x='4' y='5' width='16' height='11' rx='1.5'/><path d='M2 19h20'/>",
        "phone": "<rect x='7' y='2.5' width='10' height='19' rx='2.5'/><path d='M11 18.5h2'/>",
    ]

    @MainActor private static var cache: [String: NSImage] = [:]

    /// Template image (tinted by `foregroundStyle`). `filled` mirrors the star's pressed state.
    @MainActor static func image(_ name: String, filled: Bool = false) -> NSImage {
        let key = name + (filled ? "#f" : "")
        if let c = cache[key] { return c }
        let body = paths[name] ?? ""
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='\(filled ? "#000" : "none")' stroke='#000' stroke-width='1.75' stroke-linecap='round' stroke-linejoin='round'>\(body)</svg>"
        let raw = NSImage(data: Data(svg.utf8)) ?? NSImage()
        let side: CGFloat = 24
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            raw.draw(in: rect)
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}

struct Icon: View {
    let name: String
    var size: CGFloat = 22
    var filled = false
    var body: some View {
        Image(nsImage: IconArt.image(name, filled: filled))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Battery glyph (home status row)

struct BatteryGlyph: View {
    let level: Int
    var body: some View {
        Canvas { ctx, _ in
            let body = Path(roundedRect: CGRect(x: 0.75, y: 0.75, width: 21.5, height: 11.5), cornerRadius: 3.2)
            ctx.stroke(body, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            ctx.fill(Path(roundedRect: CGRect(x: 23.4, y: 4.2, width: 2, height: 4.6), cornerRadius: 1), with: .color(.white.opacity(0.7)))
            let w = 17 * CGFloat(max(0, min(100, level))) / 100
            if w > 0 { ctx.fill(Path(roundedRect: CGRect(x: 3, y: 3, width: w, height: 7), cornerRadius: 1.6), with: .color(.white)) }
        }
        .frame(width: 26, height: 13)
    }
}

// MARK: - Headphone illustration (drawn from the design's SVG: 240x220 viewBox)

struct HeadphoneArt: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 240, size.height / 220)
            var c = ctx
            c.translateBy(x: (size.width - 240 * s) / 2, y: (size.height - 220 * s) / 2)
            c.scaleBy(x: s, y: s)
            Self.draw(&c)
        }
        .aspectRatio(240.0 / 220.0, contentMode: .fit)
    }

    private static func g(_ stops: [(Double, Color)]) -> Gradient {
        Gradient(stops: stops.map { .init(color: $0.1, location: $0.0) })
    }

    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255).opacity(a)
    }

    private static func curve(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        var i = 1
        while i + 2 < pts.count + 0 {
            p.addCurve(to: CGPoint(x: pts[i + 2].0, y: pts[i + 2].1), control1: CGPoint(x: pts[i].0, y: pts[i].1), control2: CGPoint(x: pts[i + 1].0, y: pts[i + 1].1))
            i += 3
        }
        return p
    }

    /// Soft-touch silicone headband cushion (Open Design v5): tapered moulded body, dark core, sheen and a long specular streak.
    private static func cushion(_ c: inout GraphicsContext) {
        func lin(_ stops: [(Double, Color)]) -> GraphicsContext.Shading {
            .linearGradient(g(stops), startPoint: CGPoint(x: 45, y: 0), endPoint: CGPoint(x: 195, y: 0))
        }
        c.stroke(SVGPath.parse(CushionData.lip), with: .color(.white.opacity(0.18)), lineWidth: 0.8)
        let body = SVGPath.parse(CushionData.fill)
        c.fill(body, with: .radialGradient(g([(0.79, hex(0x141416)), (0.84, hex(0x1C1C20)), (0.9, hex(0x2C2C32)), (0.95, hex(0x3A3A42)), (0.98, hex(0x26262B)), (1, hex(0x121214))]), center: CGPoint(x: 120, y: 95), startRadius: 0, endRadius: 67.6))
        c.fill(SVGPath.parse(CushionData.len), with: lin([(0, .white.opacity(0)), (0.25, .white.opacity(0.07)), (0.6, .white.opacity(0)), (1, .black.opacity(0.22))]))
        c.fill(SVGPath.parse(CushionData.shadow), with: .color(hex(0x0A0A0C, 0.38)))
        c.fill(SVGPath.parse(CushionData.sheen), with: lin([(0, .white.opacity(0)), (0.3, .white.opacity(0.08)), (0.7, .white.opacity(0.02)), (1, .white.opacity(0))]))
        c.fill(SVGPath.parse(CushionData.spec), with: lin([(0, .white.opacity(0)), (0.22, .white.opacity(0.55)), (0.48, .white.opacity(0.3)), (0.75, .white.opacity(0.07)), (1, .white.opacity(0))]))
        c.stroke(SVGPath.parse(CushionData.crease), with: .color(hex(0x0A0A0C, 0.6)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        c.stroke(SVGPath.parse(CushionData.crease2), with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
    }

    /// Semicircle between `left` and `right` (centre height `center`) continued by vertical legs down to `bottom`.
    private static func arch(left: CGFloat, right: CGFloat, center: CGFloat, bottom: CGFloat) -> Path {
        let r = (right - left) / 2
        var p = Path()
        p.move(to: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: left, y: center))
        p.addArc(center: CGPoint(x: (left + right) / 2, y: center), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: right, y: bottom))
        return p
    }

    private static func ellipse(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, rot: Double, about: CGPoint, fill: GraphicsContext.Shading? = nil, stroke: GraphicsContext.Shading? = nil, lineWidth: CGFloat = 1) {
        var t = c
        t.translateBy(x: about.x, y: about.y)
        t.rotate(by: .degrees(rot))
        t.translateBy(x: -about.x, y: -about.y)
        let r = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        let p = Path(ellipseIn: r)
        if let fill { t.fill(p, with: fill) }
        if let stroke { t.stroke(p, with: stroke, lineWidth: lineWidth) }
    }

    private static func cup(_ c: inout GraphicsContext) {
        let metal = GraphicsContext.Shading.linearGradient(g([(0, hex(0x5B5B62)), (0.5, hex(0x9A9AA2)), (1, hex(0x3B3B41))]), startPoint: CGPoint(x: 45, y: 0), endPoint: CGPoint(x: 56, y: 0))
        let arm = curve([(46, 112), (45, 128), (47, 142), (56, 152)])
        c.stroke(arm, with: metal, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        var sh = c; sh.translateBy(x: 1.6, y: 0)
        sh.stroke(arm, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // ear pad (inner side)
        let padC = CGPoint(x: 73, y: 176)
        ellipse(&c, cx: 73, cy: 176, rx: 27, ry: 37, rot: -9, about: padC,
                fill: .radialGradient(g([(0, hex(0x2A2A2E)), (1, hex(0x09090A))]), center: CGPoint(x: 73 - 27 + 54 * 0.6, y: 176 - 37 + 74 * 0.35), startRadius: 0, endRadius: 54 * 0.8))
        // shell
        let shellC = CGPoint(x: 62, y: 176)
        let rim = GraphicsContext.Shading.linearGradient(g([(0, .white.opacity(0.55)), (0.5, .white.opacity(0.06)), (1, .white.opacity(0.2))]), startPoint: CGPoint(x: 35, y: 137.5), endPoint: CGPoint(x: 89, y: 214.5))
        ellipse(&c, cx: 62, cy: 176, rx: 27, ry: 38.5, rot: -9, about: shellC,
                fill: .linearGradient(g([(0, hex(0x4A4A50)), (0.38, hex(0x232326)), (1, hex(0x0C0C0E))]), startPoint: CGPoint(x: 35, y: 137.5), endPoint: CGPoint(x: 89, y: 214.5)),
                stroke: rim, lineWidth: 1.1)
        // face
        let faceC = CGPoint(x: 60, y: 176)
        ellipse(&c, cx: 60, cy: 176, rx: 19, ry: 30, rot: -9, about: faceC,
                fill: .linearGradient(g([(0, hex(0x37373C)), (0.55, hex(0x1B1B1E)), (1, hex(0x101012))]), startPoint: CGPoint(x: 41 + 38 * 0.2, y: 146), endPoint: CGPoint(x: 41 + 38 * 0.8, y: 206)))
        c.stroke(curve([(45, 160), (48, 150), (56, 146), (63, 147)]), with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        for (x, y) in [(66.0, 197.0), (70, 196.5), (68, 200), (72, 199.5)] {
            c.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(hex(0x6B6B72)))
        }
        var k = c
        k.translateBy(x: 74, y: 175); k.rotate(by: .degrees(-9)); k.translateBy(x: -74, y: -175)
        let btn = Path(roundedRect: CGRect(x: 73, y: 170, width: 3, height: 11), cornerRadius: 1.5)
        k.fill(btn, with: .color(hex(0x050506)))
        k.stroke(btn, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
    }

    static func draw(_ c: inout GraphicsContext) {
        let band = GraphicsContext.Shading.linearGradient(g([(0, hex(0x26262B)), (0.3, hex(0x47474F)), (0.55, hex(0x383840)), (1, hex(0x202024))]), startPoint: CGPoint(x: 44, y: 0), endPoint: CGPoint(x: 196, y: 0))
        // Circular arch (semicircle on straight legs) so the band reads round, not elliptical.
        c.stroke(arch(left: 45, right: 195, center: 95, bottom: 128), with: band, style: StrokeStyle(lineWidth: 16, lineCap: .round))
        c.stroke(arch(left: 53, right: 187, center: 95, bottom: 118), with: .color(.white.opacity(0.32)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        cushion(&c)

        let rim = GraphicsContext.Shading.linearGradient(g([(0, .white.opacity(0.55)), (0.5, .white.opacity(0.06)), (1, .white.opacity(0.2))]), startPoint: .zero, endPoint: CGPoint(x: 240, y: 220))
        for x in [36.0, 186.0] {
            let r = Path(roundedRect: CGRect(x: x, y: 112, width: 18, height: 16), cornerRadius: 6)
            c.fill(r, with: .color(hex(0x1A1A1D)))
            c.stroke(r, with: rim, lineWidth: 0.8)
        }
        cup(&c)
        var m = c
        m.translateBy(x: 240, y: 0); m.scaleBy(x: -1, y: 1)
        cup(&m)
    }
}

/// Soft breathing glow behind the headphones.
struct Glow: View {
    var active = true
    @State private var phase = false
    var body: some View {
        Ellipse()
            .fill(RadialGradient(stops: [
                .init(color: Color(red: 0.62, green: 0.71, blue: 0.87).opacity(0.2), location: 0),
                .init(color: Color(red: 0.40, green: 0.48, blue: 0.65).opacity(0.07), location: 0.6),
                .init(color: .clear, location: 1),
            ], center: .center, startRadius: 0, endRadius: 135))
            .frame(width: 270, height: 180)
            .scaleEffect(phase ? 1.05 : 0.94)
            .opacity(active ? (phase ? 1 : 0.75) : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { phase = true }
            }
    }
}
