import Foundation

public protocol AISecureCredentialAccess: Sendable {
	func saveAPIKey(_ value: String, for identifier: String) throws
	func getAPIKey(for identifier: String) async throws -> String?
	func deleteAPIKey(for identifier: String) throws
}
/// Storage semantics extracted from RepoPrompt, including legacy plain/HMAC recovery.
public final class AISecureStringStore: AISecureCredentialAccess, Sendable {
	private let backend: any AISecureKeyValueBackend
	public init(backend: any AISecureKeyValueBackend) { self.backend = backend }
	public func saveAPIKey(_ value: String, for identifier: String) throws { try backend.save(value, for: identifier, withIntegrityProtection: false) }
	public func getAPIKey(for identifier: String) async throws -> String? {
		do { return try backend.get(for: identifier, verifyIntegrity: false) }
		catch AIKeychainError.itemNotFound { return nil }
		catch { return try? recoverLegacyValue(for: identifier) }
	}
	private func recoverLegacyValue(for identifier: String) throws -> String? {
		let data = try backend.getRawData(for: identifier)
		if let value = String(data: data, encoding: .utf8), !value.isEmpty {
			try? backend.save(value, for: identifier, withIntegrityProtection: false); return value
		}
		if data.count > 32, let value = String(data: data.suffix(from: 32), encoding: .utf8), !value.isEmpty {
			try? backend.save(value, for: identifier, withIntegrityProtection: false); return value
		}
		return nil
	}
	public func deleteAPIKey(for identifier: String) throws { try? backend.delete(for: identifier) }
	public func savePlainValue(_ value: String, for key: String) throws { try backend.save(value, for: key, withIntegrityProtection: false) }
	public func getPlainValue(for key: String) throws -> String? {
		do { return try backend.get(for: key, verifyIntegrity: false) } catch AIKeychainError.itemNotFound { return nil }
	}
	public func deletePlainValue(for key: String) throws { try backend.delete(for: key) }
	public func saveIntegrityProtectedValue(_ value: String, for key: String) throws { try backend.save(value, for: key, withIntegrityProtection: true) }
	public func getIntegrityProtectedValue(for key: String) throws -> String? {
		do { return try backend.get(for: key, verifyIntegrity: true) } catch AIKeychainError.itemNotFound { return nil }
	}
	public func deleteIntegrityProtectedValue(for key: String) throws { try backend.delete(for: key) }
}
