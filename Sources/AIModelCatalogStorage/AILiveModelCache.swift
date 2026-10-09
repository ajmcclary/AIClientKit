import Foundation
import Synchronization
import AIClientKit
import AIClientStorage
import AIModelCatalog

/// One instance owns each host's read/modify/write cache transaction. Notification
/// delivery is injected and runs outside the lock. Unknown provider keys survive.
public final class AILiveModelCache: Sendable {
	private let preferences: any AIDataPreferences
	private let storageKey: String
	private let providerKey: @Sendable (AIProviderType) -> String?
	private let onChange: @Sendable () -> Void
	private let transaction = Mutex(())
	public init(preferences: any AIDataPreferences, storageKey: String, providerKey: @escaping @Sendable (AIProviderType) -> String?, onChange: @escaping @Sendable () -> Void) {
		self.preferences = preferences; self.storageKey = storageKey; self.providerKey = providerKey; self.onChange = onChange
	}
	public static func chatModelFilter(_ ids: [String]) -> [String] {
		let nonChat = ["embed", "whisper", "tts", "dall-e", "dalle", "moderation", "realtime", "transcribe", "speech", "rerank", "image", "video"]
		return ids.filter { id in !nonChat.contains { id.lowercased().contains($0) } }
	}
	private func load() -> [String: [String]] {
		guard let data = preferences.data(forKey: storageKey), let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }; return values
	}
	private func save(_ value: [String: [String]]) { guard let data = try? JSONEncoder().encode(value) else { return }; preferences.set(data, forKey: storageKey) }
	public func models(for provider: AIProviderType) -> [String]? {
		guard let key = providerKey(provider) else { return nil }; return transaction.withLock { _ in load()[key] }
	}
	public func store(_ ids: [String], for provider: AIProviderType) {
		guard let key = providerKey(provider) else { return }
		let filtered = Self.chatModelFilter(ids)
		let changed = transaction.withLock { _ -> Bool in
			var values = load()
			if filtered.isEmpty { guard values.removeValue(forKey: key) != nil else { return false } }
			else { values[key] = filtered }
			save(values); return true
		}
		if changed { onChange() }
	}
	public func clear(_ provider: AIProviderType) {
		guard let key = providerKey(provider) else { return }
		let changed = transaction.withLock { _ -> Bool in var value = load(); guard value.removeValue(forKey: key) != nil else { return false }; save(value); return true }
		if changed { onChange() }
	}
}
