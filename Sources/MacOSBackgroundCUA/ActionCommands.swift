import CoreGraphics
import Foundation

func inferredScreenshotPath(prefix: String, format: String) -> String {
    "/tmp/\(prefix).\(format == "png" ? "png" : "jpg")"
}

func runBackgroundSubcommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("background needs a command") }
    let command = try cursor.pop()
    switch command {
    case "screenshot":
        let target = try cursor.pop()
        let (output, format, quality, anyWindow) = try parseBackgroundScreenshotOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        let path = output ?? inferredScreenshotPath(prefix: "win-\(wid)", format: format)
        try screenshot(wid: wid, path: path, format: format, quality: quality)
        print(path)
    case "click":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(click(wid: wid, x: x, y: y, coord: coord))
    case "right-click":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(rightClick(wid: wid, x: x, y: y, coord: coord))
    case "double-click":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(doubleClick(wid: wid, x: x, y: y, coord: coord))
    case "drag":
        let target = try cursor.pop()
        let x1 = try cursor.popDouble()
        let y1 = try cursor.popDouble()
        let x2 = try cursor.popDouble()
        let y2 = try cursor.popDouble()
        let (duration, steps, coord, anyWindow) = try parseBackgroundDragOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(drag(wid: wid, x1: x1, y1: y1, x2: x2, y2: y2, coord: coord, steps: steps, duration: duration))
    case "scroll":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let dx = try cursor.popDouble()
        let dy = try cursor.popDouble()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(["via": scroll(wid: wid, x: x, y: y, dx: dx, dy: dy, coord: coord)])
    case "type":
        let target = try cursor.pop()
        let text = try cursor.pop()
        let (at, replace, coord, anyWindow) = try parseBackgroundTypeOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(["via": typeText(wid: wid, text: text, at: at, coord: coord, replace: replace)])
    case "ax-dump":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(axDump(wid: wid, x: x, y: y, coord: coord))
    case "ax-action":
        let target = try cursor.pop()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let action = try cursor.pop()
        let (coord, anyWindow) = try parseBackgroundCoordOptions(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(axAction(wid: wid, x: x, y: y, action: action, coord: coord))
    case "press":
        let target = try cursor.pop()
        let key = try cursor.pop()
        let (modifiers, anyWindow) = try parseBackgroundPressModifiers(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(pressKey(wid: wid, key: key, modifiers: modifiers))
    case "hotkey":
        let target = try cursor.pop()
        let (key, modifiers, anyWindow) = try parseBackgroundHotkey(cursor: &cursor)
        let wid = try resolveWindowTarget(target, anyWindow: anyWindow)
        try printJSON(pressKey(wid: wid, key: key, modifiers: modifiers))
    default:
        throw CUAError.usage("unknown background command: \(command)")
    }
}

func runForegroundAppSubcommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("foreground-app needs a command") }
    let command = try cursor.pop()
    let window = try frontmostWindow()
    switch command {
    case "info":
        var object = window.jsonObject
        if let app = appForPID(window.pid), let bundleID = app.bundleIdentifier {
            object["bundleID"] = bundleID
        }
        try printJSON(object)
    case "screenshot":
        let (output, format, quality) = try parseScreenshotOptions(cursor: &cursor)
        let path = output ?? inferredScreenshotPath(prefix: "front-window-\(window.wid)", format: format)
        try screenshot(wid: window.wid, path: path, format: format, quality: quality)
        print(path)
    case "click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(click(wid: window.wid, x: x, y: y, coord: coord))
    case "right-click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(rightClick(wid: window.wid, x: x, y: y, coord: coord))
    case "double-click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(doubleClick(wid: window.wid, x: x, y: y, coord: coord))
    case "drag":
        let x1 = try cursor.popDouble()
        let y1 = try cursor.popDouble()
        let x2 = try cursor.popDouble()
        let y2 = try cursor.popDouble()
        let (duration, steps, coord) = try parseDragOptions(cursor: &cursor)
        try printJSON(drag(wid: window.wid, x1: x1, y1: y1, x2: x2, y2: y2, coord: coord, steps: steps, duration: duration))
    case "scroll":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let dx = try cursor.popDouble()
        let dy = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(["via": scroll(wid: window.wid, x: x, y: y, dx: dx, dy: dy, coord: coord)])
    case "type":
        let text = try cursor.pop()
        let (at, replace, coord) = try parseTypeOptions(cursor: &cursor)
        try printJSON(["via": typeText(wid: window.wid, text: text, at: at, coord: coord, replace: replace)])
    case "press":
        let key = try cursor.pop()
        let modifiers = try parsePressModifiers(cursor: &cursor)
        try printJSON(pressKey(wid: window.wid, key: key, modifiers: modifiers))
    case "hotkey":
        let (key, modifiers) = try parseHotkey(cursor: &cursor)
        try printJSON(pressKey(wid: window.wid, key: key, modifiers: modifiers))
    default:
        throw CUAError.usage("unknown foreground-app command: \(command)")
    }
}

func runForegroundDesktopSubcommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("foreground-desktop needs a command") }
    let command = try cursor.pop()
    switch command {
    case "info":
        try printJSON(screenInfo())
    case "screenshot":
        let (output, format, quality) = try parseScreenshotOptions(cursor: &cursor)
        let path = output ?? inferredScreenshotPath(prefix: "screen-main", format: format)
        try screenshotDisplay(path: path, format: format, quality: quality)
        print(path)
    case "click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(clickGlobal(x: x, y: y, coord: coord))
    case "right-click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(rightClickGlobal(x: x, y: y, coord: coord))
    case "double-click":
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(doubleClickGlobal(x: x, y: y, coord: coord))
    case "drag":
        let x1 = try cursor.popDouble()
        let y1 = try cursor.popDouble()
        let x2 = try cursor.popDouble()
        let y2 = try cursor.popDouble()
        let (duration, steps, coord) = try parseDragOptions(cursor: &cursor)
        try printJSON(dragGlobal(x1: x1, y1: y1, x2: x2, y2: y2, coord: coord, steps: steps, duration: duration))
    case "scroll":
        _ = try cursor.popDouble() // x, kept for interface symmetry
        _ = try cursor.popDouble() // y, kept for interface symmetry
        let dx = try cursor.popDouble()
        let dy = try cursor.popDouble()
        _ = try cursor.parseCoord()
        try printJSON(scrollGlobal(dx: dx, dy: dy))
    case "type":
        let text = try cursor.pop()
        let (at, _, coord) = try parseTypeOptions(cursor: &cursor)
        try printJSON(try typeGlobal(text: text, at: at, coord: coord))
    case "press":
        let key = try cursor.pop()
        let modifiers = try parsePressModifiers(cursor: &cursor)
        try printJSON(pressGlobal(key: key, modifiers: modifiers))
    case "hotkey":
        let (key, modifiers) = try parseHotkey(cursor: &cursor)
        try printJSON(pressGlobal(key: key, modifiers: modifiers))
    default:
        throw CUAError.usage("unknown foreground-desktop command: \(command)")
    }
}
