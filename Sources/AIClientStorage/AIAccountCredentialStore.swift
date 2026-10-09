import Foundation
import AIClientKit

public enum AICredentialCacheWritePolicy: Sendable { case afterSuccessfulStorage, legacyBeforeStorage }
/// Each instance owns its cache. Account naming is supplied by the host and endpoint identity is retained.
public actor AIAccountCredentialStore: AICredentialStoring {
	private struct Key: Hashable { let provider: AIProviderType; let endpointID: String? }
	private let access: any AISecureCredentialAccess
	private let account: @Sendable (AIProviderType, String?) -> String
	private let writePolicy: AICredentialCacheWritePolicy
	private var cache: [Key: String] = [:]
	private var pendingReads: [UUID: Key] = [:]
	public init(access: any AISecureCredentialAccess, account: @escaping @Sendable (AIProviderType, String?) -> String, cacheWritePolicy: AICredentialCacheWritePolicy = .afterSuccessfulStorage) {
		self.access = access; self.account = account; self.writePolicy = cacheWritePolicy
	}
	public func credential(for provider: AIProviderType, endpointID: String?) async throws -> String? {
		let key = Key(provider: provider, endpointID: endpointID)
		if let cached = cache[key] { return cached }
		let ticket = UUID(); pendingReads[ticket] = key
		do {
			let result = try await access.getAPIKey(for: account(provider, endpointID))
			// A read may suspend while a save/delete happens. Return its captured
			// value, but never let it replace a cache entry from that later mutation.
			if pendingReads.removeValue(forKey: ticket) != nil, let result { cache[key] = result }
			return result
		} catch { pendingReads[ticket] = nil; throw error }
	}
	public func setCredential(_ value: String?, for provider: AIProviderType, endpointID: String?) async throws {
		let key = Key(provider: provider, endpointID: endpointID)
		pendingReads = pendingReads.filter { $0.value != key }
		if let value {
			if writePolicy == .legacyBeforeStorage { cache[key] = value }
			try access.saveAPIKey(value, for: account(provider, endpointID))
			cache[key] = value
		} else {
			cache[key] = nil; try access.deleteAPIKey(for: account(provider, endpointID))
		}
	}
	public func clearCache() { cache.removeAll(); pendingReads.removeAll() }
}
