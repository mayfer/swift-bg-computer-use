import CoreGraphics
import Foundation

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
