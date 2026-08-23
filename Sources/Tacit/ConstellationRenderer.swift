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
            let boneCount = Self.drawOrder.count
            guard boneCount > 0 else { return }

            var visibleJoints = Set<HandJoint>()

            for (index, bone) in Self.drawOrder.enumerated() {
                guard let startPoint = frame.point(bone.0), let endPoint = frame.point(bone.1) else {
                    continue  // missing joint: leave a gap, deliberately.
                }

                let fraction = revealFraction(forBoneAt: index, of: boneCount)
                guard fraction > 0 else { continue }

                let start = project(startPoint, in: rect)
                let end = project(endPoint, in: rect)
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
                let center = project(point, in: rect)
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

    /// Maps a normalized (0...1, origin lower-left, y up) landmark into canvas space (origin
    /// upper-left, y down), scaling the unit square to fit `rect` while preserving aspect ratio,
    /// centered, with a small inset so joint dots don't clip the view's edge.
    private func project(_ point: JointPoint, in rect: CGRect) -> CGPoint {
        let inset = dotRadius + 1
        let usable = rect.insetBy(dx: inset, dy: inset)
        let side = max(0, min(usable.width, usable.height))
        let originX = usable.midX - side / 2
        let originY = usable.midY - side / 2
        let x = originX + CGFloat(point.x) * side
        let y = originY + (1 - CGFloat(point.y)) * side  // y-flip
        return CGPoint(x: x, y: y)
    }
}
