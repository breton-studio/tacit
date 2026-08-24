import SwiftUI

// Icon geometry below is transcribed from Lucide (https://lucide.dev), lucide-static v1.34.0,
// `hand.svg` / `hand-fist.svg` — ISC License (https://github.com/lucide-icons/lucide/blob/main/LICENSE).
// Both source files carry the header `@license lucide-static v1.34.0 - ISC`. Each icon is a
// 24×24 viewBox, `stroke-width="2"`, round caps/joins, `fill="none"` — reproduced here as
// SwiftUI `Shape`s (stroked, never filled) rather than pulling in a package dependency for two
// icons.

/// Minimal SVG path-data ("d" attribute) scanner, just capable enough for the two Lucide icons
/// this file embeds: numbers (with the glued/no-separator digit runs Lucide's minified paths use,
/// e.g. `"0 0 0-2-2"` or `".72.72"`) and single-digit arc flags.
private struct SVGPathScanner {
    private let chars: [Character]
    private var idx = 0

    init(_ d: String) { chars = Array(d) }

    private mutating func skipSeparators() {
        while idx < chars.count, " ,\n\t\r".contains(chars[idx]) {
            idx += 1
        }
    }

    /// Consumes and returns the next command letter (M, L, V, H, C, A, Z, or lowercase), or `nil`
    /// if the scanner is at a number instead (i.e. an implicit repeat of the previous command).
    mutating func nextCommand() -> Character? {
        skipSeparators()
        guard idx < chars.count, chars[idx].isLetter else { return nil }
        defer { idx += 1 }
        return chars[idx]
    }

    /// Whether the scanner is positioned (after separators) at the start of a number — used to
    /// detect an implicitly-repeated command (e.g. `"L1,2 3,4"` is `L1,2` then an implicit second
    /// lineto `3,4`, with no repeated `L`).
    mutating func hasNumber() -> Bool {
        skipSeparators()
        guard idx < chars.count else { return false }
        let c = chars[idx]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func number() -> Double {
        skipSeparators()
        var s = ""
        if idx < chars.count, chars[idx] == "+" || chars[idx] == "-" {
            s.append(chars[idx]); idx += 1
        }
        var sawDot = false
        while idx < chars.count {
            let c = chars[idx]
            if c.isNumber {
                s.append(c); idx += 1
            } else if c == "." && !sawDot {
                sawDot = true
                s.append(c); idx += 1
            } else {
                break
            }
        }
        if idx < chars.count, chars[idx] == "e" || chars[idx] == "E" {
            var look = idx + 1
            var exponent = String(chars[idx])
            if look < chars.count, chars[look] == "+" || chars[look] == "-" {
                exponent.append(chars[look]); look += 1
            }
            var hasExponentDigit = false
            while look < chars.count, chars[look].isNumber {
                exponent.append(chars[look]); look += 1; hasExponentDigit = true
            }
            if hasExponentDigit {
                s += exponent
                idx = look
            }
        }
        return Double(s) ?? 0
    }

    /// Elliptical-arc flags are single `0`/`1` digits, often glued to the token that follows with
    /// no separator (e.g. `"0 0 1-8 8"`).
    mutating func flag() -> Bool {
        skipSeparators()
        guard idx < chars.count else { return false }
        defer { idx += 1 }
        return chars[idx] == "1"
    }
}

/// Appends one elliptical-arc segment (SVG's `A`/`a` command) to `path` as a sequence of cubic
/// Bézier curves, using the standard SVG endpoint-to-center-parameterization conversion (SVG 1.1
/// Implementation Notes, appendix F.6), split into ≤90° segments for a close approximation.
private func appendArcSegment(
    to path: inout Path,
    from start: (x: Double, y: Double),
    to end: (x: Double, y: Double),
    rx rxIn: Double,
    ry ryIn: Double,
    xAxisRotationDegrees: Double,
    largeArc: Bool,
    sweep: Bool,
    project: (Double, Double) -> CGPoint
) {
    let (x1, y1) = start
    let (x2, y2) = end

    guard rxIn != 0, ryIn != 0, x1 != x2 || y1 != y2 else {
        path.addLine(to: project(x2, y2))
        return
    }

    var rx = abs(rxIn), ry = abs(ryIn)
    let phi = xAxisRotationDegrees * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)

    let dx2 = (x1 - x2) / 2, dy2 = (y1 - y2) / 2
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2

    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
        let s = lambda.squareRoot()
        rx *= s
        ry *= s
    }

    let sign: Double = (largeArc != sweep) ? 1 : -1
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    let co = den == 0 ? 0 : sign * max(0, num / den).squareRoot()
    let cxp = co * (rx * y1p / ry)
    let cyp = co * -(ry * x1p / rx)

    let cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2

    func angleBetween(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
        var a = acos(min(1, max(-1, len == 0 ? 1 : dot / len)))
        if ux * vy - uy * vx < 0 { a = -a }
        return a
    }

    let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry

    let theta1 = angleBetween(1, 0, ux, uy)
    var dtheta = angleBetween(ux, uy, vx, vy)
    if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
    if sweep, dtheta < 0 { dtheta += 2 * .pi }

    let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
    let delta = dtheta / Double(segments)
    let alpha = sin(delta) * ((4 + 3 * pow(tan(delta / 2), 2)).squareRoot() - 1) / 3

    func ellipsePoint(_ theta: Double) -> (Double, Double) {
        let x = cx + rx * cosPhi * cos(theta) - ry * sinPhi * sin(theta)
        let y = cy + rx * sinPhi * cos(theta) + ry * cosPhi * sin(theta)
        return (x, y)
    }
    func ellipseDerivative(_ theta: Double) -> (Double, Double) {
        let dx = -rx * cosPhi * sin(theta) - ry * sinPhi * cos(theta)
        let dy = -rx * sinPhi * sin(theta) + ry * cosPhi * cos(theta)
        return (dx, dy)
    }

    for i in 0..<segments {
        let t1 = theta1 + Double(i) * delta
        let t2 = t1 + delta
        let p1 = ellipsePoint(t1)
        let p2 = ellipsePoint(t2)
        let d1 = ellipseDerivative(t1)
        let d2 = ellipseDerivative(t2)

        let q1 = (p1.0 + alpha * d1.0, p1.1 + alpha * d1.1)
        let q2 = (p2.0 - alpha * d2.0, p2.1 - alpha * d2.1)

        path.addCurve(to: project(p2.0, p2.1), control1: project(q1.0, q1.1), control2: project(q2.0, q2.1))
    }
}

/// Interprets one SVG path's `d` attribute (M/m, L/l, V/v, H/h, C/c, A/a, Z/z — the commands
/// Lucide's `hand` and `hand-fist` icons use) and appends the resulting geometry to `path`,
/// scaling from the source's 24×24 viewBox into `rect`.
private func appendSVGPath(_ d: String, to path: inout Path, rect: CGRect) {
    let scale = min(rect.width, rect.height) / 24
    func project(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(y) * scale)
    }

    var scanner = SVGPathScanner(d)
    var current = (x: 0.0, y: 0.0)
    var subpathStart = (x: 0.0, y: 0.0)

    while let command = scanner.nextCommand() {
        var activeCommand = command
        var isFirstIteration = true
        while isFirstIteration || scanner.hasNumber() {
            isFirstIteration = false
            switch activeCommand {
            case "M":
                current = (scanner.number(), scanner.number())
                path.move(to: project(current.x, current.y))
                subpathStart = current
                activeCommand = "L"
            case "m":
                current = (current.x + scanner.number(), current.y + scanner.number())
                path.move(to: project(current.x, current.y))
                subpathStart = current
                activeCommand = "l"
            case "L":
                current = (scanner.number(), scanner.number())
                path.addLine(to: project(current.x, current.y))
            case "l":
                current = (current.x + scanner.number(), current.y + scanner.number())
                path.addLine(to: project(current.x, current.y))
            case "H":
                current = (scanner.number(), current.y)
                path.addLine(to: project(current.x, current.y))
            case "h":
                current = (current.x + scanner.number(), current.y)
                path.addLine(to: project(current.x, current.y))
            case "V":
                current = (current.x, scanner.number())
                path.addLine(to: project(current.x, current.y))
            case "v":
                current = (current.x, current.y + scanner.number())
                path.addLine(to: project(current.x, current.y))
            case "C":
                let c1 = (scanner.number(), scanner.number())
                let c2 = (scanner.number(), scanner.number())
                let end = (scanner.number(), scanner.number())
                path.addCurve(to: project(end.0, end.1), control1: project(c1.0, c1.1), control2: project(c2.0, c2.1))
                current = end
            case "c":
                let origin = current
                let c1 = (origin.x + scanner.number(), origin.y + scanner.number())
                let c2 = (origin.x + scanner.number(), origin.y + scanner.number())
                let end = (origin.x + scanner.number(), origin.y + scanner.number())
                path.addCurve(to: project(end.0, end.1), control1: project(c1.0, c1.1), control2: project(c2.0, c2.1))
                current = end
            case "A", "a":
                let rx = scanner.number(), ry = scanner.number()
                let rotation = scanner.number()
                let largeArc = scanner.flag()
                let sweep = scanner.flag()
                var end = (scanner.number(), scanner.number())
                if activeCommand == "a" {
                    end = (current.x + end.0, current.y + end.1)
                }
                appendArcSegment(
                    to: &path,
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    xAxisRotationDegrees: rotation,
                    largeArc: largeArc,
                    sweep: sweep,
                    project: project
                )
                current = end
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                // Unsupported command — not used by `hand`/`hand-fist`; stop consuming this
                // subpath rather than looping forever.
                isFirstIteration = false
                return
            }
        }
    }
}

/// Lucide's `hand` icon (open palm) — the *watching*/*paused* glyph.
struct LucideHandShape: Shape {
    private static let pathData = [
        "M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2",
        "M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2",
        "M10 10.5V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2v8",
        "M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15",
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for d in Self.pathData {
            appendSVGPath(d, to: &path, rect: rect)
        }
        return path
    }
}

/// Lucide's `hand-fist` icon (clenched fist) — the *armed*/*fired* glyph: "the clutch IS a fist."
struct LucideHandFistShape: Shape {
    private static let pathData = [
        "M12.035 17.012a3 3 0 0 0-3-3l-.311-.002a.72.72 0 0 1-.505-1.229l1.195-1.195A2 2 0 0 1 10.828 11H12a2 2 0 0 0 0-4H9.243a3 3 0 0 0-2.122.879l-2.707 2.707A4.83 4.83 0 0 0 3 14a8 8 0 0 0 8 8h2a8 8 0 0 0 8-8V7a2 2 0 1 0-4 0v2a2 2 0 1 0 4 0",
        "M13.888 9.662A2 2 0 0 0 17 8V5A2 2 0 1 0 13 5",
        "M9 5A2 2 0 1 0 5 5V10",
        "M9 7V4A2 2 0 1 1 13 4V7.268",
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for d in Self.pathData {
            appendSVGPath(d, to: &path, rect: rect)
        }
        return path
    }
}

/// Renders the menu bar/popover glyph as a stroked Lucide icon at `size` points: `hand` for
/// *watching*/*paused*, `hand-fist` for *armed*/*fired* (spec: "the clutch IS a fist"). Stroke
/// width scales from Lucide's own `stroke-width="2"` in its 24-unit viewBox, so it stays
/// proportional at any render size (menu bar 18pt, popover header 26pt).
struct LucideMenuBarIcon: View {
    var state: GlyphState
    var size: CGFloat

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 2 * (size / 24), lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        Group {
            switch state {
            case .watching, .paused:
                LucideHandShape().stroke(MenuBarGlyph.color(for: state), style: strokeStyle)
            case .armed, .fired:
                LucideHandFistShape().stroke(MenuBarGlyph.color(for: state), style: strokeStyle)
            }
        }
        .frame(width: size, height: size)
    }
}
