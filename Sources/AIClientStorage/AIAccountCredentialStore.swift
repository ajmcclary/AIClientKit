import Foundation
import Synchronization
import AIClientKit

public enum AICredentialCacheWritePolicy: Sendable { case afterSuccessfulStorage, legacyBeforeStorage }

/// Process-wide write revision per resolved account. Every store bumps an account's
/// revision around each save/delete, and a cache entry is only served while the
/// revision it was cached at is still current, so a write through any store instance
/// invalidates every other instance's entry. Accounts are compared by their resolved
/// name only: two backends that share a name merely cost each other a cache miss.
private final class AICredentialWriteRevisions: Sendable {
	static let shared = AICredentialWriteRevisions()
	private let revisions = Mutex<[String: UInt64]>([:])
	func current(_ account: String) -> UInt64 { revisions.withLock { $0[account] ?? 0 } }
	func bump(_ account: String) -> UInt64 {
		revisions.withLock { state in let next = (state[account] ?? 0) &+ 1; state[account] = next; return next }
	}
	/// Ends a write that began with `bump` returning `started`. Returns the new revision
	/// when no other bump (another write, here or in another store) happened in between,
	/// so the written value is known to be the latest; nil when it may have lost a race.
	func finishWrite(_ account: String, startedAt started: UInt64) -> UInt64? {
		revisions.withLock { state in
			let current = state[account] ?? 0, next = current &+ 1; state[account] = next
			return current == started ? next : nil
		}
	}
}

/// Each instance owns its cache, but a write through any instance in the process
/// invalidates the matching entry in every other instance. Account naming is supplied
/// by the host and endpoint identity is retained.
public actor AIAccountCredentialStore: AICredentialStoring {
	private struct Key: Hashable { let provider: AIProviderType; let endpointID: String? }
	private struct Entry { let value: String; let account: String; let revision: UInt64 }
	private let access: any AISecureCredentialAccess
	private let account: @Sendable (AIProviderType, String?) -> String
	private let writePolicy: AICredentialCacheWritePolicy
	private let revisions = AICredentialWriteRevisions.shared
	private var cache: [Key: Entry] = [:]
	private var pendingReads: [UUID: Key] = [:]
	public init(access: any AISecureCredentialAccess, account: @escaping @Sendable (AIProviderType, String?) -> String, cacheWritePolicy: AICredentialCacheWritePolicy = .afterSuccessfulStorage) {
		self.access = access; self.account = account; self.writePolicy = cacheWritePolicy
	}
	public func credential(for provider: AIProviderType, endpointID: String?) async throws -> String? {
		let key = Key(provider: provider, endpointID: endpointID), name = account(provider, endpointID)
		if let cached = cache[key], cached.account == name, cached.revision == revisions.current(name) { return cached.value }
		cache[key] = nil
		let ticket = UUID(); pendingReads[ticket] = key
		let revision = revisions.current(name)
		do {
			let result = try await access.getAPIKey(for: name)
			// A read may suspend while a save/delete happens, here or through another
			// store. Return its captured value, but never cache it over that mutation.
			if pendingReads.removeValue(forKey: ticket) != nil, revisions.current(name) == revision, let result {
				cache[key] = Entry(value: result, account: name, revision: revision)
			}
			return result
		} catch { pendingReads[ticket] = nil; throw error }
	}
	public func setCredential(_ value: String?, for provider: AIProviderType, endpointID: String?) async throws {
		let key = Key(provider: provider, endpointID: endpointID), name = account(provider, endpointID)
		pendingReads = pendingReads.filter { $0.value != key }
		// Bump before the write so reads already in flight elsewhere are not cached,
		// and after it so reads that started during the write are not cached either.
		// The written value is cached only if no other write overlapped this one.
		let started = revisions.bump(name)
		if let value {
			if writePolicy == .legacyBeforeStorage { cache[key] = Entry(value: value, account: name, revision: started) }
			do { try access.saveAPIKey(value, for: name) } catch {
				// The legacy policy keeps serving the attempted value from this instance.
				let finished = revisions.finishWrite(name, startedAt: started)
				if writePolicy == .legacyBeforeStorage, let finished { cache[key] = Entry(value: value, account: name, revision: finished) }
				else { cache[key] = nil }
				throw error
			}
			if let finished = revisions.finishWrite(name, startedAt: started) { cache[key] = Entry(value: value, account: name, revision: finished) }
			else { cache[key] = nil }
		} else {
			cache[key] = nil
			defer { _ = revisions.finishWrite(name, startedAt: started) }
			try access.deleteAPIKey(for: name)
		}
	}
	public func clearCache() { cache.removeAll(); pendingReads.removeAll() }
}
