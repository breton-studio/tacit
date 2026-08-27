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
        // Code review 2026-08-27, Finding 2 / item (d): `Tacit` is an `executableTarget`, and this
        // toolchain (Swift 6.3.3) allows a `.testTarget` to depend on one directly — confirmed by
        // building `@testable import Tacit` before committing to this shape, so the review's
        // hedged "extract a library target" fallback was never needed. `TacitCore` is listed too
        // so this target can construct `KeyChord`/`GestureEvent`/etc. without going through
        // `Tacit`'s re-export surface.
        .testTarget(
            name: "TacitTests",
            dependencies: ["Tacit", "TacitCore"],
            // `README.md` documents the harness for the three agents writing tests here next
            // (Tests/TacitTests/README.md) — excluded for the same reason `Tacit`'s target above
            // excludes its `Resources/`: it isn't a `.swift` source, and SwiftPM otherwise warns
            // "found 1 file(s) which are unhandled" on every build.
            exclude: ["README.md"]
        ),
    ]
)
