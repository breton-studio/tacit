import Foundation
import Testing
@testable import TacitCore

private func translated(_ frame: LandmarkFrame, dx: Double = 0, dy: Double = 0, t: TimeInterval) -> LandmarkFrame {
    LandmarkFrame(
        timestamp: t,
        joints: frame.joints.mapValues {
            JointPoint(x: $0.x + dx, y: $0.y + dy, confidence: $0.confidence)
        },
        handedness: frame.handedness
    )
}

private func scaled(_ frame: LandmarkFrame, by scale: Double, t: TimeInterval) -> LandmarkFrame {
    let centerX = frame.joints.values.map(\.x).reduce(0, +) / Double(frame.joints.count)
    let centerY = frame.joints.values.map(\.y).reduce(0, +) / Double(frame.joints.count)
    return LandmarkFrame(
        timestamp: t,
        joints: frame.joints.mapValues {
            JointPoint(
                x: centerX + ($0.x - centerX) * scale,
                y: centerY + ($0.y - centerY) * scale,
                confidence: $0.confidence
            )
        },
        handedness: frame.handedness
    )
}

private func profile(for frame: LandmarkFrame) -> ModifierHandProfile {
    let features = KeyboardHandFeatures(frame: frame, confidenceThreshold: 0.5, minimumJoints: 8)!
    return ModifierHandProfile(
        cameraID: "camera",
        controllerHand: .left,
        imageSide: .left,
        splitX: 0.62,
        baselineCenterY: features.centerY
    )
}

@Test func modifierProfileUsesCalibratedPhysicalToImageMapping() {
    let leftRule = KeyboardLiftRule(
        side: .right,
        direction: .higher,
        enterCenterY: 0.5,
        exitCenterY: 0.45,
        typingMedianCenterY: 0.4,
        liftedMedianCenterY: 0.6,
        separationAUC: 0.98
    )
    let rightRule = KeyboardLiftRule(
        side: .left,
        direction: .higher,
        enterCenterY: 0.5,
        exitCenterY: 0.45,
        typingMedianCenterY: 0.41,
        liftedMedianCenterY: 0.61,
        separationAUC: 0.98
    )
    let keyboard = KeyboardHomeCalibrationProfile(
        cameraID: "brio",
        cameraName: "BRIO",
        cameraDeviceType: "external",
        imageSplitX: 0.52,
        leftRule: leftRule,
        rightRule: rightRule
    )

    let left = ModifierHandProfile(keyboardProfile: keyboard, controllerHand: .left)
    let right = ModifierHandProfile(keyboardProfile: keyboard, controllerHand: .right)
    #expect(left.imageSide == .right)
    #expect(left.baselineCenterY == 0.4)
    #expect(right.imageSide == .left)
    #expect(right.baselineCenterY == 0.41)
}

@Test func controllerRequiresThreeClosedFramesThenEmitsPalmNormalizedMotion() {
    let base = SyntheticHand.pinch(.index, closed: true, t: 0)
    let profile = profile(for: base)
    var controller = ModifierHandController()

    let first = controller.ingest([translated(base, t: 0)], profile: profile)
    let second = controller.ingest([translated(base, t: 0.07)], profile: profile)
    let third = controller.ingest([translated(base, t: 0.14)], profile: profile)
    let moved = controller.ingest([translated(base, dx: 0.08, t: 0.21)], profile: profile)

    #expect(first.state == .ready)
    #expect(second.state == .ready)
    #expect(third.state == .engaged)
    #expect(third.sample == nil)
    #expect(!third.consumesDiscreteGesture)
    #expect(moved.state == .engaged)
    #expect((moved.sample?.translationX ?? 0) > 0.2)
    #expect(abs(moved.sample?.translationY ?? 1) < 0.01)
    #expect(moved.consumesDiscreteGesture)
}

@Test func apparentHandScaleBecomesZoomAndReleaseCarriesConsumption() {
    let base = SyntheticHand.pinch(.index, closed: true, t: 0)
    let profile = profile(for: base)
    var controller = ModifierHandController()
    _ = controller.ingest([translated(base, t: 0)], profile: profile)
    _ = controller.ingest([translated(base, t: 0.07)], profile: profile)
    _ = controller.ingest([translated(base, t: 0.14)], profile: profile)

    let zoom = controller.ingest([scaled(base, by: 1.15, t: 0.21)], profile: profile)
    let open = SyntheticHand.pinch(.index, closed: false, t: 0.28)
    let release = controller.ingest([open], profile: profile)

    #expect((zoom.sample?.zoomDelta ?? 0) > 0.1)
    #expect(zoom.consumesDiscreteGesture)
    #expect(release.state == .ready)
    #expect(release.consumesDiscreteGesture)
}

@Test func leavingCalibratedZoneEndsEngagementAndFailsClosed() {
    let base = SyntheticHand.pinch(.index, closed: true, t: 0)
    let profile = profile(for: base)
    var controller = ModifierHandController()
    _ = controller.ingest([translated(base, t: 0)], profile: profile)
    _ = controller.ingest([translated(base, t: 0.07)], profile: profile)
    _ = controller.ingest([translated(base, t: 0.14)], profile: profile)

    let outside = controller.ingest([translated(base, dx: 0.8, t: 0.21)], profile: profile)
    let returned = controller.ingest([translated(base, t: 0.28)], profile: profile)

    #expect(outside.state == .outsideZone)
    #expect(outside.sample == nil)
    #expect(returned.state == .ready)
}
