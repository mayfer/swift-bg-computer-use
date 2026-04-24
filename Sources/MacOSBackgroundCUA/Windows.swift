import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

func frontmostApp() throws -> NSRunningApplication {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        throw CUAError.usage("no frontmost application")
    }
    return app
}

func frontmostPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
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
