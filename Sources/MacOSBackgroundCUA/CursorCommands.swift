import Foundation

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
        var backgroundTarget: String?
        switch mode {
        case .background:
            backgroundTarget = try cursor.pop()
        case .foregroundApp, .foregroundDesktop:
            break
        }

        let x = Double(try cursor.popDouble())
        let y = Double(try cursor.popDouble())
        let (duration, overrideCoord, wait, anyWindow) = try parseBackgroundCursorMoveOptions(cursor: &cursor, defaultDuration: 0.0)
        let coord = overrideCoord ?? .pixel
        if let backgroundTarget {
            wid = Int(try resolveWindowTarget(backgroundTarget, anyWindow: anyWindow))
        }
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
        var backgroundTarget: String?
        switch mode {
        case .background:
            backgroundTarget = try cursor.pop()
        case .foregroundApp, .foregroundDesktop:
            state.wid = nil
        }
        let (duration, overrideCoord, wait, anyWindow) = try parseBackgroundCursorMoveOptions(cursor: &cursor, defaultDuration: 0.0)
        state.duration = duration
        if let overrideCoord { state.coord = overrideCoord.rawValue }
        if let backgroundTarget {
            state.wid = Int(try resolveWindowTarget(backgroundTarget, anyWindow: anyWindow))
        }
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
