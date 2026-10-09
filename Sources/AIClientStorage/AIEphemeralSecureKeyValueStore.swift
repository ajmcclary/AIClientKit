import Foundation
import CryptoKit
import Synchronization

public final class AIEphemeralSecureKeyValueStore: AISecureKeyValueBackend, Sendable {

	public let persistsValuesAcrossLaunches = false

	private let entries = Mutex<[String: Data]>([:])
	private let hmacKey = SymmetricKey(size: .bits256)

	public init() {}

	public func save(_ value: String, for key: String, withIntegrityProtection: Bool = true) throws {
		guard let valueData = value.data(using: .utf8) else {
			throw AIKeychainError.invalidData
		}

		let data: Data
		if withIntegrityProtection {
			var protectedData = Data(HMAC<SHA256>.authenticationCode(for: valueData, using: hmacKey))
			protectedData.append(valueData)
			data = protectedData
		} else {
			data = valueData
		}

		entries.withLock { $0[key] = data }
	}

	public func get(for key: String, verifyIntegrity: Bool = true) throws -> String {
		let data = try entries.withLock { state in
			guard let data = state[key] else {
				throw AIKeychainError.itemNotFound
			}
			return data
		}

		if verifyIntegrity {
			return try verifyAndExtract(from: data)
		}
		guard let value = String(data: data, encoding: .utf8) else {
			throw AIKeychainError.invalidData
		}
		return value
	}

	public func getRawData(for key: String) throws -> Data {
		try entries.withLock { state in
			guard let data = state[key] else {
				throw AIKeychainError.itemNotFound
			}
			return data
		}
	}

	public func delete(for key: String) throws {
		_ = entries.withLock { $0.removeValue(forKey: key) }
	}

	private func verifyAndExtract(from data: Data) throws -> String {
		guard data.count > 32 else {
			throw AIKeychainError.invalidData
		}

		let storedHMAC = data.prefix(32)
		let originalData = data.suffix(from: 32)
		let computedHMAC = Data(HMAC<SHA256>.authenticationCode(for: originalData, using: hmacKey))
		guard storedHMAC == computedHMAC else {
			throw AIKeychainError.integrityCheckFailed
		}
		guard let value = String(data: originalData, encoding: .utf8) else {
			throw AIKeychainError.invalidData
		}
		return value
	}

}
