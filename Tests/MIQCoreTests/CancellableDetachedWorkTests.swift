import Foundation
import Testing
@testable import MIQCore

/// `withCancellableDetachedWork` must forward the caller's cancellation into the
/// detached task — the reason it exists, since `Task.detached` alone doesn't.
@Suite struct CancellableDetachedWorkTests {
    @Test func returnsTheOperationsValue() async throws {
        let value = try await withCancellableDetachedWork(priority: .userInitiated) { 6 * 7 }
        #expect(value == 42)
    }

    @Test func rethrowsTheOperationsError() async {
        await #expect(throws: MIQError.self) {
            try await withCancellableDetachedWork { () throws -> Int in throw MIQError.unsupportedFileFormat }
        }
    }

    @Test func cancellingTheCallerCancelsTheDetachedWork() async throws {
        let started = Flag()
        let sawCancellation = Flag()
        let caller = Task {
            try await withCancellableDetachedWork { () throws -> Int in
                started.set()
                // Stands in for a long parse that polls cancellation between chunks.
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if Task.isCancelled { sawCancellation.set(); throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return 1
            }
        }
        while !started.value { try await Task.sleep(nanoseconds: 1_000_000) }
        caller.cancel()
        let result = await caller.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(sawCancellation.value)
    }

    @Test func alreadyCancelledCallerNeverRunsTheOperation() async {
        let ran = Flag()
        let caller = Task {
            // Wait until cancelled before starting the work.
            while !Task.isCancelled { await Task.yield() }
            return try await withCancellableDetachedWork { () throws -> Int in ran.set(); return 1 }
        }
        caller.cancel()
        let result = await caller.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!ran.value)
    }
}

/// A thread-safe one-way flag for the tests above.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
    func set() { lock.lock(); isSet = true; lock.unlock() }
}
