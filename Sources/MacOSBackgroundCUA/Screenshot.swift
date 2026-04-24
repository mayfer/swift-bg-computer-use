import AppKit
import CoreGraphics
import Foundation

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
