import ApplicationServices
import CoreGraphics
import Foundation

func click(wid: CGWindowID, x: CGFloat, y: CGFloat, coord: CoordMode, hold: useconds_t = 50_000) throws -> [String: Any] {
    let (pid, app, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    let element = hitTest(app: app, x: point.x, y: point.y)
    let (plan, target, role) = planClick(element, point: point)

    switch plan {
    case .focusText:
        return ["plan": plan.rawValue, "role": role, "ok": axSet(target, kAXFocusedAttribute as CFString, true)]
    case .press:
        return ["plan": plan.rawValue, "role": role, "ok": axPress(target)]
    case .selectPress:
        let fresh = hitTest(app: app, x: point.x, y: point.y) ?? target
        return ["plan": plan.rawValue, "role": role, "ok": singleSelectRow(fresh)]
    case .selectRowAttribute:
        var row = hitTest(app: app, x: point.x, y: point.y) ?? target
        while row != nil && axRole(row) != "AXRow" {
            row = axParent(row)
        }
        if row == nil { row = target }
        var table = row
        while table != nil && !["AXTable", "AXOutline", "AXList"].contains(axRole(table)) {
            table = axParent(table)
        }
        var ok = false
        if let table, let row, isSettable(table, kAXSelectedRowsAttribute as CFString) {
            ok = axSet(table, kAXSelectedRowsAttribute as CFString, [row])
        }
        if !ok {
            ok = axSet(row, kAXSelectedAttribute as CFString, true)
        }
        return ["plan": plan.rawValue, "role": role, "ok": ok]
    case .cg:
        guardAndRestore(targetPID: pid) {
            cgMouseDown(pid: pid, point: point)
            usleep(hold)
            cgMouseUp(pid: pid, point: point)
        }
        return ["plan": plan.rawValue, "role": role, "ok": true]
    }
}

func rightClick(wid: CGWindowID, x: CGFloat, y: CGFloat, coord: CoordMode) throws -> [String: Any] {
    let (pid, _, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    guardAndRestore(targetPID: pid) {
        cgMouseDown(pid: pid, point: point, button: .right)
        usleep(50_000)
        cgMouseUp(pid: pid, point: point, button: .right)
    }
    return ["plan": "cg", "ok": true]
}

func doubleClick(wid: CGWindowID, x: CGFloat, y: CGFloat, coord: CoordMode) throws -> [String: Any] {
    _ = try click(wid: wid, x: x, y: y, coord: coord)
    usleep(80_000)
    _ = try click(wid: wid, x: x, y: y, coord: coord)
    return ["plan": "double", "ok": true]
}

func drag(wid: CGWindowID, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, coord: CoordMode, steps: Int, duration: Double) throws -> [String: Any] {
    let (pid, _, bounds) = try attach(wid)
    let start = toGlobal(bounds: bounds, x: x1, y: y1, coord: coord)
    let end = toGlobal(bounds: bounds, x: x2, y: y2, coord: coord)
    let count = max(steps, 1)
    guardAndRestore(targetPID: pid) {
        cgMouseDown(pid: pid, point: start)
        for i in 1...count {
            let t = CGFloat(i) / CGFloat(count)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            cgMove(pid: pid, point: point)
            usleep(useconds_t((duration / Double(count)) * 1_000_000))
        }
        cgMouseUp(pid: pid, point: end)
    }
    return ["ok": true]
}

func scroll(wid: CGWindowID, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, coord: CoordMode) throws -> String {
    let (pid, app, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    let element = hitTest(app: app, x: point.x, y: point.y)
    if tryAXScroll(element, dx: dx, dy: dy) {
        return "ax"
    }
    cgScroll(pid: pid, dx: dx, dy: dy)
    return "cg"
}

func typeText(wid: CGWindowID, text: String, at: (CGFloat, CGFloat)?, coord: CoordMode, replace: Bool) throws -> String {
    let (pid, app, bounds) = try attach(wid)
    var target: AXUIElement?
    if let at {
        let point = toGlobal(bounds: bounds, x: at.0, y: at.1, coord: coord)
        let element = hitTest(app: app, x: point.x, y: point.y)
        let (plan, targetElement, _) = planClick(element, point: point)
        if plan == .focusText {
            _ = axSet(targetElement, kAXFocusedAttribute as CFString, true)
            target = targetElement
        }
    }
    if target == nil,
       let focused = axGet(app, kAXFocusedUIElementAttribute as CFString) as! AXUIElement?,
       textRoles.contains(axRole(focused)) {
        target = focused
    }
    if let target {
        if replace {
            let before = axGet(target, kAXValueAttribute as CFString) as? String ?? ""
            var fullRange = CFRange(location: 0, length: before.count)
            if let rangeValue = AXValueCreate(.cfRange, &fullRange),
               axSet(target, kAXSelectedTextRangeAttribute as CFString, rangeValue),
               nsTypeText(pid: pid, wid: wid, text: text) {
                usleep(120_000)
                if (axGet(target, kAXValueAttribute as CFString) as? String ?? "") == text {
                    return "nsevent-selected"
                }
            }
            let current = axGet(target, kAXValueAttribute as CFString) as? String ?? ""
            var currentRange = CFRange(location: 0, length: current.count)
            if let rangeValue = AXValueCreate(.cfRange, &currentRange),
               axSet(target, kAXSelectedTextRangeAttribute as CFString, rangeValue),
               axSet(target, kAXSelectedTextAttribute as CFString, text),
               (axGet(target, kAXValueAttribute as CFString) as? String ?? "") == text {
                return "ax-selected"
            }
            if axSet(target, kAXValueAttribute as CFString, text) {
                return "ax"
            }
        }
        let before = axGet(target, kAXValueAttribute as CFString) as? String ?? ""
        if nsTypeText(pid: pid, wid: wid, text: text) {
            usleep(120_000)
            if (axGet(target, kAXValueAttribute as CFString) as? String ?? "") == before + text {
                return "nsevent"
            }
        }
        if axSet(target, kAXSelectedTextAttribute as CFString, text),
           (axGet(target, kAXValueAttribute as CFString) as? String ?? "") != before {
            return "ax"
        }
        if axSet(target, kAXValueAttribute as CFString, before + text) {
            return "ax"
        }
    }
    for character in text {
        guard let (code, needsShift) = keycodeForCharacter(character) else { continue }
        let flags: CGEventFlags = needsShift ? .maskShift : []
        cgKeyPress(pid: pid, keycode: code, flags: flags, hold: 3_000)
    }
    return "cg"
}

func pressKey(wid: CGWindowID, key: String, modifiers: [String]) throws -> [String: Any] {
    let (pid, app, _) = try attach(wid)
    if let result = pressFocusedTextField(app: app, key: key, modifiers: modifiers) {
        return result
    }

    var mods = modifiers
    var code = keyboard[key]
    if code == nil, key.count == 1, let result = keycodeForCharacter(Character(key)) {
        code = result.0
        if result.1 { mods.append("shift") }
    }
    guard let code else { throw CUAError.unknownKey(key) }
    let flags = flagsFor(mods)
    if nsKeyPress(pid: pid, wid: wid, keycode: code, key: key, modifiers: mods) {
        return ["ok": true, "via": "nsevent-cg"]
    }
    cgKeyPress(pid: pid, keycode: code, flags: flags)
    return ["ok": true, "via": "cg"]
}

func clickGlobal(x: CGFloat, y: CGFloat, coord: CoordMode, hold: useconds_t = 50_000) -> [String: Any] {
    let point = displayPoint(x: x, y: y, coord: coord)
    globalMouseEvent(.leftMouseDown, point: point, button: .left)
    usleep(hold)
    globalMouseEvent(.leftMouseUp, point: point, button: .left)
    return ["plan": "global", "ok": true]
}

func rightClickGlobal(x: CGFloat, y: CGFloat, coord: CoordMode) -> [String: Any] {
    let point = displayPoint(x: x, y: y, coord: coord)
    globalMouseEvent(.rightMouseDown, point: point, button: .right)
    usleep(50_000)
    globalMouseEvent(.rightMouseUp, point: point, button: .right)
    return ["plan": "global", "ok": true]
}

func doubleClickGlobal(x: CGFloat, y: CGFloat, coord: CoordMode) -> [String: Any] {
    _ = clickGlobal(x: x, y: y, coord: coord)
    usleep(80_000)
    _ = clickGlobal(x: x, y: y, coord: coord)
    return ["plan": "double", "ok": true]
}

func dragGlobal(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, coord: CoordMode, steps: Int, duration: Double) -> [String: Any] {
    let start = displayPoint(x: x1, y: y1, coord: coord)
    let end = displayPoint(x: x2, y: y2, coord: coord)
    let count = max(steps, 1)
    globalMouseEvent(.leftMouseDown, point: start, button: .left)
    for i in 1...count {
        let t = CGFloat(i) / CGFloat(count)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        globalMouseEvent(.leftMouseDragged, point: point, button: .left)
        usleep(useconds_t((duration / Double(count)) * 1_000_000))
    }
    globalMouseEvent(.leftMouseUp, point: end, button: .left)
    return ["ok": true]
}

func scrollGlobal(dx: CGFloat, dy: CGFloat) -> [String: Any] {
    globalScroll(dx: dx, dy: dy)
    return ["via": "cg"]
}

func typeGlobal(text: String, at: (CGFloat, CGFloat)?, coord: CoordMode) throws -> [String: Any] {
    if let at {
        _ = clickGlobal(x: at.0, y: at.1, coord: coord)
        usleep(80_000)
    }
    for character in text {
        guard let (code, needsShift) = keycodeForCharacter(character) else { continue }
        let flags: CGEventFlags = needsShift ? .maskShift : []
        globalKey(keycode: code, down: true, flags: flags)
        globalKey(keycode: code, down: false, flags: flags)
    }
    return ["via": "cg"]
}

func pressGlobal(key: String, modifiers: [String]) throws -> [String: Any] {
    var mods = modifiers
    var code = keyboard[key]
    if code == nil, key.count == 1, let result = keycodeForCharacter(Character(key)) {
        code = result.0
        if result.1 { mods.append("shift") }
    }
    guard let code else { throw CUAError.unknownKey(key) }
    let flags = flagsFor(mods)
    globalKey(keycode: code, down: true, flags: flags)
    globalKey(keycode: code, down: false, flags: flags)
    return ["ok": true]
}
