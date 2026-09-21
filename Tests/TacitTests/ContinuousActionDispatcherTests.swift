import AppKit
import Testing
import TacitCore
@testable import Tacit

@MainActor
private final class ContinuousSpy {
    var application = FrontmostApplication(bundleIdentifier: "com.apple.Safari", name: "Safari")
    var scrolls: [(Double, Double, ContinuousEventModifiers)] = []
    var mouse: [(ContinuousMousePhase, ContinuousEventModifiers)] = []
    var zoomSteps: [Int] = []

    func environment() -> ContinuousActionEnvironment {
        ContinuousActionEnvironment(
            frontmostApplication: { [unowned self] in self.application },
            pointerLocation: { CGPoint(x: 100, y: 100) },
            postScroll: { [unowned self] x, y, modifiers in
                self.scrolls.append((x, y, modifiers)); return true
            },
            postMiddleMouse: { [unowned self] phase, _, modifiers in
                self.mouse.append((phase, modifiers)); return true
            },
            postZoomStep: { [unowned self] direction in
                self.zoomSteps.append(direction); return true
            }
        )
    }
}

private func continuousResult(x: Double = 0, y: Double = 0, zoom: Double = 0) -> ModifierHandResult {
    ModifierHandResult(
        state: .engaged,
        controllerFrame: nil,
        sample: ModifierControlSample(
            translationX: x,
            translationY: y,
            zoomDelta: zoom,
            timestamp: 1
        ),
        consumesDiscreteGesture: true
    )
}

@Test func targetAppsResolveToTheirNativeProfiles() {
    #expect(ContinuousAppProfile.resolve(FrontmostApplication(bundleIdentifier: "com.figma.Desktop", name: "Figma")) == .figma)
    #expect(ContinuousAppProfile.resolve(FrontmostApplication(bundleIdentifier: "org.blenderfoundation.blender", name: "Blender")) == .blender)
    #expect(ContinuousAppProfile.resolve(FrontmostApplication(bundleIdentifier: "com.autodesk.mas.fusion360", name: "Autodesk Fusion 360")) == .fusion360)
    #expect(ContinuousAppProfile.resolve(FrontmostApplication(bundleIdentifier: "com.apple.Terminal", name: "Terminal")) == .standard)
}

@MainActor
@Test func figmaPansWithScrollAndZoomsWithCommandScroll() {
    let spy = ContinuousSpy()
    spy.application = .init(bundleIdentifier: "com.figma.Desktop", name: "Figma")
    let dispatcher = ContinuousActionDispatcher(environment: spy.environment())

    dispatcher.update(continuousResult(x: 0.1, y: -0.2))
    dispatcher.update(continuousResult(zoom: 0.03))

    #expect(spy.scrolls.count == 2)
    #expect(spy.scrolls[0].2.isEmpty)
    #expect(spy.scrolls[1].2 == [.command])
}

@MainActor
@Test func blenderUsesShiftMiddleDragAndAlwaysReleasesOnDisengage() {
    let spy = ContinuousSpy()
    spy.application = .init(bundleIdentifier: "org.blenderfoundation.blender", name: "Blender")
    let dispatcher = ContinuousActionDispatcher(environment: spy.environment())

    dispatcher.update(continuousResult(x: 0.1))
    dispatcher.update(.init(state: .ready, controllerFrame: nil, sample: nil, consumesDiscreteGesture: false))

    #expect(spy.mouse.map(\.0) == [.down, .dragged, .up])
    #expect(spy.mouse.allSatisfy { $0.1 == [.shift] })
}

@MainActor
@Test func fusionUsesUnmodifiedMiddleDragAndStandardAppsUseScroll() {
    let fusionSpy = ContinuousSpy()
    fusionSpy.application = .init(bundleIdentifier: "com.autodesk.fusion360", name: "Fusion 360")
    let fusion = ContinuousActionDispatcher(environment: fusionSpy.environment())
    fusion.update(continuousResult(y: 0.1))
    fusion.reset()

    let safariSpy = ContinuousSpy()
    let safari = ContinuousActionDispatcher(environment: safariSpy.environment())
    safari.update(continuousResult(y: 0.1))
    safari.update(continuousResult(zoom: 0.03))
    safari.update(continuousResult(zoom: 0.03))
    safari.update(continuousResult(zoom: 0.03))

    #expect(fusionSpy.mouse.map(\.0) == [.down, .dragged, .up])
    #expect(fusionSpy.mouse.allSatisfy { $0.1.isEmpty })
    #expect(safariSpy.scrolls.count == 1)
    #expect(safariSpy.zoomSteps == [1])
}
