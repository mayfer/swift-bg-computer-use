import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

enum CUAError: Error, CustomStringConvertible {
    case usage(String)
    case windowNotFound(CGWindowID)
    case screenshotFailed(CGWindowID)
    case imageWriteFailed(String)
    case unknownKey(String)
    case cursorStateUnavailable(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .windowNotFound(let id): return "window \(id) not found"
        case .screenshotFailed(let id): return "failed to capture window \(id)"
        case .imageWriteFailed(let path): return "failed to write image to \(path)"
        case .unknownKey(let key): return "unknown key: \(key)"
        case .cursorStateUnavailable(let detail): return detail
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

func axBounds(_ element: AXUIElement?) -> CGRect? {
    guard let element,
          let positionValue = axGet(element, kAXPositionAttribute as CFString) as! AXValue?,
          let sizeValue = axGet(element, kAXSizeAttribute as CFString) as! AXValue? else {
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

func axRole(_ element: AXUIElement?) -> String {
    axGet(element, kAXRoleAttribute as CFString) as? String ?? ""
}

func isSettable(_ element: AXUIElement?, _ attribute: CFString) -> Bool {
    guard let element else { return false }
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
}

func axAttributeNames(_ element: AXUIElement?) -> [String] {
    guard let element else { return [] }
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
          let names = names as? [String] else {
        return []
    }
    return names
}

func axParameterizedAttributeNames(_ element: AXUIElement?) -> [String] {
    guard let element else { return [] }
    var names: CFArray?
    guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
          let names = names as? [String] else {
        return []
    }
    return names
}

func axDebugValue(_ value: Any?) -> Any? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number }
    if let array = value as? [Any] { return array.prefix(12).compactMap(axDebugValue) }
    if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
        return compactAXInfo((value as! AXUIElement))
    }
    if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(axValue, .cgPoint, &point)
            return ["x": point.x, "y": point.y]
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(axValue, .cgSize, &size)
            return ["width": size.width, "height": size.height]
        case .cgRect:
            var rect = CGRect.zero
            AXValueGetValue(axValue, .cgRect, &rect)
            return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        case .cfRange:
            var range = CFRange()
            AXValueGetValue(axValue, .cfRange, &range)
            return ["location": range.location, "length": range.length]
        case .axError, .illegal:
            return String(describing: value)
        @unknown default:
            return String(describing: value)
        }
    }
    return String(describing: value)
}

func compactAXInfo(_ element: AXUIElement?) -> [String: Any] {
    guard let element else { return [:] }
    let interestingAttributes: [CFString] = [
        kAXRoleAttribute as CFString,
        kAXSubroleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXSelectedTextAttribute as CFString,
        kAXSelectedTextRangeAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        "AXPlaceholderValue" as CFString,
        "AXDOMIdentifier" as CFString,
        kAXFocusedAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXSelectedAttribute as CFString
    ]
    var object: [String: Any] = [:]
    for attribute in interestingAttributes {
        if let value = axDebugValue(axGet(element, attribute)) {
            object[attribute as String] = value
        }
    }
    if let bounds = axBounds(element) {
        object["bounds"] = ["x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height]
    }
    object["actions"] = axActions(element)
    object["settable"] = axAttributeNames(element).filter { isSettable(element, $0 as CFString) }
    object["parameterized"] = axParameterizedAttributeNames(element)
    return object
}

func axAncestorChain(_ element: AXUIElement?, maxDepth: Int = 8) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var current = element
    for _ in 0..<maxDepth {
        guard let candidate = current else { break }
        result.append(compactAXInfo(candidate))
        current = axParent(candidate)
    }
    return result
}

func axChildrenSummary(_ element: AXUIElement?, maxDepth: Int = 3, maxItems: Int = 80) -> [[String: Any]] {
    guard let element else { return [] }
    var result: [[String: Any]] = []
    var queue: [(AXUIElement, Int)] = [(element, 0)]
    while !queue.isEmpty, result.count < maxItems {
        let (current, depth) = queue.removeFirst()
        if depth > 0 {
            var info = compactAXInfo(current)
            info["depth"] = depth
            result.append(info)
        }
        if depth >= maxDepth { continue }
        let children = axGet(current, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for child in children {
            queue.append((child, depth + 1))
        }
    }
    return result
}

func axDump(wid: CGWindowID, x: CGFloat, y: CGFloat, coord: CoordMode) throws -> [String: Any] {
    let (_, app, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    let hit = hitTest(app: app, x: point.x, y: point.y)
    let (plan, target, role) = planClick(hit, point: point)
    let focused = axGet(app, kAXFocusedUIElementAttribute as CFString) as! AXUIElement?
    return [
        "window": Int(wid),
        "point": ["x": point.x, "y": point.y],
        "hit": compactAXInfo(hit),
        "plan": ["name": plan.rawValue, "role": role],
        "target": compactAXInfo(target),
        "targetAncestors": axAncestorChain(target),
        "focused": compactAXInfo(focused),
        "focusedAncestors": axAncestorChain(focused),
        "appChildren": axChildrenSummary(app, maxDepth: 2, maxItems: 80)
    ]
}

func axAction(wid: CGWindowID, x: CGFloat, y: CGFloat, action: String, coord: CoordMode) throws -> [String: Any] {
    let (_, app, bounds) = try attach(wid)
    let point = toGlobal(bounds: bounds, x: x, y: y, coord: coord)
    let hit = hitTest(app: app, x: point.x, y: point.y)
    let (plan, target, role) = planClick(hit, point: point)
    let ok = target.map { AXUIElementPerformAction($0, action as CFString) == .success } ?? false
    return [
        "ok": ok,
        "action": action,
        "plan": plan.rawValue,
        "role": role,
        "target": compactAXInfo(target)
    ]
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

func searchDescendantsContainingPoint(_ element: AXUIElement?, point: CGPoint, maxDepth: Int = 6) -> (ClickPlan, AXUIElement, String)? {
    guard let element else { return nil }

    func visit(_ current: AXUIElement, depth: Int) -> (ClickPlan, AXUIElement, String)? {
        guard depth <= maxDepth else { return nil }

        let children = axGet(current, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for child in children.reversed() {
            if let bounds = axBounds(child), bounds.contains(point),
               let hit = visit(child, depth: depth + 1) {
                return hit
            }
        }

        let (plan, role) = classify(current)
        if let plan,
           let bounds = axBounds(current),
           bounds.contains(point) {
            return (plan, current, role)
        }
        return nil
    }

    return visit(element, depth: 0)
}

func planClick(_ element: AXUIElement?, point: CGPoint? = nil) -> (ClickPlan, AXUIElement?, String) {
    guard let element else { return (.cg, nil, "") }
    let (directPlan, directRole) = classify(element)
    if let directPlan { return (directPlan, element, directRole) }
    if isOpaqueAX(element) { return (.cg, element, directRole) }

    var current = axParent(element)
    for _ in 0..<5 {
        guard let candidate = current else { break }
        let (plan, role) = classify(candidate)
        if let plan { return (plan, candidate, role) }
        if let point,
           let hit = searchDescendantsContainingPoint(candidate, point: point) {
            return hit
        }
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

enum CursorTargetMode: String, Codable {
    case background
    case foregroundApp = "foreground-app"
    case foregroundDesktop = "foreground-desktop"
}

struct CursorState: Codable, Equatable {
    var mode: CursorTargetMode
    var wid: Int?
    var x: Double
    var y: Double
    var coord: String
    var duration: Double
    var visible: Bool
    var updatedAt: Double
}

let cursorSessionDirectory = "/tmp/macos-bg-cua-cursor"
let cursorStatePath = "\(cursorSessionDirectory)/state.json"
let cursorPIDPath = "\(cursorSessionDirectory)/pid"
let cursorReadyPath = "\(cursorSessionDirectory)/ready"
let cursorVisibilityAnimationDuration = 0.12
let cursorClickPressDuration = 0.05
let cursorClickPulseDuration = 0.22

func ensureCursorSessionDirectory() throws {
    try FileManager.default.createDirectory(atPath: cursorSessionDirectory, withIntermediateDirectories: true)
}

func atomicWrite(_ data: Data, to path: String) throws {
    let temp = "\(path).tmp.\(UUID().uuidString)"
    try data.write(to: URL(fileURLWithPath: temp))
    _ = try? FileManager.default.removeItem(atPath: path)
    try FileManager.default.moveItem(atPath: temp, toPath: path)
}

func writeCursorState(_ state: CursorState) throws {
    try ensureCursorSessionDirectory()
    let data = try JSONEncoder().encode(state)
    try atomicWrite(data, to: cursorStatePath)
}

func readCursorState() throws -> CursorState {
    let data = try Data(contentsOf: URL(fileURLWithPath: cursorStatePath))
    return try JSONDecoder().decode(CursorState.self, from: data)
}

func writeCursorPID(_ pid: Int32) throws {
    try ensureCursorSessionDirectory()
    try atomicWrite(Data(String(pid).utf8), to: cursorPIDPath)
}

func writeCursorReady() throws {
    try ensureCursorSessionDirectory()
    try atomicWrite(Data("ready".utf8), to: cursorReadyPath)
}

func isCursorReady() -> Bool {
    FileManager.default.fileExists(atPath: cursorReadyPath)
}

func readCursorPID() -> Int32? {
    guard let raw = try? String(contentsOfFile: cursorPIDPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = Int32(raw) else {
        return nil
    }
    return pid
}

func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0
}

func removeCursorSessionFiles() {
    try? FileManager.default.removeItem(atPath: cursorStatePath)
    try? FileManager.default.removeItem(atPath: cursorPIDPath)
    try? FileManager.default.removeItem(atPath: cursorReadyPath)
}

func currentExecutablePath() -> String {
    let path = CommandLine.arguments[0]
    if path.hasPrefix("/") { return path }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path).path
}

func spawnCursorDaemonIfNeeded() throws -> Int32 {
    if let pid = readCursorPID(), isProcessAlive(pid) {
        return pid
    }
    try? FileManager.default.removeItem(atPath: cursorReadyPath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: currentExecutablePath())
    process.arguments = ["cursor-daemon"]
    let null = FileHandle(forWritingAtPath: "/dev/null")
    process.standardOutput = null
    process.standardError = null
    process.standardInput = nil
    try process.run()
    let pid = process.processIdentifier
    try writeCursorPID(pid)
    for _ in 0..<40 {
        if isCursorReady() { break }
        usleep(25_000)
    }
    return pid
}

func mousePointForCursorState(_ state: CursorState) throws -> (CGPoint, CGWindowID?) {
    guard let coord = CoordMode(rawValue: state.coord) else {
        throw CUAError.cursorStateUnavailable("invalid cursor coord mode: \(state.coord)")
    }
    switch state.mode {
    case .background:
        guard let rawWid = state.wid else {
            throw CUAError.cursorStateUnavailable("background cursor state is missing wid")
        }
        let window = try getWindow(CGWindowID(rawWid))
        let quartzPoint = toGlobal(bounds: window.bounds, x: state.x, y: state.y, coord: coord)
        return (quartzToAppKitPoint(quartzPoint), window.wid)
    case .foregroundApp:
        let window = try frontmostWindow()
        let quartzPoint = toGlobal(bounds: window.bounds, x: state.x, y: state.y, coord: coord)
        return (quartzToAppKitPoint(quartzPoint), window.wid)
    case .foregroundDesktop:
        let quartzPoint = displayPoint(x: state.x, y: state.y, coord: coord)
        return (quartzToAppKitPoint(quartzPoint), nil)
    }
}

final class CursorView: NSView {
    static let canvasPadding: CGFloat = 24
    static let pointerBounds = CGRect(x: 0, y: -45, width: 26, height: 45)
    static let canvasSize = CGSize(
        width: pointerBounds.width + (canvasPadding * 2),
        height: pointerBounds.height + (canvasPadding * 2)
    )
    static let effectiveHotSpot = CGPoint(
        x: canvasPadding - pointerBounds.minX,
        y: canvasPadding - pointerBounds.minY
    )
    static let fillColor = NSColor(calibratedWhite: 0.06, alpha: 1.0)
    static let pressedFillColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
    static let glowColor = NSColor(calibratedRed: 0.75, green: 0.97, blue: 0.70, alpha: 0.9)
    static let borderWidth: CGFloat = 3.0

    var pressed = false { didSet { needsDisplay = true } }
    var clickPulseProgress: CGFloat = -1 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    private func cursorPath(scale: CGFloat, points: [CGPoint]) -> NSBezierPath {
        let anchor = Self.effectiveHotSpot
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let scaled = CGPoint(x: anchor.x + point.x * scale, y: anchor.y + point.y * scale)
            if index == 0 {
                path.move(to: scaled)
            } else {
                path.line(to: scaled)
            }
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    private func drawCursor(scale: CGFloat, fill: NSColor) {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: -34),
            CGPoint(x: 8, y: -27),
            CGPoint(x: 13, y: -45),
            CGPoint(x: 19, y: -43),
            CGPoint(x: 14, y: -26),
            CGPoint(x: 26, y: -26)
        ]
        let path = cursorPath(scale: scale, points: points)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = Self.glowColor
        shadow.set()
        fill.setFill()
        NSColor.white.setStroke()
        path.lineWidth = Self.borderWidth
        path.fill()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let scale: CGFloat = pressed ? 0.94 : 1.0
        let fill = pressed ? Self.pressedFillColor : Self.fillColor

        if pressed {
            let pulseCenter = Self.effectiveHotSpot
            let ringRadius: CGFloat = 18
            let ringRect = CGRect(x: pulseCenter.x - ringRadius, y: pulseCenter.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            let ring = NSBezierPath(ovalIn: ringRect)
            NSGraphicsContext.current?.saveGraphicsState()
            let ringShadow = NSShadow()
            ringShadow.shadowBlurRadius = 6
            ringShadow.shadowOffset = CGSize(width: 0, height: -2)
            ringShadow.shadowColor = Self.glowColor.withAlphaComponent(0.7)
            ringShadow.set()
            NSColor.white.setStroke()
            ring.lineWidth = 2
            ring.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        drawCursor(scale: scale, fill: fill)
    }
}

final class CursorOverlayController: NSObject, NSApplicationDelegate {
    private let cursorSize = CursorView.canvasSize
    private let hotSpot = CursorView.effectiveHotSpot
    private let visibilityAnimationDuration = cursorVisibilityAnimationDuration
    private let clickPressDuration = cursorClickPressDuration
    private let clickPulseDuration = cursorClickPulseDuration
    private var window: NSWindow!
    private var view: CursorView!
    private var timer: Timer?
    private var lastState: CursorState?
    private var animationStart = CGPoint.zero
    private var animationTarget = CGPoint.zero
    private var animationStartTime = CACurrentMediaTime()
    private var animationDuration = 0.0
    private var currentPoint = CGPoint.zero
    private var clickPulseStartTime: CFTimeInterval?
    private var currentVisibility = 0.0
    private var visibilityFrom = 0.0
    private var visibilityTo = 0.0
    private var visibilityStartTime = CACurrentMediaTime()
    private var shouldTerminateAfterHide = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let frame = CGRect(origin: .zero, size: cursorSize)
        window = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.alphaValue = 0.0

        view = CursorView(frame: frame)
        window.contentView = view
        window.orderOut(nil)

        bootstrapFromState()
        try? writeCursorReady()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handlePulseNotification),
            name: Notification.Name("macos-bg-cua.cursor-pulse"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStopNotification),
            name: Notification.Name("macos-bg-cua.cursor-stop"),
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        removeCursorSessionFiles()
    }

    @objc private func handlePulseNotification() {
        pulseClick()
    }

    @objc private func handleStopNotification() {
        shouldTerminateAfterHide = true
        beginVisibilityAnimation(to: 0.0)
    }

    private func bootstrapFromState() {
        guard let state = try? readCursorState() else { return }
        lastState = state
        if let (point, _) = try? mousePointForCursorState(state) {
            currentPoint = point
            animationStart = point
            animationTarget = point
            animationDuration = 0
            let origin = CGPoint(x: point.x - hotSpot.x, y: point.y - hotSpot.y)
            window.setFrameOrigin(origin)
        }
        let initialVisibility = state.visible ? 0.0 : 0.0
        currentVisibility = initialVisibility
        visibilityFrom = initialVisibility
        visibilityTo = state.visible ? 1.0 : 0.0
        visibilityStartTime = CACurrentMediaTime()
        window.alphaValue = initialVisibility
    }

    private func beginVisibilityAnimation(to target: Double) {
        visibilityFrom = currentVisibility
        visibilityTo = target
        visibilityStartTime = CACurrentMediaTime()
    }

    private func updateVisibility(now: CFTimeInterval) {
        let elapsed = min(max((now - visibilityStartTime) / visibilityAnimationDuration, 0), 1)
        let eased = 1 - pow(1 - elapsed, 3)
        currentVisibility = visibilityFrom + (visibilityTo - visibilityFrom) * eased
        window.alphaValue = currentVisibility

        if currentVisibility <= 0.001 {
            view.clickPulseProgress = -1
            window.orderOut(nil)
            if shouldTerminateAfterHide {
                NSApp.terminate(nil)
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if let state = try? readCursorState(), state != lastState {
            lastState = state
            if state.visible, let (point, _) = try? mousePointForCursorState(state) {
                animationStart = currentPoint == .zero ? point : currentPoint
                animationTarget = point
                animationStartTime = now
                animationDuration = max(state.duration, 0)
            }
            let targetVisibility = state.visible ? 1.0 : 0.0
            if abs(visibilityTo - targetVisibility) > 0.001 {
                shouldTerminateAfterHide = false
                beginVisibilityAnimation(to: targetVisibility)
            }
        }

        guard let state = lastState else {
            beginVisibilityAnimation(to: 0.0)
            updateVisibility(now: now)
            return
        }

        updateVisibility(now: now)
        guard state.visible, currentVisibility > 0.001 else {
            return
        }

        guard let (resolvedPoint, targetWid) = try? mousePointForCursorState(state) else {
            beginVisibilityAnimation(to: 0.0)
            updateVisibility(now: now)
            return
        }

        if animationDuration <= 0 {
            currentPoint = resolvedPoint
        } else {
            let elapsed = now - animationStartTime
            let t = min(max(elapsed / animationDuration, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            currentPoint = CGPoint(
                x: animationStart.x + (animationTarget.x - animationStart.x) * eased,
                y: animationStart.y + (animationTarget.y - animationStart.y) * eased
            )
            if t >= 1 {
                animationDuration = 0
                currentPoint = resolvedPoint
            }
        }

        if resolvedPoint != animationTarget, animationDuration == 0 {
            currentPoint = resolvedPoint
        }

        let origin = CGPoint(x: currentPoint.x - hotSpot.x, y: currentPoint.y - hotSpot.y)
        window.setFrameOrigin(origin)

        if let clickPulseStartTime {
            let elapsed = now - clickPulseStartTime
            if elapsed < clickPressDuration {
                view.pressed = true
                view.clickPulseProgress = -1
            } else if elapsed < clickPressDuration + clickPulseDuration {
                view.pressed = false
                view.clickPulseProgress = CGFloat((elapsed - clickPressDuration) / clickPulseDuration)
            } else {
                view.pressed = false
                view.clickPulseProgress = -1
                self.clickPulseStartTime = nil
            }
        } else {
            view.pressed = false
        }

        if let targetWid {
            window.level = .normal
            window.order(.above, relativeTo: Int(targetWid))
        } else {
            window.level = .statusBar
            window.orderFrontRegardless()
        }
    }

    func pulseClick() {
        clickPulseStartTime = CACurrentMediaTime()
        view.clickPulseProgress = 0
    }
}

func runCursorDaemon() throws {
    try ensureCursorSessionDirectory()
    try writeCursorPID(getpid())
    let app = NSApplication.shared
    let delegate = CursorOverlayController()
    app.delegate = delegate
    app.run()
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

func cgKeyPress(pid: pid_t, keycode: CGKeyCode, flags: CGEventFlags = [], hold: useconds_t = 35_000) {
    cgKey(pid: pid, keycode: keycode, down: true, flags: flags)
    usleep(hold)
    cgKey(pid: pid, keycode: keycode, down: false, flags: flags)
}

func nsModifierFlags(_ modifiers: [String]) -> NSEvent.ModifierFlags {
    modifiers.reduce(NSEvent.ModifierFlags()) { partial, modifier in
        var result = partial
        switch modifier.lowercased() {
        case "shift":
            result.insert(.shift)
        case "cmd", "command":
            result.insert(.command)
        case "alt", "option", "opt":
            result.insert(.option)
        case "ctrl", "control":
            result.insert(.control)
        case "fn":
            result.insert(.function)
        default:
            break
        }
        return result
    }
}

func charactersForKey(_ key: String, modifiers: [String]) -> (String, String)? {
    switch key {
    case "Enter", "Return", "KP_Enter":
        return ("\r", "\r")
    case "Tab":
        return ("\t", "\t")
    case "Space", " ":
        return (" ", " ")
    case "Backspace", "Delete":
        return ("\u{8}", "\u{8}")
    case "Escape", "Esc":
        return ("\u{1b}", "\u{1b}")
    default:
        break
    }

    guard key.count == 1, let character = key.first else { return nil }
    let shift = modifiers.contains { $0.lowercased() == "shift" }
    if shift, let base = shifted[character] {
        return (String(character), base)
    }
    if shift {
        return (String(character).uppercased(), String(character).lowercased())
    }
    return (String(character), String(character).lowercased())
}

func nsKeyPress(pid: pid_t, wid: CGWindowID, keycode: CGKeyCode, key: String, modifiers: [String], hold: useconds_t = 35_000) -> Bool {
    guard let (characters, charactersIgnoringModifiers) = charactersForKey(key, modifiers: modifiers) else {
        return false
    }
    let flags = nsModifierFlags(modifiers)
    let timestamp = ProcessInfo.processInfo.systemUptime
    guard let down = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: flags,
        timestamp: timestamp,
        windowNumber: Int(wid),
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: UInt16(keycode)
    )?.cgEvent else {
        return false
    }
    guard let up = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: flags,
        timestamp: timestamp + Double(hold) / 1_000_000,
        windowNumber: Int(wid),
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: UInt16(keycode)
    )?.cgEvent else {
        return false
    }
    down.postToPid(pid)
    usleep(hold)
    up.postToPid(pid)
    return true
}

func nsTypeText(pid: pid_t, wid: CGWindowID, text: String) -> Bool {
    var didType = false
    for character in text {
        guard let (code, needsShift) = keycodeForCharacter(character) else { return false }
        let modifiers = needsShift ? ["shift"] : []
        if nsKeyPress(pid: pid, wid: wid, keycode: code, key: String(character), modifiers: modifiers) {
            didType = true
        } else {
            return false
        }
        usleep(20_000)
    }
    return didType || text.isEmpty
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

func desktopFrameAppKit() -> CGRect {
    NSScreen.screens.reduce(CGRect.null) { partial, screen in
        partial.union(screen.frame)
    }
}

func quartzToAppKitPoint(_ point: CGPoint) -> CGPoint {
    let desktop = desktopFrameAppKit()
    return CGPoint(x: point.x, y: desktop.maxY - point.y)
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
        cgKeyPress(pid: pid, keycode: code, flags: flags)
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

func parseCursorMoveOptions(cursor: inout ArgumentCursor, defaultDuration: Double = 0.18) throws -> (Double, CoordMode?, Bool) {
    var duration = defaultDuration
    var coord: CoordMode?
    var wait = false
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        switch arg {
        case "--duration":
            duration = Double(try cursor.popDouble())
        case "--coord":
            let raw = try cursor.pop()
            guard let parsed = CoordMode(rawValue: raw) else { throw CUAError.usage("unknown coord mode: \(raw)") }
            coord = parsed
        case "--wait":
            wait = true
        default:
            throw CUAError.usage("unknown cursor option: \(arg)")
        }
    }
    return (duration, coord, wait)
}

func parseCursorClickOptions(cursor: inout ArgumentCursor) throws -> Bool {
    var wait = false
    while !cursor.args.isEmpty {
        let arg = try cursor.pop()
        switch arg {
        case "--wait":
            wait = true
        default:
            throw CUAError.usage("unknown cursor click option: \(arg)")
        }
    }
    return wait
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

func notifyCursorClickPulse() {
    DistributedNotificationCenter.default().post(name: Notification.Name("macos-bg-cua.cursor-pulse"), object: nil)
}

func notifyCursorStop() {
    DistributedNotificationCenter.default().post(name: Notification.Name("macos-bg-cua.cursor-stop"), object: nil)
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
      macos-bg-cua cursor <command> ...
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
      cursor         Runs a persistent visual overlay cursor. In background mode,
                     it is ordered relative to the target window so overlapping
                     front windows should cover it while the target app is behind.

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
      macos-bg-cua cursor start background 12345 240 180 --duration 0.0
      macos-bg-cua cursor move 400 320 --duration 0.25 --wait
      macos-bg-cua cursor retarget foreground-app --wait
      macos-bg-cua cursor click --wait
      macos-bg-cua cursor hide
      macos-bg-cua cursor stop
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
    case "cursor-daemon":
        try runCursorDaemon()
    case "help", "--help", "-h":
        print(usage())
    case "active-window":
        try printJSON(listWindows(filter: AppFilter(pid: try frontmostApp().processIdentifier)).first ?? frontmostWindow().jsonObject)
    case "cursor":
        try runCursorCommand(cursor: &cursor)
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
