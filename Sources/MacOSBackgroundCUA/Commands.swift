import CoreGraphics
import Foundation

func inferredScreenshotPath(prefix: String, format: String) -> String {
    "/tmp/\(prefix).\(format == "png" ? "png" : "jpg")"
}

func printCursorStatus() throws {
    let state = try readCursorState()
    let pid = readCursorPID()
    try printJSON([
        "running": pid.map(isProcessAlive) ?? false,
        "pid": pid.map(Int.init) ?? NSNull(),
        "mode": state.mode.rawValue,
        "wid": state.wid ?? NSNull(),
        "x": state.x,
        "y": state.y,
        "coord": state.coord,
        "duration": state.duration,
        "visible": state.visible
    ])
}

func runCursorCommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("cursor needs a command") }
    let command = try cursor.pop()
    switch command {
    case "start":
        guard !cursor.args.isEmpty else { throw CUAError.usage("cursor start needs a mode") }
        let rawMode = try cursor.pop()
        guard let mode = CursorTargetMode(rawValue: rawMode) else {
            throw CUAError.usage("unknown cursor mode: \(rawMode)")
        }

        var wid: Int?
        switch mode {
        case .background:
            wid = Int(try cursor.popWindowID())
        case .foregroundApp, .foregroundDesktop:
            break
        }

        let x = Double(try cursor.popDouble())
        let y = Double(try cursor.popDouble())
        let (duration, overrideCoord, wait) = try parseCursorMoveOptions(cursor: &cursor, defaultDuration: 0.0)
        let coord = overrideCoord ?? .pixel
        try writeCursorState(CursorState(
            mode: mode,
            wid: wid,
            x: x,
            y: y,
            coord: coord.rawValue,
            duration: duration,
            visible: true,
            updatedAt: Date().timeIntervalSince1970
        ))
        let pid = try spawnCursorDaemonIfNeeded()
        if wait, duration > 0 {
            usleep(useconds_t(duration * 1_000_000))
        }
        try printJSON(["ok": true, "pid": Int(pid), "mode": mode.rawValue, "wid": (wid as Any?) ?? NSNull()])
    case "move":
        var state = try readCursorState()
        state.x = Double(try cursor.popDouble())
        state.y = Double(try cursor.popDouble())
        let (duration, overrideCoord, wait) = try parseCursorMoveOptions(cursor: &cursor)
        state.duration = duration
        if let overrideCoord { state.coord = overrideCoord.rawValue }
        state.visible = true
        state.updatedAt = Date().timeIntervalSince1970
        try writeCursorState(state)
        if wait, duration > 0 {
            usleep(useconds_t(duration * 1_000_000))
        }
        try printJSON(["ok": true])
    case "retarget":
        var state = try readCursorState()
        guard !cursor.args.isEmpty else { throw CUAError.usage("cursor retarget needs a mode") }
        let rawMode = try cursor.pop()
        guard let mode = CursorTargetMode(rawValue: rawMode) else {
            throw CUAError.usage("unknown cursor mode: \(rawMode)")
        }
        state.mode = mode
        switch mode {
        case .background:
            state.wid = Int(try cursor.popWindowID())
        case .foregroundApp, .foregroundDesktop:
            state.wid = nil
        }
        let (duration, overrideCoord, wait) = try parseCursorMoveOptions(cursor: &cursor, defaultDuration: 0.0)
        state.duration = duration
        if let overrideCoord { state.coord = overrideCoord.rawValue }
        state.updatedAt = Date().timeIntervalSince1970
        try writeCursorState(state)
        if wait, duration > 0 {
            usleep(useconds_t(duration * 1_000_000))
        }
        try printJSON(["ok": true, "mode": state.mode.rawValue, "wid": (state.wid as Any?) ?? NSNull()])
    case "hide":
        var state = try readCursorState()
        state.visible = false
        state.updatedAt = Date().timeIntervalSince1970
        try writeCursorState(state)
        try printJSON(["ok": true])
    case "show":
        var state = try readCursorState()
        state.visible = true
        state.updatedAt = Date().timeIntervalSince1970
        try writeCursorState(state)
        try printJSON(["ok": true])
    case "click":
        let wait = try parseCursorClickOptions(cursor: &cursor)
        notifyCursorClickPulse()
        if wait {
            usleep(useconds_t((cursorClickPressDuration + cursorClickPulseDuration) * 1_000_000))
        }
        try printJSON(["ok": true])
    case "status":
        try printCursorStatus()
    case "stop":
        if let pid = readCursorPID(), isProcessAlive(pid) {
            if var state = try? readCursorState() {
                state.visible = false
                state.updatedAt = Date().timeIntervalSince1970
                try? writeCursorState(state)
            }
            notifyCursorStop()
            for _ in 0..<8 {
                usleep(50_000)
                if !isProcessAlive(pid) { break }
            }
            if isProcessAlive(pid) {
                kill(pid, SIGTERM)
                usleep(50_000)
            }
            if isProcessAlive(pid) {
                kill(pid, SIGKILL)
            }
            removeCursorSessionFiles()
        } else {
            removeCursorSessionFiles()
        }
        try printJSON(["ok": true])
    default:
        throw CUAError.usage("unknown cursor command: \(command)")
    }
}

func runBackgroundSubcommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("background needs a command") }
    let command = try cursor.pop()
    switch command {
    case "screenshot":
        let wid = try cursor.popWindowID()
        let (output, format, quality) = try parseScreenshotOptions(cursor: &cursor)
        let path = output ?? inferredScreenshotPath(prefix: "win-\(wid)", format: format)
        try screenshot(wid: wid, path: path, format: format, quality: quality)
        print(path)
    case "click":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(click(wid: wid, x: x, y: y, coord: coord))
    case "right-click":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(rightClick(wid: wid, x: x, y: y, coord: coord))
    case "double-click":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(doubleClick(wid: wid, x: x, y: y, coord: coord))
    case "drag":
        let wid = try cursor.popWindowID()
        let x1 = try cursor.popDouble()
        let y1 = try cursor.popDouble()
        let x2 = try cursor.popDouble()
        let y2 = try cursor.popDouble()
        let (duration, steps, coord) = try parseDragOptions(cursor: &cursor)
        try printJSON(drag(wid: wid, x1: x1, y1: y1, x2: x2, y2: y2, coord: coord, steps: steps, duration: duration))
    case "scroll":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let dx = try cursor.popDouble()
        let dy = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(["via": scroll(wid: wid, x: x, y: y, dx: dx, dy: dy, coord: coord)])
    case "type":
        let wid = try cursor.popWindowID()
        let text = try cursor.pop()
        let (at, replace, coord) = try parseTypeOptions(cursor: &cursor)
        try printJSON(["via": typeText(wid: wid, text: text, at: at, coord: coord, replace: replace)])
    case "ax-dump":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let coord = try cursor.parseCoord()
        try printJSON(axDump(wid: wid, x: x, y: y, coord: coord))
    case "ax-action":
        let wid = try cursor.popWindowID()
        let x = try cursor.popDouble()
        let y = try cursor.popDouble()
        let action = try cursor.pop()
        let coord = try cursor.parseCoord()
        try printJSON(axAction(wid: wid, x: x, y: y, action: action, coord: coord))
    case "press":
        let wid = try cursor.popWindowID()
        let key = try cursor.pop()
        let modifiers = try parsePressModifiers(cursor: &cursor)
        try printJSON(pressKey(wid: wid, key: key, modifiers: modifiers))
    case "hotkey":
        let wid = try cursor.popWindowID()
        guard cursor.args.count >= 1 else { throw CUAError.usage("hotkey needs at least one key") }
        let keys = cursor.args
        let key = keys.last!
        let modifiers = Array(keys.dropLast())
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
        guard cursor.args.count >= 1 else { throw CUAError.usage("hotkey needs at least one key") }
        let keys = cursor.args
        let key = keys.last!
        let modifiers = Array(keys.dropLast())
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
        guard cursor.args.count >= 1 else { throw CUAError.usage("hotkey needs at least one key") }
        let keys = cursor.args
        let key = keys.last!
        let modifiers = Array(keys.dropLast())
        try printJSON(pressGlobal(key: key, modifiers: modifiers))
    default:
        throw CUAError.usage("unknown foreground-desktop command: \(command)")
    }
}
