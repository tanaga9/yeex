// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YeeX",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "YeeX", targets: ["YeeX"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "YeeXCore", dependencies: ["CZlib"]),
        .executableTarget(name: "YeeX", dependencies: ["YeeXCore"]),
        .testTarget(name: "YeeXCoreTests", dependencies: ["YeeXCore"], resources: [.copy("Fixtures")])
    ]
)
