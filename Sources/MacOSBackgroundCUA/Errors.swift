import CoreGraphics
import Foundation

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
