import ApplicationServices

/// A small identity-keyed memo cache for values that are **immutable for the lifetime of the
/// key**. Used by `AccessibilityService` to avoid re-paying AX IPC for per-window attributes that
/// never change (`role`, `subrole`, resizability) on every enumeration scan (perf 2.5a).
///
/// Invalidation is explicit and conservative: callers prune to the set of keys they actually saw
/// this scan via `retain(_:)`, so entries for closed windows don't accumulate. There is no implicit
/// TTL — a cached value is assumed valid as long as its key keeps showing up. Only ever cache
/// genuinely-immutable attributes here; mutable ones (frame, minimized) must be read live.
///
/// Not thread-safe. Confine all access to a single queue (the enumeration queue, post-2.5b).
final class AXAttrCache<Key: Hashable, Value> {
    private var store: [Key: Value] = [:]

    /// Return the cached value for `key`, computing and storing it on a miss.
    func value(for key: Key, compute: () -> Value) -> Value {
        if let hit = store[key] { return hit }
        let v = compute()
        store[key] = v
        return v
    }

    /// Drop every entry whose key isn't in `seen` — call once per scan with the keys touched, so
    /// elements that have gone away stop occupying the cache.
    func retain(_ seen: Set<Key>) {
        guard store.count != seen.count else {
            // Fast path: same size *and* same keys means nothing to prune. Verify membership cheaply
            // only when sizes match (the common steady-state case is "saw exactly what we cached").
            if store.keys.allSatisfy(seen.contains) { return }
            store = store.filter { seen.contains($0.key) }
            return
        }
        store = store.filter { seen.contains($0.key) }
    }

    /// Number of live entries (for tests / diagnostics).
    var count: Int { store.count }
}

/// A `Hashable` wrapper over `AXUIElement` so it can key a dictionary. Two `AXUIElement`s referring
/// to the same UI element compare equal via `CFEqual` (and share a `CFHash`), so the same window's
/// element keys the same cache entry across separate enumeration scans.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
