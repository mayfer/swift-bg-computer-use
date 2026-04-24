import ApplicationServices
import CoreGraphics
import Foundation

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
