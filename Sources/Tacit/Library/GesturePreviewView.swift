import AVFoundation
import AVKit
import SwiftUI
import TacitCore

/// Resolves the (as-yet unshipped) gesture preview assets that Task 8 will bundle: a looping
/// HEVC-alpha `.mov` and a poster `.png` per `GestureID`, at
/// `Tacit.app/Contents/Resources/previews/<rawValue>.{mov,png}` (see `scripts/make-app.sh`).
///
/// This app is a bare, hand-rolled `.app` bundle (no `Bundle.module` — see `Package.swift`: the
/// `Tacit` executable target has no resources of its own besides `Info.plist`, which
/// `make-app.sh` copies by hand), so resolution goes through `Bundle.main.resourceURL` rather than
/// SwiftPM's generated resource bundle. That also means: when the binary is run bare (e.g.
/// `.build/release/Tacit` directly, as `swift test`/local dev sometimes does) rather than launched
/// as `Tacit.app`, `Bundle.main.resourceURL` can be nil or point somewhere with no `previews`
/// directory — both cases must resolve to `nil`, not crash, so every call site's fallback path is
/// reachable.
enum PreviewAssets {
    /// Per-gesture resolved URLs, computed once and cached — 23 stat() calls total across the
    /// app's lifetime instead of one pair per render of every card.
    private struct Resolved {
        var mov: URL?
        var poster: URL?
    }

    private static let cache: [GestureID: Resolved] = {
        var result: [GestureID: Resolved] = [:]
        let fileManager = FileManager.default
        let previewsDirectory = Bundle.main.resourceURL?.appendingPathComponent("previews", isDirectory: true)
        for id in GestureID.allCases {
            guard let previewsDirectory else {
                result[id] = Resolved(mov: nil, poster: nil)
                continue
            }
            let movURL = previewsDirectory.appendingPathComponent("\(id.rawValue).mov")
            let posterURL = previewsDirectory.appendingPathComponent("\(id.rawValue).png")
            result[id] = Resolved(
                mov: fileManager.fileExists(atPath: movURL.path) ? movURL : nil,
                poster: fileManager.fileExists(atPath: posterURL.path) ? posterURL : nil
            )
        }
        return result
    }()

    /// The bundled `.mov` for `gesture`, or `nil` if it isn't present (Task 8 hasn't shipped it
    /// yet, or the app is running unbundled).
    static func movURL(for gesture: GestureID) -> URL? {
        cache[gesture]?.mov
    }

    /// The bundled poster `.png` for `gesture`, or `nil` under the same conditions as `movURL`.
    static func posterURL(for gesture: GestureID) -> URL? {
        cache[gesture]?.poster
    }
}

/// Decoded poster `NSImage`s, cached once per gesture. `posterBody` used to call
/// `NSImage(contentsOf:)` fresh on every render; since `MappingStore` is one shared
/// `@ObservedObject` across every card in the grid, a single toggle flip re-renders (and, without
/// this cache, re-decodes) every visible card's poster PNG synchronously on the main thread.
/// `@MainActor`-isolated rather than a plain dictionary: decode always happens from a SwiftUI
/// view body (already main-actor), so no actor-hopping is needed, just single-writer safety.
@MainActor
private enum PosterImageCache {
    private static var images: [GestureID: NSImage] = [:]

    static func image(for gesture: GestureID, url: URL) -> NSImage? {
        if let cached = images[gesture] {
            return cached
        }
        guard let decoded = NSImage(contentsOf: url) else { return nil }
        images[gesture] = decoded
        return decoded
    }
}

/// The Library's gesture preview slot: plays the bundled looping cartoon-hand `.mov` when one
/// exists, falls back to the poster PNG when only that exists, and — the case that matters until
/// Task 8 ships real assets — falls all the way back to the existing `ConstellationRenderer` look
/// when NEITHER exists, so the app renders exactly as it did before this type existed.
///
/// Takes the whole `entry` (not just `gesture`) so the constellation fallback can render
/// `entry.cannedFrame` without a second catalog lookup at the call site.
struct GesturePreviewView: View {
    var entry: CatalogEntry
    var mode: Mode
    /// Color for the constellation fallback ONLY (real preview assets have no equivalent — a
    /// baked HEVC clip can't recolor itself). Defaults to `.primary`, matching every existing
    /// call site except `CardDetailView`'s hero, which threads through its previewCandidate
    /// accent-lighting so that behavior survives verbatim through the fallback path.
    var constellationColor: Color = .primary
    /// True while something else needs this preview's video paused without unmounting it — e.g.
    /// `CardDetailView` pausing its `.loop` hero while the Try-It overlay's own copy of this view
    /// is open on top of it, so the two aren't both decoding at once, and resuming afterward
    /// resumes the SAME player mid-frame instead of flashing back to the poster. Has no effect
    /// unless a video is actually mounted (`.posterOnly`/hover-idle states ignore it). Defaults to
    /// `false` for every call site that doesn't need this (every one except `CardDetailView`'s
    /// hero today).
    var isSuspended: Bool = false

    enum Mode {
        /// Always playing, muted, looped — the detail hero.
        case loop
        /// Poster (or constellation) only, never plays — reserved for contexts that never
        /// animate at all.
        case posterOnly
        /// Poster (or constellation) at rest; plays only while hovered — the grid card. Never
        /// auto-plays under Reduce Motion (`effectiveMode` below downgrades it to `.posterOnly`).
        case playOnHover
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// Reduce-Motion-only: whether the user has explicitly clicked play on a `.loop`-mode preview
    /// (Ruling 4: "Reduce Motion: poster only, video plays on explicit click"). Ignored entirely
    /// when Reduce Motion is off, and irrelevant for `.posterOnly`/`.playOnHover`, which never show
    /// the play affordance.
    @State private var isManuallyPlaying = false

    private var gesture: GestureID { entry.id }

    var body: some View {
        ZStack {
            if let movURL = PreviewAssets.movURL(for: gesture) {
                movBody(movURL)
            } else if let posterURL = PreviewAssets.posterURL(for: gesture) {
                posterBody(posterURL)
            } else {
                constellationFallback
            }

            if showsManualPlaybackControl {
                manualPlaybackButton
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// `.playOnHover` never auto-plays under Reduce Motion (spec: hover-driven motion is exactly
    /// the kind of incidental animation Reduce Motion opts out of) — it behaves as `.posterOnly`
    /// instead. `.loop` gets the SAME downgrade under Reduce Motion (Ruling 4: "poster only, video
    /// plays on explicit click") rather than a parallel mechanism — it only escapes back to
    /// `.loop` once the user has explicitly clicked the play affordance below
    /// (`isManuallyPlaying`), and reverts to the poster the moment they click again.
    private var effectiveMode: Mode {
        guard reduceMotion else { return mode }
        switch mode {
        case .playOnHover: return .posterOnly
        case .loop: return isManuallyPlaying ? .loop : .posterOnly
        case .posterOnly: return .posterOnly
        }
    }

    private var isPlaying: Bool {
        switch effectiveMode {
        case .loop: true
        case .posterOnly: false
        case .playOnHover: isHovered
        }
    }

    /// The click-to-play affordance only ever applies to `.loop`-mode previews (the detail hero
    /// and Try-It's own preview copy) under Reduce Motion — `.playOnHover` stays poster-only with
    /// no way to force playback (hover has no "explicit click" equivalent), and plain
    /// `.posterOnly` contexts never animate regardless of the motion setting. Also gated on an
    /// actual `.mov` existing for this gesture: with no video asset, `body`'s top-level
    /// if/else-if falls straight to the poster (or constellation) branch regardless of play
    /// state, so there'd be nothing for a "Play" tap to start — showing the control anyway would
    /// be a dead button.
    private var showsManualPlaybackControl: Bool {
        mode == .loop && reduceMotion && PreviewAssets.movURL(for: gesture) != nil
    }

    /// Plain-verb, monochrome, 44pt play/pause toggle (spec §4: plain verbs, 44pt target, no new
    /// accent use, honors Reduce Motion by construction since it only ever appears while Reduce
    /// Motion is on). `TacitMotion.respecting` always yields `nil` (instant) here since Reduce
    /// Motion is a precondition of this button existing at all — spelled out anyway so the token
    /// stays the single source of truth rather than a bare `nil`/magic literal.
    private var manualPlaybackButton: some View {
        Button {
            isManuallyPlaying.toggle()
        } label: {
            Image(systemName: isManuallyPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(TacitMotion.respecting(reduceMotion, TacitMotion.pressFeedback), value: isManuallyPlaying)
        .accessibilityLabel(isManuallyPlaying ? "Pause" : "Play")
    }

    @ViewBuilder
    private func movBody(_ url: URL) -> some View {
        if isPlaying {
            LoopingVideoLayer(url: url, isSuspended: isSuspended)
        } else if let posterURL = PreviewAssets.posterURL(for: gesture) {
            posterBody(posterURL)
        } else {
            // A `.mov` with no poster: hold on the constellation fallback at rest rather than
            // presenting nothing, since there's no still image to show.
            constellationFallback
        }
    }

    private func posterBody(_ url: URL) -> some View {
        Group {
            if let image = PosterImageCache.image(for: gesture, url: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                constellationFallback
            }
        }
    }

    private var constellationFallback: some View {
        ConstellationRenderer(
            frame: entry.cannedFrame,
            lineWidth: 1.5,
            color: constellationColor,
            fitToJoints: true
        )
    }
}

/// A muted, looping `AVPlayerLayer` presentation of a single HEVC-alpha `.mov`, wrapped for
/// SwiftUI. Owns an `AVQueuePlayer` + `AVPlayerLooper` for gapless looping and tears both down on
/// disappear — nothing here stays alive (and decoding frames) once the view isn't on screen, so
/// hovering across a grid of 23 cards never accumulates idle players.
private struct LoopingVideoLayer: View {
    var url: URL
    var isSuspended: Bool

    var body: some View {
        LoopingVideoLayerRepresentable(url: url, isSuspended: isSuspended)
            .id(url)
    }
}

private struct LoopingVideoLayerRepresentable: NSViewRepresentable {
    var url: URL
    var isSuspended: Bool

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.start(url: url)
        view.setSuspended(isSuspended)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.start(url: url)
        nsView.setSuspended(isSuspended)
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.stop()
    }
}

/// Hosts one `AVPlayerLayer` sized to its view via `AVLayerVideoGravity.resizeAspect`, with a
/// clear (not black) layer background so the HEVC-with-alpha source's transparency composites
/// over whatever SwiftUI content sits behind it, exactly like the constellation it replaces.
private final class PlayerLayerView: NSView {
    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private let playerLayer = AVPlayerLayer()
    private var currentURL: URL?
    private var isSuspended = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func start(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        queuePlayer = player
        if !isSuspended {
            player.play()
        }
    }

    /// Pauses/resumes the SAME player+looper in place — deliberately not `stop()`/`start()`,
    /// which would tear the looper down and restart the decode from frame zero: the whole point
    /// (Task M4 fix-wave finding 3) is that the Try-It overlay opening over this hero pauses it
    /// without a poster flash or a restart on resume.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        guard let queuePlayer else { return }
        if suspended {
            queuePlayer.pause()
        } else {
            queuePlayer.play()
        }
    }

    /// `disableLooping()` before dropping references: `AVPlayerLooper` installs a boundary-time
    /// observer on the queue player that captures the looper itself, so simply nilling both
    /// objects doesn't reliably break that internal retain cycle (Apple's own guidance) — with 23
    /// hoverable grid cards, "sweep the mouse across the grid" is the primary way this view gets
    /// used, so every hover in/out is a fresh leak candidate without this.
    func stop() {
        looper?.disableLooping()
        queuePlayer?.pause()
        playerLayer.player = nil
        looper = nil
        queuePlayer = nil
        currentURL = nil
    }

    deinit {
        // Same teardown as `dismantleNSView`'s `stop()`, as a safety net for any path that drops
        // the last reference to this view without SwiftUI ever calling `dismantleNSView` on it.
        looper?.disableLooping()
        queuePlayer?.pause()
        looper = nil
        queuePlayer = nil
    }
}
