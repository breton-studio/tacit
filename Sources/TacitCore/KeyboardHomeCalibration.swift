import Foundation

public enum ImageHandSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

public struct KeyboardHandFeatures: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var boundingBoxWidth: Double
    public var boundingBoxHeight: Double
    public var boundingBoxArea: Double
    public var confidentJointCount: Int

    public init?(
        frame: LandmarkFrame,
        confidenceThreshold: Double = 0.7,
        minimumJoints: Int = 3
    ) {
        let points = frame.joints.values.filter { $0.confidence >= confidenceThreshold }
        guard points.count >= minimumJoints,
              let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max()
        else { return nil }

        centerX = points.map(\.x).reduce(0, +) / Double(points.count)
        centerY = points.map(\.y).reduce(0, +) / Double(points.count)
        boundingBoxWidth = maxX - minX
        boundingBoxHeight = maxY - minY
        boundingBoxArea = boundingBoxWidth * boundingBoxHeight
        confidentJointCount = points.count
    }
}

public enum LiftDirection: String, Codable, Sendable {
    case lower
    case higher
}

public struct KeyboardLiftRule: Codable, Equatable, Sendable {
    public var side: ImageHandSide
    public var direction: LiftDirection
    public var enterCenterY: Double
    public var exitCenterY: Double
    public var typingMedianCenterY: Double
    public var liftedMedianCenterY: Double
    public var separationAUC: Double

    public init(
        side: ImageHandSide,
        direction: LiftDirection,
        enterCenterY: Double,
        exitCenterY: Double,
        typingMedianCenterY: Double,
        liftedMedianCenterY: Double,
        separationAUC: Double
    ) {
        self.side = side
        self.direction = direction
        self.enterCenterY = enterCenterY
        self.exitCenterY = exitCenterY
        self.typingMedianCenterY = typingMedianCenterY
        self.liftedMedianCenterY = liftedMedianCenterY
        self.separationAUC = separationAUC
    }

    public func isEnterValue(_ value: Double) -> Bool {
        switch direction {
        case .lower: value <= enterCenterY
        case .higher: value >= enterCenterY
        }
    }

    public func isExitValue(_ value: Double) -> Bool {
        switch direction {
        case .lower: value >= exitCenterY
        case .higher: value <= exitCenterY
        }
    }
}

public struct KeyboardHomeCalibrationProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cameraID: String
    public var cameraName: String
    public var cameraDeviceType: String
    public var captureWidth: Int?
    public var captureHeight: Int?
    public var imageSplitX: Double
    public var confidenceThreshold: Double
    public var minimumConfidentJoints: Int
    public var enterFrames: Int
    public var exitFrames: Int
    public var leftRule: KeyboardLiftRule
    public var rightRule: KeyboardLiftRule
    public var createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        cameraID: String,
        cameraName: String,
        cameraDeviceType: String,
        captureWidth: Int? = nil,
        captureHeight: Int? = nil,
        imageSplitX: Double,
        confidenceThreshold: Double = 0.7,
        minimumConfidentJoints: Int = 15,
        enterFrames: Int = 3,
        exitFrames: Int = 3,
        leftRule: KeyboardLiftRule,
        rightRule: KeyboardLiftRule,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.cameraDeviceType = cameraDeviceType
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.imageSplitX = imageSplitX
        self.confidenceThreshold = confidenceThreshold
        self.minimumConfidentJoints = minimumConfidentJoints
        self.enterFrames = enterFrames
        self.exitFrames = exitFrames
        self.leftRule = leftRule
        self.rightRule = rightRule
        self.createdAt = createdAt
    }

    public var isCurrent: Bool { schemaVersion == Self.currentSchemaVersion }
}

public struct KeyboardCalibrationInput: Sendable {
    public var cameraID: String
    public var cameraName: String
    public var cameraDeviceType: String
    public var captureWidth: Int?
    public var captureHeight: Int?
    public var typing: [[LandmarkFrame]]
    public var leftLift: [[LandmarkFrame]]
    public var rightLift: [[LandmarkFrame]]

    public init(
        cameraID: String,
        cameraName: String,
        cameraDeviceType: String,
        captureWidth: Int? = nil,
        captureHeight: Int? = nil,
        typing: [[LandmarkFrame]],
        leftLift: [[LandmarkFrame]],
        rightLift: [[LandmarkFrame]]
    ) {
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.cameraDeviceType = cameraDeviceType
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.typing = typing
        self.leftLift = leftLift
        self.rightLift = rightLift
    }
}

public enum KeyboardCalibrationFailure: Error, Equatable, Sendable {
    case insufficientTypingFrames
    case insufficientTargetVisibility(side: ImageHandSide, rate: Double)
    case insufficientSeparation(side: ImageHandSide, auc: Double)
    case ambiguousHandMapping
}

public enum KeyboardHomeCalibrator {
    public static let confidenceThreshold = 0.7
    public static let minimumConfidentJoints = 15
    public static let minimumQualifiedRate = 0.8
    public static let minimumSeparationAUC = 0.9

    public static func derive(
        from input: KeyboardCalibrationInput
    ) -> Result<KeyboardHomeCalibrationProfile, KeyboardCalibrationFailure> {
        let typingPairs = input.typing.compactMap(sidePair)
        guard typingPairs.count >= 12 else { return .failure(.insufficientTypingFrames) }

        let split = median(typingPairs.map { ($0.left.centerX + $0.right.centerX) / 2 })
        let typingValues: [ImageHandSide: [Double]] = [
            .left: typingPairs.map(\.left.centerY),
            .right: typingPairs.map(\.right.centerY),
        ]

        let leftResult = deriveRule(
            physicalSide: .left,
            typingValues: typingValues,
            liftFrames: input.leftLift,
            split: split
        )
        guard case .success(let leftRule) = leftResult else {
            if case .failure(let failure) = leftResult { return .failure(failure) }
            fatalError("unreachable calibration result")
        }

        let rightResult = deriveRule(
            physicalSide: .right,
            typingValues: typingValues,
            liftFrames: input.rightLift,
            split: split
        )
        guard case .success(let rightRule) = rightResult else {
            if case .failure(let failure) = rightResult { return .failure(failure) }
            fatalError("unreachable calibration result")
        }
        guard leftRule.side != rightRule.side else {
            return .failure(.ambiguousHandMapping)
        }

        return .success(KeyboardHomeCalibrationProfile(
            cameraID: input.cameraID,
            cameraName: input.cameraName,
            cameraDeviceType: input.cameraDeviceType,
            captureWidth: input.captureWidth,
            captureHeight: input.captureHeight,
            imageSplitX: split,
            confidenceThreshold: confidenceThreshold,
            minimumConfidentJoints: minimumConfidentJoints,
            leftRule: leftRule,
            rightRule: rightRule
        ))
    }

    private static func deriveRule(
        physicalSide: ImageHandSide,
        typingValues: [ImageHandSide: [Double]],
        liftFrames: [[LandmarkFrame]],
        split: Double
    ) -> Result<KeyboardLiftRule, KeyboardCalibrationFailure> {
        let imageSide = inferredImageSide(
            typingValues: typingValues,
            liftFrames: liftFrames,
            split: split
        )
        let targets = liftFrames.compactMap {
            targetFeatures(in: $0, side: imageSide, split: split)
        }
        let qualified = targets.filter { $0.confidentJointCount >= minimumConfidentJoints }
        let rate = Double(qualified.count) / Double(max(liftFrames.count, 1))
        guard rate >= minimumQualifiedRate else {
            return .failure(.insufficientTargetVisibility(side: physicalSide, rate: rate))
        }

        let baseline = typingValues[imageSide] ?? []
        let liftedValues = qualified.map(\.centerY)
        let rawAUC = auc(positive: liftedValues, negative: baseline)
        let separation = max(rawAUC, 1 - rawAUC)
        guard separation >= minimumSeparationAUC else {
            return .failure(.insufficientSeparation(side: physicalSide, auc: separation))
        }

        let typingMedian = median(baseline)
        let liftedMedian = median(liftedValues)
        let direction: LiftDirection = liftedMedian < typingMedian ? .lower : .higher
        let midpoint = (typingMedian + liftedMedian) / 2
        let hysteresis = abs(typingMedian - liftedMedian) * 0.1
        let exit = direction == .lower ? midpoint + hysteresis : midpoint - hysteresis

        return .success(KeyboardLiftRule(
            side: imageSide,
            direction: direction,
            enterCenterY: midpoint,
            exitCenterY: exit,
            typingMedianCenterY: typingMedian,
            liftedMedianCenterY: liftedMedian,
            separationAUC: separation
        ))
    }

    /// Infers which image half moved for the instructed physical hand. Camera mirroring is not
    /// stable across built-in, external, Continuity, and Desk View devices, so physical left
    /// must never be assumed to mean image-left. This inference intentionally uses every minimally
    /// observable hand (not only 15/21-qualified hands); the chosen side is quality-gated only
    /// afterward, so a low-quality lifted hand cannot be replaced by a crisp resting hand.
    private static func inferredImageSide(
        typingValues: [ImageHandSide: [Double]],
        liftFrames: [[LandmarkFrame]],
        split: Double
    ) -> ImageHandSide {
        ImageHandSide.allCases.max { lhs, rhs in
            displacement(
                side: lhs,
                typingValues: typingValues,
                liftFrames: liftFrames,
                split: split
            ) < displacement(
                side: rhs,
                typingValues: typingValues,
                liftFrames: liftFrames,
                split: split
            )
        } ?? .left
    }

    private static func displacement(
        side: ImageHandSide,
        typingValues: [ImageHandSide: [Double]],
        liftFrames: [[LandmarkFrame]],
        split: Double
    ) -> Double {
        guard let baseline = typingValues[side], !baseline.isEmpty else { return 0 }
        let lifted = liftFrames.compactMap {
            targetFeatures(in: $0, side: side, split: split)?.centerY
        }
        guard !lifted.isEmpty else { return 0 }
        return abs(median(lifted) - median(baseline))
    }

    private static func sidePair(_ frames: [LandmarkFrame]) -> (left: KeyboardHandFeatures, right: KeyboardHandFeatures)? {
        let features = frames.compactMap {
            KeyboardHandFeatures(
                frame: $0,
                confidenceThreshold: confidenceThreshold,
                minimumJoints: minimumConfidentJoints
            )
        }.sorted { $0.centerX < $1.centerX }
        guard features.count >= 2, let first = features.first, let last = features.last else {
            return nil
        }
        return (first, last)
    }

    private static func targetFeatures(
        in frames: [LandmarkFrame],
        side: ImageHandSide,
        split: Double
    ) -> KeyboardHandFeatures? {
        let features = frames.compactMap {
            KeyboardHandFeatures(frame: $0, confidenceThreshold: confidenceThreshold)
        }
        let candidates = features.filter { side == .left ? $0.centerX < split : $0.centerX >= split }
        return candidates.max { $0.confidentJointCount < $1.confidentJointCount }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func auc(positive: [Double], negative: [Double]) -> Double {
        var score = 0.0
        for positiveValue in positive {
            for negativeValue in negative {
                if positiveValue > negativeValue {
                    score += 1
                } else if positiveValue == negativeValue {
                    score += 0.5
                }
            }
        }
        return score / Double(positive.count * negative.count)
    }
}

public enum KeyboardLiftState: String, Codable, Equatable, Sendable {
    case unavailable
    case resting
    case leftLifted
    case rightLifted
    case bothLifted
}

public struct KeyboardLiftDetector: Sendable {
    private struct SideState: Sendable {
        var lifted = false
        var enterCount = 0
        var exitCount = 0
    }

    private var left = SideState()
    private var right = SideState()

    public init() {}

    public mutating func ingest(
        _ frames: [LandmarkFrame],
        profile: KeyboardHomeCalibrationProfile
    ) -> KeyboardLiftState {
        guard profile.isCurrent else {
            reset()
            return .unavailable
        }

        Self.update(
            &left,
            features: Self.features(in: frames, side: profile.leftRule.side, profile: profile),
            rule: profile.leftRule,
            profile: profile
        )
        Self.update(
            &right,
            features: Self.features(in: frames, side: profile.rightRule.side, profile: profile),
            rule: profile.rightRule,
            profile: profile
        )

        switch (left.lifted, right.lifted) {
        case (false, false): return .resting
        case (true, false): return .leftLifted
        case (false, true): return .rightLifted
        case (true, true): return .bothLifted
        }
    }

    public mutating func reset() {
        left = SideState()
        right = SideState()
    }

    private static func features(
        in frames: [LandmarkFrame],
        side: ImageHandSide,
        profile: KeyboardHomeCalibrationProfile
    ) -> KeyboardHandFeatures? {
        let features = frames.compactMap {
            KeyboardHandFeatures(frame: $0, confidenceThreshold: profile.confidenceThreshold)
        }
        let candidates = features.filter {
            side == .left ? $0.centerX < profile.imageSplitX : $0.centerX >= profile.imageSplitX
        }
        return candidates.max { $0.confidentJointCount < $1.confidentJointCount }
    }

    private static func update(
        _ state: inout SideState,
        features: KeyboardHandFeatures?,
        rule: KeyboardLiftRule,
        profile: KeyboardHomeCalibrationProfile
    ) {
        guard let features, features.confidentJointCount >= profile.minimumConfidentJoints else {
            state.enterCount = 0
            state.exitCount += 1
            if state.exitCount >= profile.exitFrames { state.lifted = false }
            return
        }

        if state.lifted {
            if rule.isExitValue(features.centerY) {
                state.exitCount += 1
                if state.exitCount >= profile.exitFrames {
                    state.lifted = false
                    state.enterCount = 0
                }
            } else {
                state.exitCount = 0
            }
        } else if rule.isEnterValue(features.centerY) {
            state.enterCount += 1
            state.exitCount = 0
            if state.enterCount >= profile.enterFrames {
                state.lifted = true
                state.enterCount = 0
            }
        } else {
            state.enterCount = 0
            state.exitCount = 0
        }
    }
}
