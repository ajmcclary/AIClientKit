import Synchronization
import XCTest
import AIClientStorage

final class SecureKeysServiceBackendTests: XCTestCase {
	func testAPIKeySaveAndGetUsePlainStorage() async throws {
		let backend = RecordingSecureStorageBackend()
		let service = AISecureStringStore(backend: backend)

		try service.saveAPIKey("secret", for: "api")
		let retrieved = try await service.getAPIKey(for: "api")
		XCTAssertEqual(retrieved, "secret")
		XCTAssertEqual(backend.operations, [
			.save("secret", "api", false),
			.get("api", false)
		])
	}

	func testPlainAndIntegrityMethodsUseRequestedModes() throws {
		let backend = RecordingSecureStorageBackend()
		let service = AISecureStringStore(backend: backend)

		try service.savePlainValue("plain", for: "plain-key")
		XCTAssertEqual(try service.getPlainValue(for: "plain-key"), "plain")
		try service.deletePlainValue(for: "plain-key")
		try service.saveIntegrityProtectedValue("protected", for: "protected-key")
		XCTAssertEqual(try service.getIntegrityProtectedValue(for: "protected-key"), "protected")
		try service.deleteIntegrityProtectedValue(for: "protected-key")

		XCTAssertEqual(backend.operations, [
			.save("plain", "plain-key", false),
			.get("plain-key", false),
			.delete("plain-key"),
			.save("protected", "protected-key", true),
			.get("protected-key", true),
			.delete("protected-key")
		])
	}

	func testLegacyAPIKeyRecoveryStripsHMACPrefixAndRewritesPlainValue() async throws {
		let backend = RecordingSecureStorageBackend()
		backend.getOverride = { _, _ in throw AIKeychainError.invalidData }
		var legacyBytes = Data(repeating: 0xFF, count: 32)
		legacyBytes.append(Data("legacy-secret".utf8))
		let legacyData = legacyBytes
		backend.rawDataOverride = { _ in legacyData }
		let service = AISecureStringStore(backend: backend)

		let retrieved = try await service.getAPIKey(for: "api")
		XCTAssertEqual(retrieved, "legacy-secret")
		XCTAssertEqual(backend.operations, [
			.get("api", false),
			.getRawData("api"),
			.save("legacy-secret", "api", false)
		])
	}

	func testMissingAPIKeyReturnsNil() async throws {
		let backend = RecordingSecureStorageBackend()
		let service = AISecureStringStore(backend: backend)

		let retrieved = try await service.getAPIKey(for: "missing")
		XCTAssertNil(retrieved)
		XCTAssertEqual(backend.operations, [.get("missing", false)])
	}

	func testAPIKeyDeleteRemainsBestEffort() throws {
		let backend = RecordingSecureStorageBackend()
		backend.deleteError = AIKeychainError.unexpectedStatus(OSStatus(-1))
		let service = AISecureStringStore(backend: backend)

		XCTAssertNoThrow(try service.deleteAPIKey(for: "api"))
		XCTAssertEqual(backend.operations, [.delete("api")])
	}
}

/// `AISecureKeyValueBackend` requires `Sendable`, and this double really is
/// reached from more than one isolation domain: `SecureKeysService.getAPIKey` is
/// `async`, so a recorded call can land on a different executor than the one that
/// installed the override or later reads `operations`. The conformance is
/// therefore made *true* rather than asserted: every mutable field lives inside
/// the single `Mutex` below, which is the class's only stored property, so there
/// is no unsynchronized state left to share.
///
/// The lock is deliberately never held across a call-out — `getOverride` /
/// `rawDataOverride` are read out under the lock and invoked after it is
/// released — because `Mutex` is not recursive and a closure that re-entered the
/// backend would otherwise deadlock. Recording order is unchanged: the operation
/// is appended inside the same critical section that reads the override, exactly
/// where the previous code appended it.
private final class RecordingSecureStorageBackend: AISecureKeyValueBackend {
	enum Operation: Equatable {
		case save(String, String, Bool)
		case get(String, Bool)
		case getRawData(String)
		case delete(String)
	}

	private struct State {
		var operations: [Operation] = []
		var getOverride: (@Sendable (String, Bool) throws -> String)?
		var rawDataOverride: (@Sendable (String) throws -> Data)?
		var deleteError: (any Error & Sendable)?
		var entries: [String: Data] = [:]
	}

	private let state = Mutex(State())

	let persistsValuesAcrossLaunches = false

	var operations: [Operation] {
		state.withLock { $0.operations }
	}

	var getOverride: (@Sendable (String, Bool) throws -> String)? {
		get { state.withLock { $0.getOverride } }
		set { state.withLock { $0.getOverride = newValue } }
	}

	var rawDataOverride: (@Sendable (String) throws -> Data)? {
		get { state.withLock { $0.rawDataOverride } }
		set { state.withLock { $0.rawDataOverride = newValue } }
	}

	var deleteError: (any Error & Sendable)? {
		get { state.withLock { $0.deleteError } }
		set { state.withLock { $0.deleteError = newValue } }
	}

	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws {
		state.withLock {
			$0.operations.append(.save(value, key, withIntegrityProtection))
			$0.entries[key] = Data(value.utf8)
		}
	}

	func get(for key: String, verifyIntegrity: Bool) throws -> String {
		let (override, data) = state.withLock {
			$0.operations.append(.get(key, verifyIntegrity))
			return ($0.getOverride, $0.entries[key])
		}
		if let override {
			return try override(key, verifyIntegrity)
		}
		guard let data else {
			throw AIKeychainError.itemNotFound
		}
		guard let value = String(data: data, encoding: .utf8) else {
			throw AIKeychainError.invalidData
		}
		return value
	}

	func getRawData(for key: String) throws -> Data {
		let (override, data) = state.withLock {
			$0.operations.append(.getRawData(key))
			return ($0.rawDataOverride, $0.entries[key])
		}
		if let override {
			return try override(key)
		}
		guard let data else {
			throw AIKeychainError.itemNotFound
		}
		return data
	}

	func delete(for key: String) throws {
		let deleteError = state.withLock { state -> (any Error & Sendable)? in
			state.operations.append(.delete(key))
			if let deleteError = state.deleteError {
				return deleteError
			}
			state.entries.removeValue(forKey: key)
			return nil
		}
		if let deleteError {
			throw deleteError
		}
	}
}
