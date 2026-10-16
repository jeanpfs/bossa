import AppKit
// Borderless gradient window used as a clean backdrop behind the Bossa panel while recording.
// usage: backdrop X Y W H   (global AppKit coordinates, origin bottom-left of the main display)
let a = CommandLine.arguments
// x, y (from the top of the display), w, h are relative to the widest display
let scr = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width })!
let h = Double(a[4])!
let f = NSRect(x: scr.frame.minX + Double(a[1])!, y: scr.frame.maxY - Double(a[2])! - h, width: Double(a[3])!, height: h)
print("screen", scr.frame, "window", f)
fflush(stdout)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
w.level = .floating
w.isOpaque = true
w.hasShadow = false
let v = NSView(frame: NSRect(origin: .zero, size: f.size))
v.wantsLayer = true
let g = CAGradientLayer()
g.frame = v.bounds
g.colors = [NSColor(calibratedRed: 0.10, green: 0.08, blue: 0.22, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.14, blue: 0.42, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.45, alpha: 1).cgColor]
g.startPoint = CGPoint(x: 0, y: 1)
g.endPoint = CGPoint(x: 1, y: 0)
v.layer?.addSublayer(g)
w.contentView = v
w.orderFrontRegardless()
app.run()
