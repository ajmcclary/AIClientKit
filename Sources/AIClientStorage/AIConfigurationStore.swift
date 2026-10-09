import Foundation
import Synchronization
import AIClientKit

public protocol AIDataPreferences: Sendable {
	func data(forKey key: String) -> Data?
	func set(_ data: Data, forKey key: String)
	func remove(forKey key: String)
}
/// Hosts choose a suite or pass their existing defaults object. No global defaults lookup occurs here.
/// Foundation does not declare UserDefaults Sendable. This adapter holds only an
/// immutable reference and lock, serializes every access, and returns Data values;
/// it never exposes the reference or mutable Foundation containers to consumers.
public final class AIDefaultsDataPreferences: AIDataPreferences, @unchecked Sendable {
	private let defaults: UserDefaults
	private let lock = NSLock()
	public init(defaults: UserDefaults) { self.defaults = defaults }
	public func data(forKey key: String) -> Data? { withLock { defaults.data(forKey: key) } }
	public func set(_ data: Data, forKey key: String) { withLock { defaults.set(data, forKey: key) } }
	public func remove(forKey key: String) { withLock { defaults.removeObject(forKey: key) } }
	private func withLock<Value>(_ body: () -> Value) -> Value { lock.lock(); defer { lock.unlock() }; return body() }
}
public final class AIJSONConfigurationStore: Sendable {
	private let preferences: any AIDataPreferences
	public init(preferences: any AIDataPreferences) { self.preferences = preferences }
	public func load<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value? {
		guard let data = preferences.data(forKey: key) else { return nil }; return try JSONDecoder().decode(type, from: data)
	}
	public func save<Value: Encodable>(_ value: Value, forKey key: String) throws { preferences.set(try JSONEncoder().encode(value), forKey: key) }
	public func remove(forKey key: String) { preferences.remove(forKey: key) }
}
public struct AIProviderConfiguration: Codable, Equatable, Sendable {
	public var temperature: Double?
	public var maxTokens: Int?
	public init(temperature: Double? = nil, maxTokens: Int? = nil) { self.temperature = temperature; self.maxTokens = maxTokens }
}
public final class AIProviderConfigurationStore: Sendable {
	private let json: AIJSONConfigurationStore
	private let storageKey: @Sendable (AIProviderType) -> String
	public init(preferences: any AIDataPreferences, storageKey: @escaping @Sendable (AIProviderType) -> String) { json = .init(preferences: preferences); self.storageKey = storageKey }
	public func configuration(for provider: AIProviderType) -> AIProviderConfiguration { (try? json.load(AIProviderConfiguration.self, forKey: storageKey(provider))) ?? .init() }
	public func save(_ value: AIProviderConfiguration, for provider: AIProviderType) { try? json.save(value, forKey: storageKey(provider)) }
}
