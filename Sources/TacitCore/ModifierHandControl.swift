import Foundation

/// The physical hand used as Tacit's resting controller. Camera mirroring is intentionally not
/// encoded here: `KeyboardHomeCalibrationProfile` already learned the physical-to-image mapping
/// for each camera, so changing this setting remains correct for built-in and external cameras.
public enum ControllerHand: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right

    public var displayName: String { rawValue.capitalized }
}

public enum ModifierHandState: String, Codable, Equatable, Sendable {
    case unavailable
    case outsideZone
    case ready
    case engaged
}

/// One continuous, per-frame controller update. Translation is expressed in palm units so the
/// same motion works at different camera distances; zoom is the logarithmic palm-size change, a
/// useful monocular proxy for motion toward/away from the camera.
public struct ModifierControlSample: Equatable, Sendable {
    public var translationX: Double
    public var translationY: Double
    public var zoomDelta: Double
    public var timestamp: TimeInterval

    public init(
        translationX: Double,
        translationY: Double,
        zoomDelta: Double,
        timestamp: TimeInterval
    ) {
        self.translationX = translationX
        self.translationY = translationY
        self.zoomDelta = zoomDelta
        self.timestamp = timestamp
    }
}

public struct ModifierHandResult: Equatable, Sendable {
    public var state: ModifierHandState
    public var controllerFrame: LandmarkFrame?
    public var sample: ModifierControlSample?
    /// True after a pinch has moved far enough to be a continuous gesture, including its release
    /// frame. This prevents that release from also becoming a thumb-index app-switch tap.
    public var consumesDiscreteGesture: Bool

    public init(
        state: ModifierHandState,
        controllerFrame: LandmarkFrame?,
        sample: ModifierControlSample?,
        consumesDiscreteGesture: Bool
    ) {
        self.state = state
        self.controllerFrame = controllerFrame
        self.sample = sample
        self.consumesDiscreteGesture = consumesDiscreteGesture
    }
}

/// The controller zone derived from the camera's keyboard calibration. Its image half comes from
/// the explicitly recorded physical hand lift, not Vision's handedness guess, so mirrored cameras
/// are handled correctly. The generous vertical band permits pan/zoom travel while still keeping
/// the keyboard area as the physical clutch.
public struct ModifierHandProfile: Equatable, Sendable {
    public var cameraID: String
    public var controllerHand: ControllerHand
    public var imageSide: ImageHandSide
    public var splitX: Double
    public var baselineCenterY: Double
    public var verticalRadius: Double
    public var pinchCloseThreshold: Double
    public var pinchOpenThreshold: Double

    public init(
        cameraID: String,
        controllerHand: ControllerHand,
        imageSide: ImageHandSide,
        splitX: Double,
        baselineCenterY: Double,
        verticalRadius: Double = 0.34,
        pinchCloseThreshold: Double = 0.35,
        pinchOpenThreshold: Double = 0.60
    ) {
        self.cameraID = cameraID
        self.controllerHand = controllerHand
        self.imageSide = imageSide
        self.splitX = splitX
        self.baselineCenterY = baselineCenterY
        self.verticalRadius = verticalRadius
        self.pinchCloseThreshold = pinchCloseThreshold
        self.pinchOpenThreshold = pinchOpenThreshold
    }

    public init(keyboardProfile: KeyboardHomeCalibrationProfile, controllerHand: ControllerHand) {
        let rule = controllerHand == .left ? keyboardProfile.leftRule : keyboardProfile.rightRule
        self.init(
            cameraID: keyboardProfile.cameraID,
            controllerHand: controllerHand,
            imageSide: rule.side,
            splitX: keyboardProfile.imageSplitX,
            baselineCenterY: rule.typingMedianCenterY
        )
    }

    public func contains(_ features: KeyboardHandFeatures, margin: Double = 0) -> Bool {
        let sideMatches: Bool
        switch imageSide {
        case .left: sideMatches = features.centerX <= splitX + 0.06 + margin
        case .right: sideMatches = features.centerX >= splitX - 0.06 - margin
        }
        return sideMatches && abs(features.centerY - baselineCenterY) <= verticalRadius + margin
    }
}

/// A zone-gated, Schmitt-triggered continuous controller for the non-mouse hand.
///
/// Engagement requires three consecutive closed-pinch frames. Translation and apparent depth are
/// low-pass filtered, and a small travel threshold separates an intentional pan/zoom from a quick
/// thumb-index tap. Leaving the calibrated zone or losing the hand always ends the engagement.
public struct ModifierHandController: Sendable {
    private var closedFrameCount = 0
    private var isPinched = false
    private var previousCenter: Point?
    private var previousPalmSize: Double?
    private var cumulativeTravel = 0.0
    private var consumedThisPinch = false
    private var xFilter = OneEuroFilter()
    private var yFilter = OneEuroFilter()
    private var zoomFilter = OneEuroFilter(minCutoff: 0.8, beta: 0.08)

    private static let engageFrames = 3
    private static let consumeTravel = 0.18
    private static let consumeZoom = 0.055

    private struct Point: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    public init() {}

    public mutating func ingest(
        _ frames: [LandmarkFrame],
        profile: ModifierHandProfile
    ) -> ModifierHandResult {
        guard let selected = selectControllerFrame(frames, profile: profile) else {
            resetEngagement()
            return ModifierHandResult(
                state: frames.isEmpty ? .unavailable : .outsideZone,
                controllerFrame: nil,
                sample: nil,
                consumesDiscreteGesture: false
            )
        }

        let frame = selected.frame
        guard let pinchDistance = HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame),
              let palmSize = HandGeometry.palmSize(frame), palmSize > 0
        else {
            resetEngagement()
            return ModifierHandResult(
                state: .ready,
                controllerFrame: frame,
                sample: nil,
                consumesDiscreteGesture: false
            )
        }

        let center = Point(x: selected.features.centerX, y: selected.features.centerY)
        let wasConsumed = consumedThisPinch

        if !isPinched {
            if pinchDistance < profile.pinchCloseThreshold {
                closedFrameCount += 1
                if closedFrameCount >= Self.engageFrames {
                    isPinched = true
                    previousCenter = center
                    previousPalmSize = palmSize
                    cumulativeTravel = 0
                    consumedThisPinch = false
                    resetFilters()
                }
            } else {
                closedFrameCount = 0
            }

            return ModifierHandResult(
                state: isPinched ? .engaged : .ready,
                controllerFrame: frame,
                sample: nil,
                consumesDiscreteGesture: false
            )
        }

        if pinchDistance > profile.pinchOpenThreshold {
            resetEngagement()
            return ModifierHandResult(
                state: .ready,
                controllerFrame: frame,
                sample: nil,
                consumesDiscreteGesture: wasConsumed
            )
        }

        guard let priorCenter = previousCenter, let priorPalmSize = previousPalmSize else {
            previousCenter = center
            previousPalmSize = palmSize
            return ModifierHandResult(
                state: .engaged,
                controllerFrame: frame,
                sample: nil,
                consumesDiscreteGesture: consumedThisPinch
            )
        }

        let rawX = (center.x - priorCenter.x) / palmSize
        let rawY = (center.y - priorCenter.y) / palmSize
        let rawZoom = log(palmSize / priorPalmSize)
        previousCenter = center
        previousPalmSize = palmSize

        cumulativeTravel += hypot(rawX, rawY)
        if cumulativeTravel >= Self.consumeTravel || abs(rawZoom) >= Self.consumeZoom {
            consumedThisPinch = true
        }

        let filteredSample = ModifierControlSample(
            translationX: xFilter.filter(rawX, at: frame.timestamp),
            translationY: yFilter.filter(rawY, at: frame.timestamp),
            zoomDelta: zoomFilter.filter(rawZoom, at: frame.timestamp),
            timestamp: frame.timestamp
        )
        return ModifierHandResult(
            state: .engaged,
            controllerFrame: frame,
            // Keep a quick, stationary pinch available to `PinchTapDetector`. Continuous output
            // starts only after travel/depth proves this engagement is a pan/zoom, at which point
            // the release is also suppressed as a discrete app-switch tap.
            sample: consumedThisPinch ? filteredSample : nil,
            consumesDiscreteGesture: consumedThisPinch
        )
    }

    public mutating func reset() {
        resetEngagement()
    }

    private func selectControllerFrame(
        _ frames: [LandmarkFrame],
        profile: ModifierHandProfile
    ) -> (frame: LandmarkFrame, features: KeyboardHandFeatures)? {
        frames.compactMap { frame -> (LandmarkFrame, KeyboardHandFeatures)? in
            guard let features = KeyboardHandFeatures(
                frame: frame,
                confidenceThreshold: 0.55,
                minimumJoints: 8
            ), profile.contains(features) else { return nil }
            return (frame, features)
        }.min { lhs, rhs in
            let lhsY = abs(lhs.1.centerY - profile.baselineCenterY)
            let rhsY = abs(rhs.1.centerY - profile.baselineCenterY)
            if lhsY != rhsY { return lhsY < rhsY }
            return HandGeometry.meanConfidence(lhs.0) > HandGeometry.meanConfidence(rhs.0)
        }
    }

    private mutating func resetEngagement() {
        closedFrameCount = 0
        isPinched = false
        previousCenter = nil
        previousPalmSize = nil
        cumulativeTravel = 0
        consumedThisPinch = false
        resetFilters()
    }

    private mutating func resetFilters() {
        xFilter.reset()
        yFilter.reset()
        zoomFilter.reset()
    }
}

/// The One Euro filter adapts to movement speed: stable at rest without making fast motion feel
/// sticky. This implementation is scalar and timestamp-driven so recorded fixture playback stays
/// deterministic.
private struct OneEuroFilter: Sendable {
    var minCutoff: Double = 1.0
    var beta: Double = 0.045
    var derivativeCutoff: Double = 1.0

    private var previousValue: Double?
    private var previousDerivative = 0.0
    private var previousTimestamp: TimeInterval?

    init(
        minCutoff: Double = 1.0,
        beta: Double = 0.045,
        derivativeCutoff: Double = 1.0
    ) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, at timestamp: TimeInterval) -> Double {
        guard let previousValue, let previousTimestamp else {
            self.previousValue = value
            self.previousTimestamp = timestamp
            return value
        }

        let dt = max(timestamp - previousTimestamp, 1.0 / 120.0)
        let derivative = (value - previousValue) / dt
        let filteredDerivative = lowPass(
            derivative,
            previous: previousDerivative,
            alpha: smoothingAlpha(cutoff: derivativeCutoff, dt: dt)
        )
        let cutoff = minCutoff + beta * abs(filteredDerivative)
        let filtered = lowPass(
            value,
            previous: previousValue,
            alpha: smoothingAlpha(cutoff: cutoff, dt: dt)
        )

        self.previousValue = filtered
        self.previousDerivative = filteredDerivative
        self.previousTimestamp = timestamp
        return filtered
    }

    mutating func reset() {
        previousValue = nil
        previousDerivative = 0
        previousTimestamp = nil
    }

    private func smoothingAlpha(cutoff: Double, dt: Double) -> Double {
        let timeConstant = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + timeConstant / dt)
    }

    private func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}
