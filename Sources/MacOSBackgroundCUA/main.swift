import Foundation

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
    case "screenshot",
         "click", "right-click", "double-click", "drag", "scroll", "type", "press", "hotkey":
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
