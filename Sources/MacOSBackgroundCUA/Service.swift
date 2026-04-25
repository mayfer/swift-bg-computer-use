import CoreGraphics
import Darwin
import Dispatch
import Foundation
import QuartzCore

let serviceSessionDirectory = "/tmp/macos-bg-cua-service-\(executableSessionTag())"
let serviceSocketPath = "\(serviceSessionDirectory)/sock"
let servicePIDPath = "\(serviceSessionDirectory)/pid"
let serviceReadyPath = "\(serviceSessionDirectory)/ready"
let cursorIdleAutoHideSeconds: Double = 4.0

struct ServiceRequest: Codable {
    var argv: [String]?
    var control: String?
}

struct ServiceResponse: Codable {
    var ok: Bool
    var stdout: String
    var stderr: String
    var exit: Int32
}

func ensureServiceSessionDirectory() throws {
    try FileManager.default.createDirectory(atPath: serviceSessionDirectory, withIntermediateDirectories: true)
}

func writeServicePID(_ pid: Int32) throws {
    try ensureServiceSessionDirectory()
    try atomicWrite(Data(String(pid).utf8), to: servicePIDPath)
}

func readServicePID() -> Int32? {
    guard let raw = try? String(contentsOfFile: servicePIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = Int32(raw) else {
        return nil
    }
    return pid
}

func writeServiceReady() throws {
    try ensureServiceSessionDirectory()
    try atomicWrite(Data("ready".utf8), to: serviceReadyPath)
}

func isServiceReady() -> Bool {
    FileManager.default.fileExists(atPath: serviceReadyPath)
}

func isServiceRunning() -> Bool {
    guard let pid = readServicePID() else { return false }
    return isProcessAlive(pid)
}

func removeServiceSessionFiles() {
    _ = try? FileManager.default.removeItem(atPath: serviceSocketPath)
    _ = try? FileManager.default.removeItem(atPath: servicePIDPath)
    _ = try? FileManager.default.removeItem(atPath: serviceReadyPath)
}

func spawnServiceDaemonIfNeeded() throws -> Int32 {
    if let pid = readServicePID(), isProcessAlive(pid) {
        return pid
    }
    _ = try? FileManager.default.removeItem(atPath: serviceReadyPath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: currentExecutablePath())
    process.arguments = ["service", "run"]
    let null = FileHandle(forWritingAtPath: "/dev/null")
    process.standardOutput = null
    process.standardError = null
    process.standardInput = nil
    try process.run()
    let pid = process.processIdentifier
    try writeServicePID(pid)
    for _ in 0..<120 {
        if isServiceReady() { break }
        usleep(25_000)
    }
    return pid
}

private func makeSockaddrUn(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
            _ = strlcpy(cptr, path, capacity)
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

private func bindServerSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw CUAError.usage("socket() failed: \(String(cString: strerror(errno)))")
    }
    var addr = makeSockaddrUn(path: path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
            bind(fd, sptr, len)
        }
    }
    guard bindResult == 0 else {
        let msg = String(cString: strerror(errno))
        close(fd)
        throw CUAError.usage("bind(\(path)) failed: \(msg)")
    }
    guard listen(fd, 8) == 0 else {
        let msg = String(cString: strerror(errno))
        close(fd)
        throw CUAError.usage("listen() failed: \(msg)")
    }
    return fd
}

private func connectClientSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw CUAError.usage("socket() failed: \(String(cString: strerror(errno)))")
    }
    var addr = makeSockaddrUn(path: path)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
            connect(fd, sptr, len)
        }
    }
    guard result == 0 else {
        let msg = String(cString: strerror(errno))
        close(fd)
        throw CUAError.usage("connect(\(path)) failed: \(msg)")
    }
    return fd
}

private func readJSONLine(fd: Int32) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk.prefix(n))
        if buffer.contains(0x0a) { break }
    }
    if buffer.isEmpty { return nil }
    if let idx = buffer.firstIndex(of: 0x0a) {
        return buffer.subdata(in: buffer.startIndex..<idx)
    }
    return buffer
}

private func writeAll(fd: Int32, _ data: Data) {
    var remaining = data
    while !remaining.isEmpty {
        let count = remaining.count
        let n = remaining.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, count)
        }
        if n <= 0 { break }
        remaining.removeFirst(n)
    }
}

private func sendResponse(fd: Int32, _ response: ServiceResponse) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    var out = data
    out.append(0x0a)
    writeAll(fd: fd, out)
}

func captureOutput(_ body: () -> Void) -> (stdout: String, stderr: String) {
    fflush(Darwin.stdout)
    fflush(Darwin.stderr)

    let outPath = "\(NSTemporaryDirectory())macos-bg-cua-out-\(UUID().uuidString)"
    let errPath = "\(NSTemporaryDirectory())macos-bg-cua-err-\(UUID().uuidString)"

    let outFd = open(outPath, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    let errFd = open(errPath, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard outFd >= 0, errFd >= 0 else {
        if outFd >= 0 { close(outFd) }
        if errFd >= 0 { close(errFd) }
        body()
        return ("", "")
    }

    let savedStdout = dup(1)
    let savedStderr = dup(2)
    _ = dup2(outFd, 1)
    _ = dup2(errFd, 2)
    close(outFd)
    close(errFd)

    body()

    fflush(Darwin.stdout)
    fflush(Darwin.stderr)

    _ = dup2(savedStdout, 1)
    _ = dup2(savedStderr, 2)
    close(savedStdout)
    close(savedStderr)

    let outData = (try? Data(contentsOf: URL(fileURLWithPath: outPath))) ?? Data()
    let errData = (try? Data(contentsOf: URL(fileURLWithPath: errPath))) ?? Data()
    _ = try? FileManager.default.removeItem(atPath: outPath)
    _ = try? FileManager.default.removeItem(atPath: errPath)

    return (
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

private func executeServiceCommand(argv: [String]) -> ServiceResponse {
    var ok = true
    var exitCode: Int32 = 0
    let captured = captureOutput {
        do {
            try run(["macos-bg-cua"] + argv)
        } catch let error as CUAError {
            fputs("error: \(error.description)\n", Darwin.stderr)
            ok = false
            exitCode = 1
        } catch {
            fputs("error: \(error)\n", Darwin.stderr)
            ok = false
            exitCode = 1
        }
    }
    return ServiceResponse(ok: ok, stdout: captured.stdout, stderr: captured.stderr, exit: exitCode)
}

private func argvTouchesCursor(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    if first == "cursor" {
        guard argv.count > 1 else { return false }
        switch argv[1] {
        case "start", "move", "retarget", "show", "click":
            return true
        default:
            return false
        }
    }
    return false
}

final class ServiceRuntime {
    let idleTimeout: Double
    var lastCursorActivity: CFTimeInterval
    var cursorHiddenByIdle: Bool = false
    var shuttingDown = false
    var signalSources: [DispatchSourceSignal] = []
    var idleTimer: DispatchSourceTimer?

    init(idleTimeout: Double) {
        self.idleTimeout = idleTimeout
        self.lastCursorActivity = CACurrentMediaTime()
    }

    func touchCursor() {
        lastCursorActivity = CACurrentMediaTime()
        cursorHiddenByIdle = false
    }

    func tick() {
        guard idleTimeout > 0, !shuttingDown else { return }
        guard let pid = readCursorPID(), isProcessAlive(pid) else { return }
        guard var state = try? readCursorState() else { return }
        guard state.visible else { return }
        // Direct `cursor ...` commands refresh the shared state timestamp but do not
        // run through `service send`, so the daemon's local activity clock can be stale.
        // Use the newer of the two clocks to avoid hiding the overlay immediately.
        let stateActivity = state.updatedAt
        let serviceActivity = Date().timeIntervalSince1970 - (CACurrentMediaTime() - lastCursorActivity)
        let lastActivity = max(stateActivity, serviceActivity)
        let elapsed = Date().timeIntervalSince1970 - lastActivity
        if elapsed >= idleTimeout {
            state.visible = false
            state.updatedAt = Date().timeIntervalSince1970
            try? writeCursorState(state)
            cursorHiddenByIdle = true
        }
    }
}

func serviceShutdown(runtime: ServiceRuntime) {
    runtime.shuttingDown = true
    if let pid = readCursorPID(), isProcessAlive(pid) {
        notifyCursorStop()
        for _ in 0..<12 {
            if !isProcessAlive(pid) { break }
            usleep(50_000)
        }
        if isProcessAlive(pid) {
            kill(pid, SIGTERM)
            for _ in 0..<10 {
                if !isProcessAlive(pid) { break }
                usleep(50_000)
            }
        }
        if isProcessAlive(pid) {
            kill(pid, SIGKILL)
        }
        removeCursorSessionFiles()
    }
    removeServiceSessionFiles()
}

private func handleClient(fd: Int32, runtime: ServiceRuntime) {
    defer { close(fd) }
    guard let line = readJSONLine(fd: fd), !line.isEmpty else { return }
    let request: ServiceRequest
    do {
        request = try JSONDecoder().decode(ServiceRequest.self, from: line)
    } catch {
        sendResponse(fd: fd, ServiceResponse(ok: false, stdout: "", stderr: "invalid request: \(error)\n", exit: 1))
        return
    }

    if let control = request.control {
        switch control {
        case "ping":
            sendResponse(fd: fd, ServiceResponse(ok: true, stdout: "pong\n", stderr: "", exit: 0))
        case "status":
            let cursorPID = readCursorPID()
            let cursorState = try? readCursorState()
            var info: [String: Any] = [
                "running": true,
                "pid": Int(getpid()),
                "socket": serviceSocketPath,
                "idleTimeout": runtime.idleTimeout,
                "cursorRunning": cursorPID.map(isProcessAlive) ?? false,
                "cursorHiddenByIdle": runtime.cursorHiddenByIdle,
                "cursorIdleSeconds": CACurrentMediaTime() - runtime.lastCursorActivity
            ]
            if let state = cursorState {
                info["cursorVisible"] = state.visible
                info["cursorMode"] = state.mode.rawValue
            }
            let data = (try? JSONSerialization.data(withJSONObject: info, options: [])) ?? Data("{}".utf8)
            let str = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
            sendResponse(fd: fd, ServiceResponse(ok: true, stdout: str, stderr: "", exit: 0))
        case "shutdown":
            sendResponse(fd: fd, ServiceResponse(ok: true, stdout: "", stderr: "", exit: 0))
            serviceShutdown(runtime: runtime)
            exit(0)
        default:
            sendResponse(fd: fd, ServiceResponse(ok: false, stdout: "", stderr: "unknown control: \(control)\n", exit: 1))
        }
        return
    }

    guard let argv = request.argv, !argv.isEmpty else {
        sendResponse(fd: fd, ServiceResponse(ok: false, stdout: "", stderr: "missing argv\n", exit: 1))
        return
    }

    if let first = argv.first, first == "service" || first == "cursor-daemon" {
        sendResponse(fd: fd, ServiceResponse(ok: false, stdout: "", stderr: "command not allowed via service socket: \(first)\n", exit: 1))
        return
    }

    let response = executeServiceCommand(argv: argv)
    if argvTouchesCursor(argv) {
        runtime.touchCursor()
    }
    sendResponse(fd: fd, response)
}

func runServiceDaemon() throws {
    try ensureServiceSessionDirectory()
    try writeServicePID(getpid())
    _ = unlink(serviceSocketPath)

    let serverFd = try bindServerSocket(path: serviceSocketPath)
    let runtime = ServiceRuntime(idleTimeout: cursorIdleAutoHideSeconds)

    signal(SIGPIPE, SIG_IGN)

    let handlerQueue = DispatchQueue(label: "macos-bg-cua.service")

    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: handlerQueue)
        source.setEventHandler {
            serviceShutdown(runtime: runtime)
            exit(0)
        }
        source.resume()
        runtime.signalSources.append(source)
    }

    let timer = DispatchSource.makeTimerSource(queue: handlerQueue)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler {
        runtime.tick()
    }
    timer.resume()
    runtime.idleTimer = timer

    try writeServiceReady()

    while true {
        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(serverFd, &clientAddr, &clientLen)
        if clientFd < 0 {
            if errno == EINTR { continue }
            break
        }
        handlerQueue.async {
            handleClient(fd: clientFd, runtime: runtime)
        }
    }
    close(serverFd)
    removeServiceSessionFiles()
}

func sendToService(argv: [String]) throws -> ServiceResponse {
    if !isServiceRunning() {
        _ = try spawnServiceDaemonIfNeeded()
    }
    let fd = try connectClientSocket(path: serviceSocketPath)
    defer { close(fd) }
    let req = ServiceRequest(argv: argv, control: nil)
    guard let data = try? JSONEncoder().encode(req) else {
        throw CUAError.usage("failed to encode request")
    }
    var out = data
    out.append(0x0a)
    writeAll(fd: fd, out)
    guard let line = readJSONLine(fd: fd), !line.isEmpty else {
        throw CUAError.usage("no response from service")
    }
    return try JSONDecoder().decode(ServiceResponse.self, from: line)
}

private func sendControl(_ control: String, timeoutMs: Int = 2000) throws -> ServiceResponse? {
    guard isServiceRunning() else { return nil }
    let fd = try connectClientSocket(path: serviceSocketPath)
    defer { close(fd) }
    let req = ServiceRequest(argv: nil, control: control)
    guard let data = try? JSONEncoder().encode(req) else { return nil }
    var out = data
    out.append(0x0a)
    writeAll(fd: fd, out)
    guard let line = readJSONLine(fd: fd), !line.isEmpty else { return nil }
    return try? JSONDecoder().decode(ServiceResponse.self, from: line)
}

func runServiceSubcommand(cursor: inout ArgumentCursor) throws {
    guard !cursor.args.isEmpty else { throw CUAError.usage("service needs a command (start|stop|status|run|send|ping)") }
    let command = try cursor.pop()
    switch command {
    case "start":
        if let pid = readServicePID(), isProcessAlive(pid) {
            try printJSON([
                "ok": true,
                "pid": Int(pid),
                "alreadyRunning": true,
                "socket": serviceSocketPath
            ])
            return
        }
        let pid = try spawnServiceDaemonIfNeeded()
        try printJSON([
            "ok": true,
            "pid": Int(pid),
            "alreadyRunning": false,
            "socket": serviceSocketPath
        ])
    case "stop":
        guard let pid = readServicePID(), isProcessAlive(pid) else {
            removeServiceSessionFiles()
            try printJSON(["ok": true, "wasRunning": false])
            return
        }
        var viaSocket = false
        if FileManager.default.fileExists(atPath: serviceSocketPath) {
            if let _ = try? sendControl("shutdown") {
                viaSocket = true
            }
        }
        for _ in 0..<30 {
            if !isProcessAlive(pid) { break }
            usleep(50_000)
        }
        if isProcessAlive(pid) {
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if !isProcessAlive(pid) { break }
                usleep(50_000)
            }
        }
        if isProcessAlive(pid) {
            kill(pid, SIGKILL)
        }
        removeServiceSessionFiles()
        try printJSON(["ok": true, "wasRunning": true, "viaSocket": viaSocket])
    case "status":
        let running = isServiceRunning()
        let pidAny: Any = readServicePID().map { Int($0) as Any } ?? NSNull()
        var object: [String: Any] = [
            "running": running,
            "pid": pidAny,
            "socket": serviceSocketPath
        ]
        if running,
           let response = (try? sendControl("status")) ?? nil,
           let payload = response.stdout.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            for (k, v) in extra { object[k] = v }
        }
        try printJSON(object)
    case "run":
        try runServiceDaemon()
    case "send":
        let argv = cursor.args
        cursor.args.removeAll()
        guard !argv.isEmpty else { throw CUAError.usage("service send needs arguments") }
        let response = try sendToService(argv: argv)
        if !response.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(response.stdout.utf8))
        }
        if !response.stderr.isEmpty {
            FileHandle.standardError.write(Data(response.stderr.utf8))
        }
        if !response.ok {
            exit(response.exit == 0 ? 1 : response.exit)
        }
    case "ping":
        guard isServiceRunning() else {
            try printJSON(["ok": false, "running": false])
            exit(1)
        }
        if let response = try sendControl("ping") {
            try printJSON(["ok": response.ok, "response": response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)])
        } else {
            try printJSON(["ok": false])
            exit(1)
        }
    default:
        throw CUAError.usage("unknown service command: \(command)")
    }
}
