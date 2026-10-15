import Foundation

/// Runs synchronous, CPU- or I/O-heavy MIQCore work (a parse, a render) off the
/// caller's actor while keeping it tied to the caller's cancellation.
///
/// `Task.detached` deliberately does not inherit the parent's cancellation, so a
/// bare `await Task.detached { … }.value` keeps decoding a multi-GB volume after
/// the UI that asked for it has gone away. This helper forwards the caller's
/// cancellation into the detached task, where MIQCore's cancellable readers
/// (`Task.checkCancellation()` between gunzip windows and network chunks) stop
/// the work and release what they decoded so far.
///
/// - Parameters:
///   - priority: Priority of the detached task.
///   - operation: The work. It runs on a detached task, so it must capture only
///     `Sendable` values; it should poll `Task.checkCancellation()` at natural
///     boundaries (MIQCore's parsers already do).
/// - Returns: The operation's value.
/// - Throws: The operation's error, or `CancellationError` when the caller was
///   cancelled — also when the operation had already finished, so a cancelled
///   caller never acts on a stale result.
public func withCancellableDetachedWork<T: Sendable>(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) { () throws -> T in
        try Task.checkCancellation()
        return try operation()
    }
    let value = try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
    try Task.checkCancellation()
    return value
}
