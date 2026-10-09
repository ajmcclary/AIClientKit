import XCTest
import AIClientStorage

final class EphemeralSecureKeyValueStoreTests: XCTestCase {
	func testStoreIsProcessLocalAndNotPersistent() {
		XCTAssertFalse(AIEphemeralSecureKeyValueStore().persistsValuesAcrossLaunches)
	}

	func testPlainSaveReadRawReadAndOverwrite() throws {
		let store = AIEphemeralSecureKeyValueStore()

		try store.save("first", for: "key", withIntegrityProtection: false)
		XCTAssertEqual(try store.get(for: "key", verifyIntegrity: false), "first")
		XCTAssertEqual(try store.getRawData(for: "key"), Data("first".utf8))

		try store.save("second", for: "key", withIntegrityProtection: false)
		XCTAssertEqual(try store.get(for: "key", verifyIntegrity: false), "second")
	}

	func testIntegrityProtectedSaveMirrorsClassicFraming() throws {
		let store = AIEphemeralSecureKeyValueStore()
		let value = "protected"

		try store.save(value, for: "key", withIntegrityProtection: true)

		XCTAssertEqual(try store.get(for: "key", verifyIntegrity: true), value)
		XCTAssertEqual(try store.getRawData(for: "key").count, 32 + value.utf8.count)
	}

	func testPlainValueFailsIntegrityVerification() throws {
		let store = AIEphemeralSecureKeyValueStore()
		try store.save("plain", for: "key", withIntegrityProtection: false)

		XCTAssertThrowsError(try store.get(for: "key", verifyIntegrity: true)) { error in
			guard case AIKeychainError.invalidData = error else {
				return XCTFail("Expected invalidData, got \(error)")
			}
		}
	}

	func testMissingReadThrowsItemNotFound() {
		let store = AIEphemeralSecureKeyValueStore()

		XCTAssertThrowsError(try store.get(for: "missing", verifyIntegrity: false)) { error in
			guard case AIKeychainError.itemNotFound = error else {
				return XCTFail("Expected itemNotFound, got \(error)")
			}
		}
	}

	func testExistingAndMissingDeletesAreNoOpsAfterRemoval() throws {
		let store = AIEphemeralSecureKeyValueStore()
		try store.save("value", for: "key", withIntegrityProtection: false)

		XCTAssertNoThrow(try store.delete(for: "key"))
		XCTAssertNoThrow(try store.delete(for: "key"))
		XCTAssertThrowsError(try store.get(for: "key", verifyIntegrity: false))
	}

	func testSeparateInstancesDoNotShareEntries() throws {
		let first = AIEphemeralSecureKeyValueStore()
		let second = AIEphemeralSecureKeyValueStore()
		try first.save("value", for: "key", withIntegrityProtection: true)

		XCTAssertEqual(try first.get(for: "key", verifyIntegrity: true), "value")
		XCTAssertThrowsError(try second.get(for: "key", verifyIntegrity: true))
	}
}
