import AppKit
import ApplicationServices
import TacitCore

struct FrontmostApplication: Equatable {
    var bundleIdentifier: String
    var name: String
}

enum ContinuousAppProfile: String, Equatable {
    case figma
    case blender
    case fusion360
    case standard

    static func resolve(_ application: FrontmostApplication?) -> ContinuousAppProfile {
        guard let application else { return .standard }
        let identifier = application.bundleIdentifier.lowercased()
        let name = application.name.lowercased()

        if identifier == "com.figma.desktop" || name == "figma" { return .figma }
        if identifier == "org.blenderfoundation.blender" || name.contains("blender") { return .blender }
        if identifier.contains("autodesk") && identifier.contains("fusion") || name.contains("fusion 360") {
            return .fusion360
        }
        return .standard
    }
}

struct ContinuousEventModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let command = ContinuousEventModifiers(rawValue: 1 << 0)
    static let shift = ContinuousEventModifiers(rawValue: 1 << 1)
}

enum ContinuousMousePhase: Equatable {
    case down
    case dragged
    case up
}

/// Injected boundary around CoreGraphics so app-profile routing can be unit tested without moving
/// the user's real pointer or posting input events.
struct ContinuousActionEnvironment {
    var frontmostApplication: () -> FrontmostApplication?
    var pointerLocation: () -> CGPoint
    var postScroll: (_ horizontal: Double, _ vertical: Double, _ modifiers: ContinuousEventModifiers) -> Bool
    var postMiddleMouse: (_ phase: ContinuousMousePhase, _ location: CGPoint, _ modifiers: ContinuousEventModifiers) -> Bool
    var postZoomStep: (_ direction: Int) -> Bool

    static func live() -> ContinuousActionEnvironment {
        ContinuousActionEnvironment(
            frontmostApplication: {
                guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
                return FrontmostApplication(
                    bundleIdentifier: application.bundleIdentifier ?? "",
                    name: application.localizedName ?? ""
                )
            },
            pointerLocation: { CGEvent(source: nil)?.location ?? .zero },
            postScroll: { horizontal, vertical, modifiers in
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(vertical.rounded()),
                    wheel2: Int32(horizontal.rounded()),
                    wheel3: 0
                ) else { return false }
                event.flags = cgFlags(modifiers)
                event.post(tap: .cghidEventTap)
                return true
            },
            postMiddleMouse: { phase, location, modifiers in
                let eventType: CGEventType = switch phase {
                case .down: .otherMouseDown
                case .dragged: .otherMouseDragged
                case .up: .otherMouseUp
                }
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: eventType,
                    mouseCursorPosition: location,
                    mouseButton: .center
                ) else { return false }
                event.flags = cgFlags(modifiers)
                event.post(tap: .cghidEventTap)
                return true
            },
            postZoomStep: { direction in
                // ANSI '=' (24) is '+' with Shift; ANSI '-' is 27. Most browsers, Finder, and
                // terminals honor Command-plus/minus even when they ignore modified wheel events.
                let keyCode: CGKeyCode = direction > 0 ? 24 : 27
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
                else { return false }
                var flags: CGEventFlags = [.maskCommand]
                if direction > 0 { flags.insert(.maskShift) }
                down.flags = flags
                up.flags = flags
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return true
            }
        )
    }
}

private func cgFlags(_ modifiers: ContinuousEventModifiers) -> CGEventFlags {
    var flags = CGEventFlags()
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    return flags
}

/// Turns controller-hand deltas into the native input shape the frontmost app expects.
///
/// - Figma: two-axis pixel scrolling pans; Command-scroll zooms.
/// - Blender: Shift-middle drag pans; wheel zooms.
/// - Fusion 360: middle drag pans; wheel zooms.
/// - Browsers, Finder, Terminal, and every safe fallback: two-axis scroll; Command +/- zoom.
@MainActor
final class ContinuousActionDispatcher {
    private let environment: ContinuousActionEnvironment
    private var activeProfile: ContinuousAppProfile?
    private var pointer = CGPoint.zero
    private var middleMouseIsDown = false
    private var zoomAccumulator = 0.0

    private static let motionScale = 420.0
    private static let scrollScale = 520.0
    private static let zoomPriorityThreshold = 0.012
    private static let wheelZoomScale = 1_800.0
    private static let steppedZoomThreshold = 0.075

    init(environment: ContinuousActionEnvironment = .live()) {
        self.environment = environment
    }

    func update(_ result: ModifierHandResult) {
        guard result.state == .engaged else {
            endEngagement()
            return
        }

        if activeProfile == nil {
            activeProfile = .resolve(environment.frontmostApplication())
            pointer = environment.pointerLocation()
        }
        guard let profile = activeProfile, let sample = result.sample else { return }

        let planarMagnitude = hypot(sample.translationX, sample.translationY)
        let zooming = abs(sample.zoomDelta) >= Self.zoomPriorityThreshold
            && abs(sample.zoomDelta) >= planarMagnitude * 0.45
        switch profile {
        case .figma:
            if zooming {
                _ = environment.postScroll(0, sample.zoomDelta * Self.wheelZoomScale, [.command])
            } else {
                _ = environment.postScroll(
                    sample.translationX * Self.scrollScale,
                    sample.translationY * Self.scrollScale,
                    []
                )
            }

        case .blender, .fusion360:
            if zooming {
                releaseMiddleMouseIfNeeded()
                _ = environment.postScroll(0, sample.zoomDelta * Self.wheelZoomScale, [])
            } else {
                let modifiers: ContinuousEventModifiers = profile == .blender ? [.shift] : []
                if !middleMouseIsDown {
                    middleMouseIsDown = environment.postMiddleMouse(.down, pointer, modifiers)
                }
                guard middleMouseIsDown else { return }
                pointer.x += sample.translationX * Self.motionScale
                // Vision coordinates are lower-left/y-up; Quartz global pointer coordinates are
                // upper-left/y-down. Negate y so the synthetic drag follows the physical hand.
                pointer.y -= sample.translationY * Self.motionScale
                _ = environment.postMiddleMouse(.dragged, pointer, modifiers)
            }

        case .standard:
            if zooming {
                zoomAccumulator += sample.zoomDelta
                while abs(zoomAccumulator) >= Self.steppedZoomThreshold {
                    let direction = zoomAccumulator > 0 ? 1 : -1
                    _ = environment.postZoomStep(direction)
                    zoomAccumulator -= Double(direction) * Self.steppedZoomThreshold
                }
            } else {
                _ = environment.postScroll(
                    sample.translationX * Self.scrollScale,
                    sample.translationY * Self.scrollScale,
                    []
                )
            }
        }
    }

    func reset() {
        endEngagement()
    }

    private func endEngagement() {
        releaseMiddleMouseIfNeeded()
        activeProfile = nil
        zoomAccumulator = 0
    }

    private func releaseMiddleMouseIfNeeded() {
        guard middleMouseIsDown else { return }
        let modifiers: ContinuousEventModifiers = activeProfile == .blender ? [.shift] : []
        _ = environment.postMiddleMouse(.up, pointer, modifiers)
        middleMouseIsDown = false
    }
}
