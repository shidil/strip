import os

/// Centralized `os_signpost` instrumentation for Strip's performance hot paths (Phase 0 of the
/// optimization plan). The headline metric — chord→motion latency — is otherwise unmeasurable, so
/// these intervals/events are the prerequisite for every later optimization.
///
/// **Zero-cost when not recording:** the os subsystem short-circuits begin/end/emit calls when no
/// Instruments session is listening, so this is safe to leave compiled in.
///
/// **Hot-path safety:** all names are `StaticString` and every bit of metadata is emitted via
/// `os` log-message interpolation (which is non-allocating — no Swift `String` is built), so these
/// are safe to call inside the display-link `tick` loop. Never pass a pre-built `String` here.
///
/// To observe: Instruments → os_signpost instrument (or `xctrace`), filter subsystem
/// `io.github.shidil.strip`, category `hotpath`.
public enum Signpost {
    public static let log = OSSignposter(subsystem: "io.github.shidil.strip", category: "hotpath")
}
