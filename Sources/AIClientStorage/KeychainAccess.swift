import Foundation
import Security
import IOKit

public enum AIKeychainAccessibility: Sendable { case afterFirstUnlock, afterFirstUnlockDeviceOnly }
public protocol AIKeychainAccess: Sendable {
	func read(service: String, account: String) throws -> Data?
	func add(service: String, account: String, data: Data, accessibility: AIKeychainAccessibility, synchronizable: Bool) throws
	/// Replaces an existing item's data in place, atomically: on failure the previous
	/// data must still be stored. Throws `AIKeychainError.itemNotFound` when there is no
	/// such item. There is deliberately no default: `read`/`add`/`remove` cannot replace
	/// an item without a window in which it is deleted, which loses the secret when the
	/// re-add fails. `accessibility` is for implementations that must re-create the item.
	func update(service: String, account: String, data: Data, accessibility: AIKeychainAccessibility) throws
	func remove(service: String, account: String) throws
}
public final class AISystemKeychainAccess: AIKeychainAccess, Sendable {
	public init() {}
	private func query(_ service: String, _ account: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
	}
	public func read(service: String, account: String) throws -> Data? {
		var query = query(service, account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?; let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw AIKeychainError.unexpectedStatus(status) }
		guard let data = result as? Data else { throw AIKeychainError.invalidData }; return data
	}
	public func add(service: String, account: String, data: Data, accessibility: AIKeychainAccessibility, synchronizable: Bool) throws {
		var query = query(service, account); query[kSecValueData as String] = data
		query[kSecAttrAccessible as String] = accessibility == .afterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		query[kSecAttrSynchronizable as String] = synchronizable
		let status = SecItemAdd(query as CFDictionary, nil)
		if status == errSecDuplicateItem { throw AIKeychainError.duplicateItem }
		guard status == errSecSuccess else { throw AIKeychainError.unexpectedStatus(status) }
	}
	public func update(service: String, account: String, data: Data, accessibility: AIKeychainAccessibility) throws {
		let attributes: [String: Any] = [kSecValueData as String: data]
		let status = SecItemUpdate(query(service, account) as CFDictionary, attributes as CFDictionary)
		if status == errSecItemNotFound { throw AIKeychainError.itemNotFound }
		guard status == errSecSuccess else { throw AIKeychainError.unexpectedStatus(status) }
	}
	public func remove(service: String, account: String) throws {
		let status = SecItemDelete(query(service, account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw AIKeychainError.unexpectedStatus(status) }
	}
}
public enum AISystemStorageInputs {
	public static func randomBytes(count: Int) throws -> Data {
		guard count > 0 else { throw AIKeychainError.invalidData }
		var data = Data(count: count)
		let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
		guard status == errSecSuccess else { throw AIKeychainError.unexpectedStatus(status) }; return data
	}
	public static func hardwareIdentifier() -> String? {
		let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
		defer { IOObjectRelease(expert) }; guard expert != 0 else { return nil }
		return IORegistryEntryCreateCFProperty(expert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
	}
}
