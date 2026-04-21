// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "macos-background-cua",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "macos-bg-cua", targets: ["MacOSBackgroundCUA"])
    ],
    targets: [
        .executableTarget(name: "MacOSBackgroundCUA")
    ]
)
