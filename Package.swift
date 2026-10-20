// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skriv",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Skriv", targets: ["Skriv"])],
    targets: [
        .target(name: "SkrivCore"),
        .executableTarget(name: "Skriv", dependencies: ["SkrivCore"]),
        .testTarget(name: "SkrivCoreTests", dependencies: ["SkrivCore"]),
    ]
)
