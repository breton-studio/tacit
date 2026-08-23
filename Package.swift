// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tacit",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TacitCore"),
        .executableTarget(
            name: "Tacit",
            dependencies: ["TacitCore"],
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(name: "TacitCoreTests", dependencies: ["TacitCore"]),
    ]
)
