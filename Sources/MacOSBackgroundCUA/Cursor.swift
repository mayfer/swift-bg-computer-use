import AppKit
import CoreGraphics
import Foundation
import QuartzCore

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

func executableSessionTag() -> String {
    let url = URL(fileURLWithPath: currentExecutablePath())
    let components = url.pathComponents.suffix(3)
    let joined = components.joined(separator: "-")
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    return joined.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
}

let cursorSessionDirectory = "/tmp/macos-bg-cua-cursor-\(executableSessionTag())"
let cursorStatePath = "\(cursorSessionDirectory)/state.json"
let cursorPIDPath = "\(cursorSessionDirectory)/pid"
let cursorReadyPath = "\(cursorSessionDirectory)/ready"
let cursorVisibilityAnimationDuration = 0.12
let cursorClickPressDuration = 0.05
let cursorClickPulseDuration = 0.22

private let cursorPulseNotification = Notification.Name("macos-bg-cua.cursor-pulse")
private let cursorStopNotification = Notification.Name("macos-bg-cua.cursor-stop")

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

func notifyCursorClickPulse() {
    DistributedNotificationCenter.default().post(name: cursorPulseNotification, object: nil)
}

func notifyCursorStop() {
    DistributedNotificationCenter.default().post(name: cursorStopNotification, object: nil)
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
            name: cursorPulseNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStopNotification),
            name: cursorStopNotification,
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
