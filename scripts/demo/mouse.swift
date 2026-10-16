import CoreGraphics
import Foundation
// usage: mouse move X Y | click X Y | drag X1 Y1 X2 Y2 [steps]
let a = CommandLine.arguments
func p(_ i: Int) -> CGFloat { CGFloat(Double(a[i])!) }
func post(_ t: CGEventType, _ x: CGFloat, _ y: CGFloat) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
}
switch a[1] {
case "move": post(.mouseMoved, p(2), p(3))
case "click": post(.mouseMoved, p(2), p(3)); usleep(120_000); post(.leftMouseDown, p(2), p(3)); usleep(60_000); post(.leftMouseUp, p(2), p(3))
case "drag":
  let n = a.count > 6 ? Int(a[6])! : 40
  post(.mouseMoved, p(2), p(3)); usleep(300_000)
  post(.leftMouseDown, p(2), p(3)); usleep(80_000)
  for i in 1...n { let t = CGFloat(i)/CGFloat(n); post(.leftMouseDragged, p(2)+(p(4)-p(2))*t, p(3)+(p(5)-p(3))*t); usleep(22_000) }
  usleep(150_000); post(.leftMouseUp, p(4), p(5))
default: break
}
