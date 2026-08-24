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
            // `Resources/previews`: `PreviewAssets` (Sources/Tacit/Library/GesturePreviewView.swift)
            // resolves these 46 files via `Bundle.main.resourceURL`, not `Bundle.module` — they're
            // copied into the app bundle by `scripts/make-app.sh`, not by SwiftPM's resource
            // pipeline. Excluding (rather than declaring as `resources:`) documents that intent and
            // silences SwiftPM's "found N file(s) which are unhandled" warning without creating a
            // second, unused `Bundle.module` copy of the same assets.
            exclude: ["Resources/Info.plist", "Resources/previews", "Resources/AppIcon.icns"]
        ),
        .testTarget(name: "TacitCoreTests", dependencies: ["TacitCore"]),
    ]
)
