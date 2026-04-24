import AppKit
import CoreGraphics
import Foundation

enum CoordMode: String {
    case pixel
    case normalized
    case global
}

func toGlobal(bounds: CGRect, x: CGFloat, y: CGFloat, coord: CoordMode) -> CGPoint {
    switch coord {
    case .global:
        return CGPoint(x: x, y: y)
    case .normalized:
        return CGPoint(x: bounds.origin.x + bounds.width * x, y: bounds.origin.y + bounds.height * y)
    case .pixel:
        return CGPoint(x: bounds.origin.x + x, y: bounds.origin.y + y)
    }
}

func mainDisplayBounds() -> CGRect {
    CGDisplayBounds(CGMainDisplayID())
}

func screenInfo() -> [String: Any] {
    let bounds = mainDisplayBounds()
    return [
        "displayID": Int(CGMainDisplayID()),
        "x": Int(bounds.origin.x),
        "y": Int(bounds.origin.y),
        "width": Int(bounds.width),
        "height": Int(bounds.height)
    ]
}

func displayPoint(x: CGFloat, y: CGFloat, coord: CoordMode) -> CGPoint {
    toGlobal(bounds: mainDisplayBounds(), x: x, y: y, coord: coord)
}

func desktopFrameAppKit() -> CGRect {
    NSScreen.screens.reduce(CGRect.null) { partial, screen in
        partial.union(screen.frame)
    }
}

func quartzToAppKitPoint(_ point: CGPoint) -> CGPoint {
    let desktop = desktopFrameAppKit()
    return CGPoint(x: point.x, y: desktop.maxY - point.y)
}
