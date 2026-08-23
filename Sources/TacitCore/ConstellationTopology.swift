import Foundation

/// Pure data description of the hand "skeleton" used to draw the constellation line-art:
/// which pairs of `HandJoint`s are connected by a visible bone.
///
/// TacitCore imports Foundation only — this is data, no rendering.
public enum ConstellationTopology {
    /// Exactly 20 bones: 5 wrist spokes (wrist→thumbCMC/indexMCP/middleMCP/ringMCP/littleMCP)
    /// plus each finger's chain (thumb: CMC→MP→IP→Tip = 3 bones; the other four fingers each
    /// MCP→PIP→DIP→Tip = 3 bones × 4 fingers = 12 bones). 5 + 3 + 12 = 20.
    public static let bones: [(HandJoint, HandJoint)] = [
        // Wrist spokes.
        (.wrist, .thumbCMC),
        (.wrist, .indexMCP),
        (.wrist, .middleMCP),
        (.wrist, .ringMCP),
        (.wrist, .littleMCP),

        // Thumb chain.
        (.thumbCMC, .thumbMP),
        (.thumbMP, .thumbIP),
        (.thumbIP, .thumbTip),

        // Index chain.
        (.indexMCP, .indexPIP),
        (.indexPIP, .indexDIP),
        (.indexDIP, .indexTip),

        // Middle chain.
        (.middleMCP, .middlePIP),
        (.middlePIP, .middleDIP),
        (.middleDIP, .middleTip),

        // Ring chain.
        (.ringMCP, .ringPIP),
        (.ringPIP, .ringDIP),
        (.ringDIP, .ringTip),

        // Little chain.
        (.littleMCP, .littlePIP),
        (.littlePIP, .littleDIP),
        (.littleDIP, .littleTip),
    ]
}
