import Foundation
import Synchronization

public struct AIModelOverrideSnapshot: Codable, Equatable, Sendable {
	public var diff: [String: Bool]
	public var stream: [String: Bool]
	public var temperature: [String: Double]
	public var responses: [String: Bool]
	public init(diff: [String: Bool] = [:], stream: [String: Bool] = [:], temperature: [String: Double] = [:], responses: [String: Bool] = [:]) {
		self.diff = diff; self.stream = stream; self.temperature = temperature; self.responses = responses
	}
}
/// Copies snapshots out before calling the host. The revision lets a host reject
/// reordered persistence callbacks without holding a lock across a main-actor hop.
public final class AIModelOverrideStore: Sendable {
	private struct State { var snapshot: AIModelOverrideSnapshot; var revision: UInt64 = 0 }
	private let state: Mutex<State>
	private let persist: @Sendable (AIModelOverrideSnapshot, UInt64) -> Void
	public init(initial: AIModelOverrideSnapshot, persist: @escaping @Sendable (AIModelOverrideSnapshot, UInt64) -> Void) { state = Mutex(State(snapshot: initial)); self.persist = persist }
	public var snapshot: AIModelOverrideSnapshot { state.withLock { $0.snapshot } }
	public func update(_ body: (inout AIModelOverrideSnapshot) -> Void) {
		let (snapshot, revision) = state.withLock { value -> (AIModelOverrideSnapshot, UInt64) in body(&value.snapshot); value.revision += 1; return (value.snapshot, value.revision) }
		persist(snapshot, revision)
	}
	public func streamOverride(for id: String) -> Bool? { state.withLock { $0.snapshot.stream[id] } }
	public func temperatureOverride(for id: String) -> Double? { state.withLock { $0.snapshot.temperature[id] } }
	public func responsesOverride(for id: String) -> Bool? { state.withLock { $0.snapshot.responses[id] } }
}
