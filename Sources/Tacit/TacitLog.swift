import OSLog

/// Unified-logging categories for `Tacit` (bundle id `studio.breton.tacit`). Purely diagnostic —
/// no behavior depends on any of these calls. Watch live with, e.g.:
///
///     log stream --process Tacit --level info --style compact
///
/// or filter to one category with `--predicate 'category == "engine"'` etc.
enum TacitLog {
    static let engine = Logger(subsystem: "studio.breton.tacit", category: "engine")
    static let actions = Logger(subsystem: "studio.breton.tacit", category: "actions")
    static let capture = Logger(subsystem: "studio.breton.tacit", category: "capture")
}
