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
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// `.playOnHover` never auto-plays under Reduce Motion (spec: hover-driven motion is exactly
    /// the kind of incidental animation Reduce Motion opts out of) — it behaves as `.posterOnly`
    /// instead, leaving the detail hero's explicit `.loop` as the only way Reduce Motion users see
    /// this gesture move, and only after they've deliberately opened the card.
    private var effectiveMode: Mode {
        if mode == .playOnHover, reduceMotion { return .posterOnly }
        return mode
    }

    private var isPlaying: Bool {
        switch effectiveMode {
        case .loop: true
        case .posterOnly: false
        case .playOnHover: isHovered
        }
    }

    @ViewBuilder
    private func movBody(_ url: URL) -> some View {
        if isPlaying {
            LoopingVideoLayer(url: url)
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
            if let image = NSImage(contentsOf: url) {
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

    var body: some View {
        LoopingVideoLayerRepresentable(url: url)
            .id(url)
    }
}

private struct LoopingVideoLayerRepresentable: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.start(url: url)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.start(url: url)
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
        player.play()
    }

    func stop() {
        queuePlayer?.pause()
        playerLayer.player = nil
        looper = nil
        queuePlayer = nil
        currentURL = nil
    }
}
