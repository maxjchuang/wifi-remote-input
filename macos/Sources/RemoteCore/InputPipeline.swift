// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct InputEvent: Equatable {
    public let type: String
    public let value: String
    public init(_ type: String, _ value: String) { self.type = type; self.value = value }
}

/// One acknowledged request at a time. No retries, including after uncertain delivery.
@MainActor public final class InputPipeline {
    private var events: [InputEvent] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let interval: UInt64
    private let exchange: (InputEvent) async throws -> String
    private let result: (InputEvent) -> Void
    private let failure: (String) -> Void
    public init(interval: UInt64 = 40_000_000, exchange: @escaping (InputEvent) async throws -> String, result: @escaping (InputEvent) -> Void, failure: @escaping (String) -> Void) {
        self.interval = interval; self.exchange = exchange; self.result = result; self.failure = failure
    }
    public var isIdle: Bool { worker == nil }
    public var hasPending: Bool { !events.isEmpty }
    @discardableResult public func enqueue(_ event: InputEvent) -> Bool {
        guard !event.value.isEmpty, event.value.utf16.count <= (event.type == "editor.edit" ? 16384 : 4096),
              events.count < 256, events.reduce(0, { $0 + $1.value.utf16.count }) + event.value.utf16.count <= 32768 else { return false }
        if event.type == "text.commit", let last = events.last, last.type == event.type, (last.value + event.value).utf16.count <= 4096 {
            events[events.count - 1] = InputEvent(event.type, last.value + event.value)
        } else { events.append(event) }
        if worker == nil {
            let id = generation
            worker = Task { [weak self] in await self?.drain(id) }
        }
        return true
    }
    public func discardPending() { events.removeAll() }
    public func reset() { generation = UUID(); events.removeAll(); worker?.cancel(); worker = nil }
    private func drain(_ id: UUID) async {
        defer { if id == generation { worker = nil } }
        while id == generation && !events.isEmpty {
            do {
                // Coalesce typing bursts and remain below the server's 40 requests/sec limit.
                try await Task.sleep(nanoseconds: interval)
                guard id == generation, !events.isEmpty else { return }
                let event = events.removeFirst()
                let status = try await exchange(event)
                guard id == generation else { return }
                if status == "discarded" { continue }
                guard status == "ok" else { events.removeAll(); failure(status); return }
                result(event)
            } catch {
                guard id == generation else { return }
                events.removeAll(); failure("delivery_unknown"); return
            }
        }
    }
}
