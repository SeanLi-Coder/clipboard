// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipShelf",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipShelf", targets: ["ClipShelf"]),
        .library(name: "ClipboardCore", targets: ["ClipboardCore"])
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"])
    ]
)
