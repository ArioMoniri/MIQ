import Foundation

/// Decides what to do with a background render's result once it lands, given
/// that the state it was computed from may have been replaced meanwhile.
///
/// The preview owns one gate. Every swap of the backing volume (fresh parse,
/// cache-hit preparation, 4D expansion, a streamed volume source) calls
/// `advance()`; a render takes a `ticket()` when it starts and asks
/// `decision(for:cancelled:)` when it finishes:
/// - `.discard` — the render was cancelled (superseded by a newer gesture or a
///   torn-down preview): show nothing from it.
/// - `.applyPixelsOnly` — the state changed under it: its pixels are still the
///   best thing to show until the follow-up render the swap scheduled lands, but
///   any value *derived* from its buffer (the auto window it computed) must not
///   be remembered, because that buffer is no longer current.
/// - `.apply` — current: show it and memoize what it derived.
public struct RenderGenerationGate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case discard
        case applyPixelsOnly
        case apply
    }

    /// The generation the newest state belongs to. Wraps on overflow, so it is
    /// only ever compared for equality.
    public private(set) var current: Int

    public init(current: Int = 0) {
        self.current = current
    }

    /// Marks the backing state as replaced; outstanding tickets become stale.
    public mutating func advance() {
        current &+= 1
    }

    /// The ticket a render captures at start.
    public func ticket() -> Int { current }

    /// Whether `ticket` still names the newest state.
    public func isCurrent(_ ticket: Int) -> Bool { ticket == current }

    public func decision(for ticket: Int, cancelled: Bool) -> Decision {
        if cancelled { return .discard }
        return isCurrent(ticket) ? .apply : .applyPixelsOnly
    }
}
