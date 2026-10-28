import Foundation
import Synchronization

/// Fan-out of values to any number of `AsyncStream` subscribers; new subscribers get the latest value first.
final class Broadcast<Value: Sendable>: Sendable {
    private let state = Mutex<(latest: Value?, continuations: [UUID: AsyncStream<Value>.Continuation])>(
        (nil, [:])
    )

    init(_ initial: Value? = nil) {
        state.withLock { $0.latest = initial }
    }

    func send(_ value: Value) {
        let continuations = state.withLock { s in
            s.latest = value
            return Array(s.continuations.values)
        }
        for c in continuations { c.yield(value) }
    }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        let latest = state.withLock { s in
            s.continuations[id] = continuation
            return s.latest
        }
        if let latest { continuation.yield(latest) }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    var latest: Value? { state.withLock { $0.latest } }
}
