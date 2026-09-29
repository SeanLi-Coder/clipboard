// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipShelf",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipShelf", targets: ["ClipShelf"]),
        .library(name: "ClipboardCore", targets: ["ClipboardCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipboardCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipShelfTests", dependencies: ["ClipShelf"])
    ]
)
