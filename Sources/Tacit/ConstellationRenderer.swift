import SwiftUI
import TacitCore

/// Draws a hand's 21 landmarks as a "constellation" of dots joined by bones — the app's core
/// visual identity, reused later by the menu bar glyph, HUD, and library cards.
///
/// Coordinates in `LandmarkFrame` are normalized 0...1 with origin at the LOWER-LEFT (y up, per
/// Vision's convention). SwiftUI's `Canvas` origin is upper-left (y down), so `project` flips y.
///
/// A joint or bone whose landmark is missing from `frame` (below the confidence floor, or just
/// never observed) is skipped entirely rather than substituted or interpolated — the resulting
/// gap in the line-art is a deliberate degraded-state signal, not a bug.
struct ConstellationRenderer: View {
    var frame: LandmarkFrame
    var lineWidth: CGFloat = 1.5
    var color: Color = .primary
    /// 0...1 stroke-trim for the draw-on animation; 1 = fully drawn. Bones reveal from the wrist
    /// outward (see `drawOrder`); the currently-animating bone is drawn as a partial segment.
    var drawProgress: Double = 1.0
    /// When `true`, scale-to-fit the bounding box of the joints actually PRESENT in `frame`
    /// (aspect preserved, centered, small inset) instead of the normalized unit square. Falls
    /// back to unit-square fit if the present joints have a zero-size bounding box (0 or 1 point).
    /// Default `false` preserves existing (position-preserving) behavior for the live preview;
    /// glyph/HUD/card uses set this `true` so a canned frame (e.g. the menu bar glyph's fist,
    /// which doesn't occupy the full unit square) fills its small render target.
    var fitToJoints: Bool = false

    /// `ConstellationTopology.bones` reordered by graph distance from the wrist — wrist spokes
    /// first (distance 1), then each finger's proximal→distal segments outward (distance 2, 3, 4)
    /// — so the draw-on animation reads as radiating out from the wrist. Computed once (BFS over
    /// the bone graph) rather than per frame/draw call.
    private static let drawOrder: [(HandJoint, HandJoint)] = {
        var depth: [HandJoint: Int] = [.wrist: 0]
        var frontier: [HandJoint] = [.wrist]
        while !frontier.isEmpty {
            var next: [HandJoint] = []
            for joint in frontier {
                for (a, b) in ConstellationTopology.bones {
                    if a == joint, depth[b] == nil {
                        depth[b] = depth[joint]! + 1
                        next.append(b)
                    } else if b == joint, depth[a] == nil {
                        depth[a] = depth[joint]! + 1
                        next.append(a)
                    }
                }
            }
            frontier = next
        }
        return ConstellationTopology.bones.enumerated()
            .sorted { lhs, rhs in
                let lhsDistance = max(depth[lhs.element.0] ?? 0, depth[lhs.element.1] ?? 0)
                let rhsDistance = max(depth[rhs.element.0] ?? 0, depth[rhs.element.1] ?? 0)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.offset < rhs.offset  // stable tiebreak: original topology order
            }
            .map(\.element)
    }()

    /// Dot radius scales with `lineWidth`; at the default 1.5pt line this is exactly 2pt.
    private var dotRadius: CGFloat { lineWidth * 4.0 / 3.0 }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let bbox = fitToJoints ? jointsBoundingBox() : nil
            let boneCount = Self.drawOrder.count
            guard boneCount > 0 else { return }

            var visibleJoints = Set<HandJoint>()

            for (index, bone) in Self.drawOrder.enumerated() {
                guard let startPoint = frame.point(bone.0), let endPoint = frame.point(bone.1) else {
                    continue  // missing joint: leave a gap, deliberately.
                }

                let fraction = revealFraction(forBoneAt: index, of: boneCount)
                guard fraction > 0 else { continue }

                let start = project(startPoint, in: rect, bbox: bbox)
                let end = project(endPoint, in: rect, bbox: bbox)
                let tip = fraction >= 1
                    ? end
                    : CGPoint(
                        x: start.x + (end.x - start.x) * fraction,
                        y: start.y + (end.y - start.y) * fraction
                    )

                var path = Path()
                path.move(to: start)
                path.addLine(to: tip)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                visibleJoints.insert(bone.0)
                visibleJoints.insert(bone.1)
            }

            for joint in visibleJoints {
                guard let point = frame.point(joint) else { continue }
                let center = project(point, in: rect, bbox: bbox)
                let dotRect = CGRect(
                    x: center.x - dotRadius, y: center.y - dotRadius,
                    width: dotRadius * 2, height: dotRadius * 2
                )
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
            }
        }
    }

    /// How much of the bone at `index` (of `count`, in `drawOrder`) should be drawn for the
    /// current `drawProgress`: 0 = not yet started, 1 = fully drawn, in between = partially drawn
    /// (linear interpolation along the segment). Bone `i` finishes drawing once
    /// `drawProgress >= (i+1)/count`.
    private func revealFraction(forBoneAt index: Int, of count: Int) -> Double {
        let threshold = Double(index + 1) / Double(count)
        let previousThreshold = Double(index) / Double(count)
        if drawProgress >= threshold { return 1 }
        if drawProgress <= previousThreshold { return 0 }
        return (drawProgress - previousThreshold) / (threshold - previousThreshold)
    }

    /// Bounding box (in normalized 0...1, origin lower-left coordinates) of every joint actually
    /// present in `frame`. `nil` if fewer than 2 present joints, or if they're coincident (zero
    /// width and height) — both degenerate cases the caller should treat as "fall back to
    /// unit-square fit".
    private func jointsBoundingBox() -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let points = frame.joints.values
        guard points.count >= 2 else { return nil }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        guard maxX > minX, maxY > minY else { return nil }
        return (minX, minY, maxX, maxY)
    }

    /// Maps a normalized (0...1, origin lower-left, y up) landmark into canvas space (origin
    /// upper-left, y down), scaling to fit `rect` while preserving aspect ratio, centered, with a
    /// small inset so joint dots don't clip the view's edge.
    ///
    /// When `bbox` is non-nil (i.e. `fitToJoints` is set and the present joints have a non-zero
    /// bounding box), that bounding box — not the full unit square — is what's scaled to fit,
    /// so a canned frame occupying only a small corner of the unit square (e.g. the glyph's fist)
    /// still fills the render target.
    private func project(
        _ point: JointPoint,
        in rect: CGRect,
        bbox: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
    ) -> CGPoint {
        let inset = dotRadius + 1
        let usable = rect.insetBy(dx: inset, dy: inset)
        let side = max(0, min(usable.width, usable.height))
        let originX = usable.midX - side / 2
        let originY = usable.midY - side / 2

        let normalizedX: Double
        let normalizedY: Double
        if let bbox {
            let width = bbox.maxX - bbox.minX
            let height = bbox.maxY - bbox.minY
            let extent = max(width, height)  // preserve aspect: fit the LARGER dimension to the square
            let cx = (bbox.minX + bbox.maxX) / 2
            let cy = (bbox.minY + bbox.maxY) / 2
            normalizedX = (point.x - cx) / extent + 0.5
            normalizedY = (point.y - cy) / extent + 0.5
        } else {
            normalizedX = point.x
            normalizedY = point.y
        }

        let x = originX + CGFloat(normalizedX) * side
        let y = originY + (1 - CGFloat(normalizedY)) * side  // y-flip
        return CGPoint(x: x, y: y)
    }
}
