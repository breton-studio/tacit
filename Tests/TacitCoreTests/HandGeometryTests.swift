import Foundation
import Testing
@testable import TacitCore

// MARK: - Brief tests (verbatim)

@Test func palmSizeIsWristToMiddleMCP() {
    let f = SyntheticHand.openPalm()
    let w = f.point(.wrist)!, m = f.point(.middleMCP)!
    let expected = ((w.x - m.x) * (w.x - m.x) + (w.y - m.y) * (w.y - m.y)).squareRoot()
    #expect(abs(HandGeometry.palmSize(f)! - expected) < 1e-9)
}

@Test func openPalmFingersExtended() {
    let f = SyntheticHand.openPalm()
    for finger in Finger.allCases {
        #expect(HandGeometry.isFingerExtended(finger, in: f, margin: 1.15) == true)
    }
}

@Test func fistFingersNotExtended() {
    let f = SyntheticHand.looseFist()
    for finger in [Finger.index, .middle, .ring, .little] {
        #expect(HandGeometry.isFingerExtended(finger, in: f, margin: 1.15) == false)
    }
}

@Test func closedPinchHasSmallNormalizedDistance() {
    let closed = SyntheticHand.pinch(.index, closed: true)
    let open = SyntheticHand.pinch(.index, closed: false)
    #expect(HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: closed)! < 0.3)
    #expect(HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: open)! > 0.8)
}

@Test func missingJointsYieldNil() {
    let empty = LandmarkFrame(timestamp: 0, joints: [:], handedness: .unknown)
    #expect(HandGeometry.palmSize(empty) == nil)
    #expect(HandGeometry.isFingerExtended(.index, in: empty, margin: 1.15) == nil)
}

// MARK: - Synthetic pose sanity checks
//
// Every later gesture classifier (StaticPoseClassifier and friends) is built on the
// assumption that these signatures hold for the corresponding SyntheticHand pose.
// Keep these green whenever SyntheticHand's coordinates are tuned.

private func isExtended(_ finger: Finger, _ frame: LandmarkFrame) -> Bool {
    HandGeometry.isFingerExtended(finger, in: frame, margin: 1.15) == true
}

@Test func syntheticOpenPalmSignature() {
    let f = SyntheticHand.openPalm()
    for finger in Finger.allCases {
        #expect(isExtended(finger, f), "\(finger) should be extended in openPalm")
    }
}

@Test func syntheticLooseFistSignature() {
    let f = SyntheticHand.looseFist()
    for finger in [Finger.index, .middle, .ring, .little] {
        #expect(!isExtended(finger, f), "\(finger) should not be extended in looseFist")
    }
    #expect(HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: f)! > 0.35)
}

@Test func syntheticIndexPointSignature() {
    let f = SyntheticHand.indexPoint()
    #expect(isExtended(.index, f))
    for finger in [Finger.thumb, .middle, .ring, .little] {
        #expect(!isExtended(finger, f), "\(finger) should not be extended in indexPoint")
    }
}

@Test func syntheticVictorySignature() {
    let f = SyntheticHand.victory()
    #expect(isExtended(.index, f))
    #expect(isExtended(.middle, f))
    for finger in [Finger.thumb, .ring, .little] {
        #expect(!isExtended(finger, f), "\(finger) should not be extended in victory")
    }
    #expect(HandGeometry.normalizedDistance(.indexTip, .middleTip, in: f)! >= 0.45)
}

@Test func syntheticThumbsUpSignature() {
    let f = SyntheticHand.thumbsUp()
    #expect(isExtended(.thumb, f))
    for finger in [Finger.index, .middle, .ring, .little] {
        #expect(!isExtended(finger, f), "\(finger) should not be extended in thumbsUp")
    }
    #expect(f.point(.thumbTip)!.y > f.point(.indexMCP)!.y)
}

@Test func syntheticPinchSignature() {
    for finger in [Finger.index, .middle, .ring, .little] {
        let closed = SyntheticHand.pinch(finger, closed: true)
        let open = SyntheticHand.pinch(finger, closed: false)
        let targetTip: HandJoint = {
            switch finger {
            case .thumb, .index: return .indexTip
            case .middle: return .middleTip
            case .ring: return .ringTip
            case .little: return .littleTip
            }
        }()
        #expect(HandGeometry.normalizedDistance(.thumbTip, targetTip, in: closed)! < 0.3)
        #expect(HandGeometry.normalizedDistance(.thumbTip, targetTip, in: open)! > 0.6)
    }
}

@Test func syntheticTypingHandMatchesNoPoseSignature() {
    let f = SyntheticHand.typingHand()

    // openPalm: all five extended.
    let openPalmSignature = Finger.allCases.allSatisfy { isExtended($0, f) }
    #expect(!openPalmSignature)

    // looseFist: index/middle/ring/little not extended AND thumb-index distance > 0.35.
    let nonThumbAllCurled = [Finger.index, .middle, .ring, .little].allSatisfy { !isExtended($0, f) }
    let thumbIndexDistance = HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: f)!
    let looseFistSignature = nonThumbAllCurled && thumbIndexDistance > 0.35
    #expect(!looseFistSignature)

    // indexPoint: only index extended.
    let indexPointSignature = isExtended(.index, f)
        && [Finger.thumb, .middle, .ring, .little].allSatisfy { !isExtended($0, f) }
    #expect(!indexPointSignature)

    // victory: exactly index+middle extended, tips spread >= 0.45 normalized.
    let tipSpread = HandGeometry.normalizedDistance(.indexTip, .middleTip, in: f) ?? 0
    let victorySignature = isExtended(.index, f) && isExtended(.middle, f)
        && [Finger.thumb, .ring, .little].allSatisfy { !isExtended($0, f) }
        && tipSpread >= 0.45
    #expect(!victorySignature)

    // thumbsUp: only thumb extended, thumbTip above indexMCP.
    let thumbsUpSignature = isExtended(.thumb, f)
        && [Finger.index, .middle, .ring, .little].allSatisfy { !isExtended($0, f) }
        && (f.point(.thumbTip)?.y ?? 0) > (f.point(.indexMCP)?.y ?? 0)
    #expect(!thumbsUpSignature)
}
