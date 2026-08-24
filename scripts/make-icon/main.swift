// Renders the Tacit app icon (spec: background `#111111`, Lucide `hand` glyph in `#f9f9f9`) and
// writes out both the 1024×1024 master PNG and an `AppIcon.iconset` directory with the 10
// standard macOS icon sizes, ready for `iconutil -c icns`.
//
// Compiled by `scripts/make-icon.sh` together with `Sources/Tacit/LucideGlyphs.swift` — reusing
// its SVG-path interpreter and the transcribed Lucide `hand` path data rather than duplicating
// them. `LucideGlyphs.swift`'s bottom-of-file `LucideMenuBarIcon` view references two symbols
// (`GlyphState`, `MenuBarGlyph.color(for:)`) that normally live in `Sources/Tacit/MenuBarGlyph.swift`
// — pulling that whole file in would cascade into `TacitCore` (it references `KeyChord`, an
// `ObservableObject` protocol, etc.), so instead of compiling the app target's full source graph
// we declare tiny same-module shims below with matching names/signatures, just enough for
// `LucideGlyphs.swift` to type-check. `LucideMenuBarIcon` itself is never invoked by this program.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Shims satisfying `LucideGlyphs.swift`'s `LucideMenuBarIcon` (unused by this program)

enum GlyphState: Equatable {
    case paused, watching, armed, fired
}

enum MenuBarGlyph {
    static func color(for state: GlyphState) -> Color { .primary }
}

// MARK: - Icon geometry (spec, all figures relative to a 1024×1024 canvas)

let masterSize: CGFloat = 1024
let margin: CGFloat = 100 // transparent margin on every side
let squircleSide: CGFloat = 824 // 1024 - 2*100
let cornerRadius: CGFloat = 185 // continuous-corner approximation
let glyphSpan: CGFloat = 480 // the 24-unit Lucide viewBox spans this many px
let strokeWidthAt1024: CGFloat = 40 // 2 units * (480/24)

let backgroundColor = CGColor(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0, alpha: 1)
let glyphColor = CGColor(red: 0xf9 / 255.0, green: 0xf9 / 255.0, blue: 0xf9 / 255.0, alpha: 1)

/// The Lucide `hand` glyph, scaled and positioned for a `canvasSize`×`canvasSize` render.
/// Scaled from the raw 24-unit path (not the SwiftUI `Shape`'s own `rect`-fitting scale, which
/// centers the *viewBox*) so we can re-center on the path's own bounding box afterwards — the
/// hand's silhouette isn't centered in its 24×24 viewBox, so centering the viewBox reads as
/// visually off-center in the squircle.
func glyphPath(canvasSize: CGFloat) -> CGPath {
    let s = canvasSize / masterSize
    let raw = LucideHandShape().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).cgPath
    let scale = (glyphSpan * s) / 24

    var scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
    let scaled = raw.copy(using: &scaleTransform) ?? raw

    let bounds = scaled.boundingBoxOfPath
    let center = canvasSize / 2
    var translateTransform = CGAffineTransform(
        translationX: center - bounds.midX,
        y: center - bounds.midY
    )
    return scaled.copy(using: &translateTransform) ?? scaled
}

/// Draws the full icon (squircle + glyph) into `context`, a `canvasSize`×`canvasSize` bitmap
/// context using a top-left-origin, y-down coordinate space (matching the Lucide SVG path data's
/// own orientation, and SwiftUI's).
func drawIcon(into context: CGContext, canvasSize: CGFloat) {
    context.translateBy(x: 0, y: canvasSize)
    context.scaleBy(x: 1, y: -1)

    let s = canvasSize / masterSize
    let rect = CGRect(x: margin * s, y: margin * s, width: squircleSide * s, height: squircleSide * s)
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius * s, cornerHeight: cornerRadius * s, transform: nil)
    context.addPath(squircle)
    context.setFillColor(backgroundColor)
    context.fillPath()

    context.addPath(glyphPath(canvasSize: canvasSize))
    context.setStrokeColor(glyphColor)
    context.setLineWidth(strokeWidthAt1024 * s)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

/// Renders one PNG at `size`×`size`, drawing natively at that resolution (not downscaled from the
/// master) for crisp edges at every size.
func renderPNG(size: Int, to path: String) {
    let canvasSize = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create CGContext for size \(size)")
    }
    drawIcon(into: context, canvasSize: canvasSize)
    guard let cgImage = context.makeImage() else {
        fatalError("could not create CGImage for size \(size)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG for size \(size)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("could not write \(path): \(error)")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: make-icon <master-png-path> <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let masterPath = arguments[1]
let iconsetDir = arguments[2]

try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

renderPNG(size: 1024, to: masterPath)

// The 10 standard `AppIcon.iconset` files: (16, 32, 128, 256, 512) at 1x and 2x.
let iconsetSizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in iconsetSizes {
    renderPNG(size: px, to: iconsetDir + "/" + name)
}

print("Wrote master PNG to \(masterPath)")
print("Wrote \(iconsetSizes.count) iconset files to \(iconsetDir)")
