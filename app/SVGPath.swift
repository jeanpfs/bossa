import SwiftUI

/// Minimal SVG path-data reader: M, L, Z and semicircular A (all the cushion art uses), absolute coordinates.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var p = Path()
        var cur = CGPoint.zero
        let tokens = d.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "M", with: " M ").replacingOccurrences(of: "L", with: " L ")
            .replacingOccurrences(of: "A", with: " A ").replacingOccurrences(of: "Z", with: " Z ")
            .split(whereSeparator: { $0 == " " }).map(String.init)
        var i = 0
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            let t = tokens[i]; i += 1
            switch t {
            case "M": cur = CGPoint(x: num(), y: num()); p.move(to: cur)
            case "L": cur = CGPoint(x: num(), y: num()); p.addLine(to: cur)
            case "A":
                _ = num(); _ = num(); _ = num(); _ = num(); _ = num()
                let end = CGPoint(x: num(), y: num())
                // Semicircle on the chord (cur -> end), bulging up (sweep 1 in a y-down space).
                let c = CGPoint(x: (cur.x + end.x) / 2, y: (cur.y + end.y) / 2)
                let r = hypot(end.x - cur.x, end.y - cur.y) / 2
                let a0 = atan2(cur.y - c.y, cur.x - c.x)
                p.addArc(center: c, radius: r, startAngle: .radians(Double(a0)), endAngle: .radians(Double(a0) + .pi), clockwise: false)
                cur = end
            case "Z": p.closeSubpath()
            default: break
            }
        }
        return p
    }
}
