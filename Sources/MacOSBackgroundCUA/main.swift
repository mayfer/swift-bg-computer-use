import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CUAError: Error, CustomStringConvertible {
    case usage(String)
    case windowNotFound(CGWindowID)
    case screenshotFailed(CGWindowID)
    case imageWriteFailed(String)
    case unknownKey(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .windowNotFound(let id): return "window \(id) not found"
        case .screenshotFailed(let id): return "failed to capture window \(id)"
        case .imageWriteFailed(let path): return "failed to write image to \(path)"
        case .unknownKey(let key): return "unknown key: \(key)"
        }
    }
}

struct WindowInfo {
    let pid: pid_t
    let wid: CGWindowID
    let layer: Int
    let bounds: CGRect
    let owner: String
    let name: String

    var jsonObject: [String: Any] {
        [
            "pid": Int(pid),
            "wid": Int(wid),
            "width": Int(bounds.width),
            "height": Int(bounds.height),
            "owner": owner,
            "name": name
        ]
    }
}

struct AppFilter {
    var owner: String?
    var bundleID: String?
    var pid: pid_t?
}

func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func windowInfo(from dict: [String: Any]) -> WindowInfo? {
    guard
        let pidNumber = dict[kCGWindowOwnerPID as String] as? NSNumber,
        let widNumber = dict[kCGWindowNumber as String] as? NSNumber,
        let layerNumber = dict[kCGWindowLayer as String] as? NSNumber,
        let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
        let xNumber = boundsDict["X"] as? NSNumber,
        let yNumber = boundsDict["Y"] as? NSNumber,
        let widthNumber = boundsDict["Width"] as? NSNumber,
        let heightNumber = boundsDict["Height"] as? NSNumber
    else {
        return nil
    }

    return WindowInfo(
        pid: pidNumber.int32Value,
        wid: CGWindowID(widNumber.uint32Value),
        layer: layerNumber.intValue,
        bounds: CGRect(
            x: CGFloat(truncating: xNumber),
            y: CGFloat(truncating: yNumber),
            width: CGFloat(truncating: widthNumber),
            height: CGFloat(truncating: heightNumber)
        ),
        owner: dict[kCGWindowOwnerName as String] as? String ?? "",
        name: dict[kCGWindowName as String] as? String ?? ""
    )
}

func allWindows(options: CGWindowListOption = .optionOnScreenOnly) -> [WindowInfo] {
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return raw.compactMap(windowInfo)
}

func appMatches(_ app: NSRunningApplication, filter: AppFilter) -> Bool {
    if let pid = filter.pid, app.processIdentifier != pid { return false }
    if let owner = filter.owner {
        let name = app.localizedName ?? ""
        if name.range(of: owner, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
    }
    if let bundleID = filter.bundleID {
        if app.bundleIdentifier?.caseInsensitiveCompare(bundleID) != .orderedSame {
            return false
        }
    }
    return true
}

func appForPID(_ pid: pid_t) -> NSRunningApplication? {
    NSRunningApplication(processIdentifier: pid)
}

func listWindows(filter: AppFilter = AppFilter()) -> [[String: Any]] {
    allWindows().filter { window in
        guard window.layer == 0 else { return false }
        if filter.pid == nil, filter.owner == nil, filter.bundleID == nil { return true }
        guard let app = appForPID(window.pid) else { return false }
        return appMatches(app, filter: filter)
    }.map { window in
        var object = window.jsonObject
        if let app = appForPID(window.pid), let bundleID = app.bundleIdentifier {
            object["bundleID"] = bundleID
        }
        return object
    }
}

func listApps(runningOnly: Bool = false) -> [[String: Any]] {
    NSWorkspace.shared.runningApplications
        .filter { app in
            !runningOnly || !app.isTerminated
        }
        .sorted { lhs, rhs in
            let lhsActive = lhs.isActive ? 0 : 1
            let rhsActive = rhs.isActive ? 0 : 1
            if lhsActive != rhsActive { return lhsActive < rhsActive }
            return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? "") == .orderedAscending
        }
        .map { app in
            var object: [String: Any] = [
                "pid": Int(app.processIdentifier),
                "name": app.localizedName ?? "",
                "bundleID": app.bundleIdentifier ?? "",
                "running": !app.isTerminated,
                "active": app.isActive,
                "hidden": app.isHidden
            ]
            if let url = app.bundleURL {
                object["bundlePath"] = url.path
            }
            return object
        }
}

func getWindow(_ wid: CGWindowID) throws -> WindowInfo {
    let array = [NSNumber(value: wid)]
    if let raw = CGWindowListCreateDescriptionFromArray(array as CFArray) as? [[String: Any]],
       let window = raw.compactMap(windowInfo).first {
        return window
    }
    if let window = allWindows().first(where: { $0.wid == wid }) {
        return window
    }
    throw CUAError.windowNotFound(wid)
}

func axGet(_ element: AXUIElement?, _ attribute: CFString) -> Any? {
    guard let element else { return nil }
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
}

func axSet(_ element: AXUIElement?, _ attribute: CFString, _ value: Any) -> Bool {
    guard let element else { return false }
    return AXUIElementSetAttributeValue(element, attribute, value as CFTypeRef) == .success
}

func axActions(_ element: AXUIElement?) -> [String] {
    guard let element else { return [] }
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let names = names as? [String] else {
        return []
    }
    return names
}

func axPress(_ element: AXUIElement?) -> Bool {
    guard let element else { return false }
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

func axParent(_ element: AXUIElement?) -> AXUIElement? {
    axGet(element, kAXParentAttribute as CFString) as! AXUIElement?
}

func axRole(_ element: AXUIElement?) -> String {
    axGet(element, kAXRoleAttribute as CFString) as? String ?? ""
}

func isSettable(_ element: AXUIElement?, _ attribute: CFString) -> Bool {
    guard let element else { return false }
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
}

func hitTest(app: AXUIElement, x: CGFloat, y: CGFloat) -> AXUIElement? {
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &element)
    return error == .success ? element : nil
}

let pressableRoles: Set<String> = [
    "AXButton", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXLink",
    "AXPopUpButton", "AXComboBox", "AXSegmentedControl", "AXDisclosureTriangle", "AXToolbarButton"
]
let selectableRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText", "AXOutlineRow", "AXListItem"]
let textRoles: Set<String> = ["AXTextField", "AXTextArea"]

enum ClickPlan: String {
    case focusText = "focus_text"
    case press
    case selectPress = "select_press"
    case selectRowAttribute = "select_row_attr"
    case cg
}

func classify(_ element: AXUIElement?) -> (ClickPlan?, String) {
    let role = axRole(element)
    if textRoles.contains(role) { return (.focusText, role) }
    let actions = Set(axActions(element))
    if pressableRoles.contains(role), actions.contains(kAXPressAction) { return (.press, role) }
    if selectableRoles.contains(role), actions.contains(kAXPressAction) { return (.selectPress, role) }
    if role == "AXRow", isSettable(element, kAXSelectedAttribute as CFString) { return (.selectRowAttribute, role) }
    return (nil, role)
}

func isOpaqueAX(_ element: AXUIElement?) -> Bool {
    guard let element else { return true }
    let role = axRole(element)
    return role.isEmpty || role == "AXWindow" || role == "AXApplication"
}

func searchDescendants(_ element: AXUIElement?, maxDepth: Int = 3) -> (ClickPlan, AXUIElement, String)? {
    guard let element else { return nil }
    var queue: [(AXUIElement, Int)] = [(element, 0)]
    while !queue.isEmpty {
        let (current, depth) = queue.removeFirst()
        if depth > 0 {
            let (plan, role) = classify(current)
            if let plan { return (plan, current, role) }
        }
        if depth >= maxDepth { continue }
        let children = axGet(current, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for child in children {
            queue.append((child, depth + 1))
        }
    }
    return nil
}

func planClick(_ element: AXUIElement?) -> (ClickPlan, AXUIElement?, String) {
    guard let element else { return (.cg, nil, "") }
    let (directPlan, directRole) = classify(element)
    if let directPlan { return (directPlan, element, directRole) }
    if isOpaqueAX(element) { return (.cg, element, directRole) }

    var current = axParent(element)
    for _ in 0..<5 {
        guard let candidate = current else { break }
        let (plan, role) = classify(candidate)
        if let plan { return (plan, candidate, role) }
        current = axParent(candidate)
    }

    if let hit = searchDescendants(element) {
        return hit
    }
    return (.cg, element, directRole)
}

func singleSelectRow(_ element: AXUIElement?) -> Bool {
    guard let element else { return false }
    if let parent = axParent(element),
       let siblings = axGet(parent, kAXChildrenAttribute as CFString) as? [AXUIElement] {
        for sibling in siblings where sibling !== element {
            if (axGet(sibling, kAXSelectedAttribute as CFString) as? Bool) == true {
                _ = axPress(sibling)
                usleep(30_000)
            }
        }
    }
    if (axGet(element, kAXSelectedAttribute as CFString) as? Bool) == true {
        _ = axPress(element)
        usleep(50_000)
    }
    return axPress(element)
}

func scrollableAncestor(_ element: AXUIElement?, maxDepth: Int = 15) -> AXUIElement? {
    var current = element
    for _ in 0..<maxDepth {
        guard let candidate = current else { return nil }
        let actions = Set(axActions(candidate))
        if actions.contains("AXScrollDownByPage") || actions.contains("AXScrollUpByPage") ||
            actions.contains("AXScrollLeftByPage") || actions.contains("AXScrollRightByPage") {
            return candidate
        }
        if axGet(candidate, "AXVerticalScrollBar" as CFString) != nil ||
            axGet(candidate, "AXHorizontalScrollBar" as CFString) != nil {
            return candidate
        }
        current = axParent(candidate)
    }
    return nil
}

func tryAXScroll(_ element: AXUIElement?, dx: CGFloat, dy: CGFloat) -> Bool {
    guard let scrollElement = scrollableAncestor(element) else { return false }
    let actions = Set(axActions(scrollElement))
    var did = false
    if dy != 0 {
        let action = dy > 0 ? "AXScrollDownByPage" : "AXScrollUpByPage"
        if actions.contains(action), AXUIElementPerformAction(scrollElement, action as CFString) == .success {
            did = true
        }
    }
    if dx != 0 {
        let action = dx > 0 ? "AXScrollRightByPage" : "AXScrollLeftByPage"
        if actions.contains(action), AXUIElementPerformAction(scrollElement, action as CFString) == .success {
            did = true
        }
    }
    return did
}

func attach(_ wid: CGWindowID) throws -> (pid_t, AXUIElement, CGRect) {
    let window = try getWindow(wid)
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(app, 2.0)
    _ = axSet(app, "AXEnhancedUserInterface" as CFString, true)
    _ = axSet(app, "AXManualAccessibility" as CFString, true)
    return (window.pid, app, window.bounds)
}

enum CoordMode: String {
    case pixel
    case normalized
    case global
}

enum ModeCommand: String {
    case screenshot
    case click
    case rightClick = "right-click"
    case doubleClick = "double-click"
    case drag
    case scroll
    case type
    case press
    case hotkey
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

func frontmostApp() throws -> NSRunningApplication {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        throw CUAError.usage("no frontmost application")
    }
    return app
}

func axWindowBounds(_ window: AXUIElement?) -> CGRect? {
    guard let window,
          let positionValue = axGet(window, kAXPositionAttribute as CFString) as! AXValue?,
          let sizeValue = axGet(window, kAXSizeAttribute as CFString) as! AXValue? else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &position),
          AXValueGetValue(sizeValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

func rectDistanceSquared(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let dx = lhs.origin.x - rhs.origin.x
    let dy = lhs.origin.y - rhs.origin.y
    let dw = lhs.size.width - rhs.size.width
    let dh = lhs.size.height - rhs.size.height
    return dx * dx + dy * dy + dw * dw + dh * dh
}

func frontmostWindow() throws -> WindowInfo {
    let app = try frontmostApp()
    let pid = app.processIdentifier
    let appAX = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appAX, 2.0)

    let focusedWindow = axGet(appAX, kAXFocusedWindowAttribute as CFString) as! AXUIElement?
    let mainWindow = axGet(appAX, kAXMainWindowAttribute as CFString) as! AXUIElement?
    let targetBounds = axWindowBounds(focusedWindow) ?? axWindowBounds(mainWindow)

    let candidates = allWindows().filter { $0.layer == 0 && $0.pid == pid }
    guard !candidates.isEmpty else {
        throw CUAError.usage("no layer-0 window found for frontmost app \(app.localizedName ?? "")")
    }

    if let targetBounds {
        if let exact = candidates.min(by: { rectDistanceSquared($0.bounds, targetBounds) < rectDistanceSquared($1.bounds, targetBounds) }) {
            return exact
        }
    }

    return candidates[0]
}

func frontmostPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func guardAndRestore(targetPID: pid_t, work: () -> Void) {
    let previous = frontmostPID()
    let stealPossible = previous != nil && previous != targetPID
    work()
    guard stealPossible, let previous else { return }
    usleep(120_000)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
       let previousApp = NSRunningApplication(processIdentifier: previous),
       !previousApp.isTerminated {
        previousApp.activate(options: [.activateIgnoringOtherApps])
    }
}

func mouseEvent(_ type: CGEventType, point: CGPoint, button: CGMouseButton) -> CGEvent? {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
}

func globalMouseEvent(_ type: CGEventType, point: CGPoint, button: CGMouseButton) {
    mouseEvent(type, point: point, button: button)?.post(tap: .cghidEventTap)
}

func globalScroll(dx: CGFloat, dy: CGFloat) {
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
}

func cgMouseDown(pid: pid_t, point: CGPoint, button: CGMouseButton = .left) {
    let type: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    mouseEvent(type, point: point, button: button)?.postToPid(pid)
}

func cgMouseUp(pid: pid_t, point: CGPoint, button: CGMouseButton = .left) {
    let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    mouseEvent(type, point: point, button: button)?.postToPid(pid)
}

func cgMove(pid: pid_t, point: CGPoint) {
    mouseEvent(.mouseMoved, point: point, button: .left)?.postToPid(pid)
}

func cgScroll(pid: pid_t, dx: CGFloat, dy: CGFloat) {
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.postToPid(pid)
}

func cgKey(pid: pid_t, keycode: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { return }
    event.flags = flags
    event.postToPid(pid)
}

func globalKey(keycode: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func writeImage(_ image: CGImage, path: String, format: String, quality: CGFloat) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    let data: Data?
    if format == "png" {
        data = rep.representation(using: .png, properties: [:])
    } else {
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
    guard let data else {
        throw CUAError.imageWriteFailed(path)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        throw CUAError.imageWriteFailed(path)
    }
}

func screenshotDisplay(path: String, format: String, quality: CGFloat) throws {
    guard let image = CGWindowListCreateImage(
        mainDisplayBounds(),
        .optionOnScreenOnly,
        kCGNullWindowID,
        [.boundsIgnoreFraming, .nominalResolution]
    ) else {
        throw CUAError.imageWriteFailed(path)
    }
    try writeImage(image, path: path, format: format, quality: quality)
}

func screenshot(wid: CGWindowID, path: String, format: String, quality: CGFloat) throws {
    let window = try getWindow(wid)
    guard let image = CGWindowListCreateImage(
        window.bounds,
        .optionIncludingWindow,
        wid,
        [.boundsIgnoreFraming, .nominalResolution]
    ) else {
        throw CUAError.screenshotFailed(wid)
    }
    try writeImage(image, path: path, format: format, quality: quality)
}

func click(wid: CGWindowID, x: CGFloat, y: CGFloat, coord: CoordMode, hold: useconds_t = 50_000) throws -> [String: Any] {
    let (pid, app, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    let element = hitTest(app: app, x: point.x, y: point.y)
    let (plan, target, role) = planClick(element)

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

let keyboard: [String: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "-": 27, "=": 24, "`": 50, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42,
    "Tab": 48, " ": 49, "Space": 49, "Enter": 36, "Return": 36, "Backspace": 51, "Delete": 51,
    "ForwardDelete": 117, "ArrowUp": 126, "ArrowDown": 125, "ArrowLeft": 123, "ArrowRight": 124,
    "Up": 126, "Down": 125, "Left": 123, "Right": 124, "Escape": 53, "Esc": 53,
    "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
    "F9": 101, "F10": 109, "F11": 103, "F12": 111
]

let shifted: [Character: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0", "_": "-", "+": "=", "~": "`", "{": "[", "}": "]", ":": ";",
    "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\"
]

let modifierFlags: [String: CGEventFlags] = [
    "shift": .maskShift,
    "cmd": .maskCommand,
    "command": .maskCommand,
    "alt": .maskAlternate,
    "option": .maskAlternate,
    "opt": .maskAlternate,
    "ctrl": .maskControl,
    "control": .maskControl,
    "fn": .maskSecondaryFn
]

func keycodeForCharacter(_ character: Character) -> (CGKeyCode, Bool)? {
    let string = String(character)
    if string.lowercased() != string, let code = keyboard[string.lowercased()] {
        return (code, true)
    }
    if let base = shifted[character], let code = keyboard[base] {
        return (code, true)
    }
    if let code = keyboard[string] {
        return (code, false)
    }
    return nil
}

func flagsFor(_ modifiers: [String]) -> CGEventFlags {
    modifiers.reduce(CGEventFlags()) { partial, modifier in
        partial.union(modifierFlags[modifier.lowercased()] ?? [])
    }
}

func displayPoint(x: CGFloat, y: CGFloat, coord: CoordMode) -> CGPoint {
    toGlobal(bounds: mainDisplayBounds(), x: x, y: y, coord: coord)
}

func typeText(wid: CGWindowID, text: String, at: (CGFloat, CGFloat)?, coord: CoordMode, replace: Bool) throws -> String {
    let (pid, app, bounds) = try attach(wid)
    var target: AXUIElement?
    if let at {
        let point = toGlobal(bounds: bounds, x: at.0, y: at.1, coord: coord)
        let element = hitTest(app: app, x: point.x, y: point.y)
        let (plan, targetElement, _) = planClick(element)
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
        if replace, axSet(target, kAXValueAttribute as CFString, text) {
            return "ax"
        }
        let before = axGet(target, kAXValueAttribute as CFString) as? String ?? ""
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
        cgKey(pid: pid, keycode: code, down: true, flags: flags)
        cgKey(pid: pid, keycode: code, down: false, flags: flags)
    }
    return "cg"
}

func performFirstAvailableAction(_ element: AXUIElement?, _ candidates: [String]) -> String? {
    guard let element else { return nil }
    let available = Set(axActions(element))
    for action in candidates where available.contains(action) {
        if AXUIElementPerformAction(element, action as CFString) == .success {
            return action
        }
    }
    return nil
}

func pressFocusedTextField(app: AXUIElement, key: String, modifiers: [String]) -> [String: Any]? {
    guard modifiers.isEmpty,
          ["Enter", "Return", "KP_Enter"].contains(key),
          let focused = axGet(app, kAXFocusedUIElementAttribute as CFString) as! AXUIElement?,
          textRoles.contains(axRole(focused)) else {
        return nil
    }

    if let action = performFirstAvailableAction(focused, ["AXConfirm"]) {
        return ["ok": true, "via": "ax", "action": action]
    }

    return nil
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
    cgKey(pid: pid, keycode: code, down: true, flags: flags)
    cgKey(pid: pid, keycode: code, down: false, flags: flags)
    return ["ok": true]
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

struct ArgumentCursor {
    var args: [String]

    mutating func pop() throws -> String {
        guard !args.isEmpty else { throw CUAError.usage("missing argument") }
        return args.removeFirst()
    }

    mutating func popDouble() throws -> CGFloat {
        let raw = try pop()
        guard let value = Double(raw) else { throw CUAError.usage("expected number, got \(raw)") }
        return CGFloat(value)
    }

    mutating func popInt() throws -> Int {
        let raw = try pop()
        guard let value = Int(raw) else { throw CUAError.usage("expected integer, got \(raw)") }
        return value
    }

    mutating func popWindowID() throws -> CGWindowID {
        CGWindowID(try popInt())
    }

    mutating func parseCoord() throws -> CoordMode {
        var coord = CoordMode.pixel
        var rest: [String] = []
        while !args.isEmpty {
            let item = try pop()
            if item == "--coord" {
                let raw = try pop()
                guard let parsed = CoordMode(rawValue: raw) else {
                    throw CUAError.usage("unknown coord mode: \(raw)")
                }
                coord = parsed
            } else {
                rest.append(item)
            }
        }
        args = rest
        return coord
    }
}

func parseScreenshotOptions(cursor: inout ArgumentCursor) throws -> (String?, String, CGFloat) {
    var output: String?
    var format = "jpeg"
    var quality: CGFloat = 0.8
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        switch arg {
        case "-o", "--out":
            output = try cursor.pop()
        case "--png":
            format = "png"
        case "--quality":
            quality = CGFloat(try cursor.popDouble())
        default:
            throw CUAError.usage("unknown screenshot option: \(arg)")
        }
    }
    return (output, format, quality)
}

func parseTypeOptions(cursor: inout ArgumentCursor) throws -> ((CGFloat, CGFloat)?, Bool, CoordMode) {
    var at: (CGFloat, CGFloat)?
    var replace = false
    var coord = CoordMode.pixel
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        switch arg {
        case "--at":
            at = (try cursor.popDouble(), try cursor.popDouble())
        case "--replace":
            replace = true
        case "--coord":
            let raw = try cursor.pop()
            guard let parsed = CoordMode(rawValue: raw) else { throw CUAError.usage("unknown coord mode: \(raw)") }
            coord = parsed
        default:
            throw CUAError.usage("unknown type option: \(arg)")
        }
    }
    return (at, replace, coord)
}

func parseDragOptions(cursor: inout ArgumentCursor) throws -> (Double, Int, CoordMode) {
    var duration = 0.3
    var steps = 20
    var coord = CoordMode.pixel
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        switch arg {
        case "--duration":
            duration = Double(try cursor.popDouble())
        case "--steps":
            steps = try cursor.popInt()
        case "--coord":
            let raw = try cursor.pop()
            guard let parsed = CoordMode(rawValue: raw) else { throw CUAError.usage("unknown coord mode: \(raw)") }
            coord = parsed
        default:
            throw CUAError.usage("unknown drag option: \(arg)")
        }
    }
    return (duration, steps, coord)
}

func parsePressModifiers(cursor: inout ArgumentCursor) throws -> [String] {
    var modifiers: [String] = []
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        guard arg == "--mod" else { throw CUAError.usage("unknown press option: \(arg)") }
        modifiers.append(try cursor.pop())
    }
    return modifiers
}

func inferredScreenshotPath(prefix: String, format: String) -> String {
    "/tmp/\(prefix).\(format == "png" ? "png" : "jpg")"
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

func usage() -> String {
    """
    macos-bg-cua: background macOS window control for coding agents

    This tool lets an agent inspect and operate a target app window without
    activating it, or operate the frontmost app / desktop in foreground modes.
    Start with list-apps or list-windows, capture a screenshot, inspect the
    saved image, then act using coordinates from that image.

    usage:
      macos-bg-cua list-apps
      macos-bg-cua list-windows
      macos-bg-cua list-windows [--app NAME] [--bundle-id ID] [--pid PID]
      macos-bg-cua active-window
      macos-bg-cua background <command> ...
      macos-bg-cua foreground-app <command> ...
      macos-bg-cua foreground-desktop <command> ...
      macos-bg-cua screenshot <wid> [-o path] [--png] [--quality 0.8]
      macos-bg-cua click <wid> <x> <y> [--coord pixel|normalized|global]
      macos-bg-cua right-click <wid> <x> <y> [--coord pixel|normalized|global]
      macos-bg-cua double-click <wid> <x> <y> [--coord pixel|normalized|global]
      macos-bg-cua drag <wid> <x1> <y1> <x2> <y2> [--duration 0.3] [--steps 20] [--coord pixel|normalized|global]
      macos-bg-cua scroll <wid> <x> <y> <dx> <dy> [--coord pixel|normalized|global]
      macos-bg-cua type <wid> <text> [--at X Y] [--replace] [--coord pixel|normalized|global]
      macos-bg-cua press <wid> <key> [--mod cmd]...
      macos-bg-cua hotkey <wid> <mod>... <key>

    agent loop:
      1. Run list-apps if you need a bundle id or pid.
      2. Run list-windows, optionally filtered by --app/--bundle-id/--pid,
         and choose a wid.
      3. Run screenshot <wid> --png -o /tmp/window.png.
      4. Inspect the actual image dimensions, or use width/height from
         list-windows. Those dimensions are the coordinate frame.
      5. Click/type/drag/scroll with x,y measured from the screenshot's top-left.

    modes:
      background         Operate a specific window id (wid). Coordinates are
                         window-local. This is the original mode.
      foreground-app     Operate the frontmost app window. Screenshots are
                         cropped to the active window bounds, excluding shadow.
                         Coordinates are window-local unless --coord global.
      foreground-desktop Operate the main display. Screenshots are full-screen.
                         Coordinates are display-local pixels or normalized.
                         Use `info` to get width/height for the current screen.

    coordinate modes:
      pixel       Default. x,y are window-local screenshot pixels, top-left
                  origin. If the screenshot is 1200x800, its bottom-right is
                  approximately x=1199,y=799. This is the safest mode for GPT
                  agents because it matches the captured image bytes.
      normalized  x,y are fractions of the window size from 0.0 to 1.0. Use this
                  only when reasoning proportionally across changing window sizes.
      global      x,y are macOS global screen coordinates. Use only when you
                  already have absolute display coordinates.

    image and coordinate warning:
      Do not use coordinates from a downscaled preview in a chat UI or image
      viewer. Viewers often display the screenshot smaller than its real pixel
      size. Convert proportionally back to the real screenshot/list-windows size.
      Example: a target that appears 25% across and 40% down in any preview of a
      1000x700 window should be clicked at x=250,y=280.

    command behavior:
      list-apps      Prints JSON running apps: pid,name,bundleID,running,active,
                     hidden,bundlePath. This is for discovering bundle IDs/PIDs.
      list-windows   Prints JSON windows: pid,wid,width,height,owner,name.
                     Only normal layer-0 app windows are listed. Add filters to
                     get windows for a specific app.
      active-window  Prints JSON for the frontmost app's current layer-0 window.
      foreground-app info
                     Prints JSON for the current frontmost app window.
      foreground-desktop info
                     Prints JSON for the main display bounds.
      screenshot     Saves a window image and prints the output path, not JSON.
                     Works for occluded/background windows when Screen Recording
                     permission is granted.
      click          Tries Accessibility first: AXPress, text focus, row select.
                     Falls back to CGEventPostToPid for canvas/opaque areas.
                     Prints {"plan","role","ok"} so agents can see the route.
      right-click    Uses PID-targeted CG events.
      double-click   Sends two clicks at the same coordinate.
      drag           Sends interpolated PID-targeted mouse events.
      scroll         Tries AX page scroll first, then CG wheel. Positive dy means
                     scroll down; positive dx means scroll right. Prints {"via"}.
      type           With --at X Y, first targets that point. AX text insertion is
                     preferred because it handles Unicode and does not depend on
                     keyboard layout. Falls back to ASCII CG keystrokes.
      press/hotkey   Sends US-keyboard virtual-key events to the target PID.

    permissions:
      Accessibility is required for AX actions and most input reliability.
      Screen Recording is required for screenshots. Grant permissions to the
      launching terminal/app or to the compiled binary.

    examples:
      macos-bg-cua list-apps
      macos-bg-cua list-windows
      macos-bg-cua list-windows --bundle-id net.imput.helium
      macos-bg-cua list-windows --app Helium
      macos-bg-cua active-window
      macos-bg-cua screenshot 12345 --png -o /tmp/app.png
      macos-bg-cua foreground-app screenshot --png -o /tmp/front.png
      macos-bg-cua foreground-desktop screenshot --png -o /tmp/screen.png
      macos-bg-cua foreground-app click 240 180
      macos-bg-cua foreground-desktop click 240 180
      macos-bg-cua click 12345 240 180
      macos-bg-cua click 12345 0.25 0.40 --coord normalized
      macos-bg-cua double-click 12345 410 300
      macos-bg-cua right-click 12345 410 300
      macos-bg-cua drag 12345 120 400 500 400 --duration 0.5 --steps 30
      macos-bg-cua scroll 12345 600 500 0 700
      macos-bg-cua scroll 12345 600 500 0 -700
      macos-bg-cua type 12345 "hello world" --at 320 740
      macos-bg-cua press 12345 Enter
      macos-bg-cua press 12345 ArrowDown
      macos-bg-cua press 12345 c --mod cmd
      macos-bg-cua press 12345 p --mod cmd --mod shift
      macos-bg-cua hotkey 12345 cmd c
      macos-bg-cua hotkey 12345 cmd v
      macos-bg-cua hotkey 12345 cmd shift p
      macos-bg-cua hotkey 12345 cmd alt Escape
    """
}

func run(_ arguments: [String]) throws {
    var cursor = ArgumentCursor(args: Array(arguments.dropFirst()))
    guard !cursor.args.isEmpty else { throw CUAError.usage(usage()) }
    let command = try cursor.pop()

    switch command {
    case "help", "--help", "-h":
        print(usage())
    case "active-window":
        try printJSON(listWindows(filter: AppFilter(pid: try frontmostApp().processIdentifier)).first ?? frontmostWindow().jsonObject)
    case "background":
        try runBackgroundSubcommand(cursor: &cursor)
    case "foreground-app":
        try runForegroundAppSubcommand(cursor: &cursor)
    case "foreground-desktop":
        try runForegroundDesktopSubcommand(cursor: &cursor)
    case "list-apps":
        var runningOnly = false
        while !cursor.args.isEmpty {
            let arg = try cursor.pop()
            switch arg {
            case "--running-only":
                runningOnly = true
            default:
                throw CUAError.usage("unknown list-apps option: \(arg)")
            }
        }
        try printJSON(listApps(runningOnly: runningOnly))
    case "list-windows":
        var filter = AppFilter()
        while !cursor.args.isEmpty {
            let arg = try cursor.pop()
            switch arg {
            case "--app", "--owner":
                filter.owner = try cursor.pop()
            case "--bundle-id":
                filter.bundleID = try cursor.pop()
            case "--pid":
                filter.pid = pid_t(try cursor.popInt())
            default:
                throw CUAError.usage("unknown list-windows option: \(arg)")
            }
        }
        try printJSON(listWindows(filter: filter))
    case "screenshot":
        cursor.args.insert(command, at: 0)
        try runBackgroundSubcommand(cursor: &cursor)
    case "click", "right-click", "double-click", "drag", "scroll", "type", "press", "hotkey":
        cursor.args.insert(command, at: 0)
        try runBackgroundSubcommand(cursor: &cursor)
    default:
        throw CUAError.usage("unknown command: \(command)\n\(usage())")
    }
}

do {
    try run(CommandLine.arguments)
} catch let error as CUAError {
    fputs("error: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
