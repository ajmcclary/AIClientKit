import Foundation
import Security
import CryptoKit
import Synchronization
import AIClientKit
import AIClientStorage
import XCTest

final class StorageIsolationTests: XCTestCase, @unchecked Sendable {
	private func environment(now: Double = 1000, continuous: Double = 200, uptime: Double = 100, hardware: String? = "fixture-device") -> AIStorageEnvironment {
		.init(randomBytes: { Data(repeating: 0x42, count: $0) }, hardwareIdentifier: { hardware }, wallClock: { Date(timeIntervalSince1970: now) }, continuousSeconds: { continuous }, uptime: { uptime })
	}
	private func store(_ access: MemoryKeychain, namespace: AIStorageNamespace = .application(identifier: "fixture.app"), env: AIStorageEnvironment? = nil, fallback: AIIntegrityFallbackPolicy = .requireInstallSecret) -> AIKeychainStore {
		.init(namespace: namespace, access: access, environment: env ?? environment(), integrityFallback: fallback)
	}
	func testThreeAppNamespacesKeepCredentialsAndIntegritySecretsSeparate() throws {
		let access = MemoryKeychain()
		let stores = ["repoprompt", "codeeditor", "diagram"].map { store(access, namespace: .application(identifier: "fixture."+$0)) }
		for (index, s) in stores.enumerated() { try s.save("secret-\(index)", for: "OpenAIAPI", withIntegrityProtection: false); try s.save("document-\(index)", for: "policy") }
		for (index, s) in stores.enumerated() { XCTAssertEqual(try s.get(for: "OpenAIAPI", verifyIntegrity: false), "secret-\(index)"); XCTAssertEqual(try s.get(for: "policy"), "document-\(index)") }
		XCTAssertEqual(access.records.count, 9)
		try stores[1].delete(for: "OpenAIAPI")
		XCTAssertEqual(try stores[0].get(for: "OpenAIAPI", verifyIntegrity: false), "secret-0")
	}
	func testLegacyHMACDerivationAndFramingAreByteCompatible() throws {
		let access = MemoryKeychain(), namespace = AIStorageNamespace(serviceName: "fixture.legacy.keychain", integrityInstallSecretAccount: "legacy-install", integrityKeyDerivationSalt: "legacy-salt")
		try access.add(service: namespace.serviceName, account: "legacy-install", data: Data(repeating: 0x42, count: 32), accessibility: .afterFirstUnlockDeviceOnly, synchronizable: false)
		let s = store(access, namespace: namespace)
		try s.save("policy", for: "record")
		var material = Data(repeating: 0x42, count: 32); material.append(Data("fixture-devicelegacy-salt".utf8))
		let expected = try AIIntegrityEnvelope.encode("policy", key: SymmetricKey(data: Data(SHA256.hash(data: material))))
		XCTAssertEqual(try s.getRawData(for: "record"), expected)
		XCTAssertEqual(access.records[.init(service: namespace.serviceName, account: "record")]?.accessibility, .afterFirstUnlock)
		XCTAssertEqual(access.records[.init(service: namespace.serviceName, account: "legacy-install")]?.accessibility, .afterFirstUnlockDeviceOnly)
		XCTAssertFalse(access.records.values.contains { $0.synchronizable })
	}
	func testLegacyDeviceAndSaltFallbacksRemainExplicit() throws {
		for hardware: String? in ["fixture-device", nil] {
			let access = MemoryKeychain(); access.rejectInstallSecret = true
			let namespace = AIStorageNamespace(serviceName: "fixture.fallback", integrityInstallSecretAccount: "install", integrityKeyDerivationSalt: "salt")
			let compatible = store(access, namespace: namespace, env: environment(hardware: hardware), fallback: .legacyDeviceOrSalt)
			try compatible.save("value", for: "record")
			let material = Data(((hardware ?? "")+"salt").utf8)
			XCTAssertEqual(try compatible.getRawData(for: "record"), try AIIntegrityEnvelope.encode("value", key: SymmetricKey(data: Data(SHA256.hash(data: material)))))
			XCTAssertThrowsError(try store(access, namespace: namespace).save("new", for: "strict"))
		}
	}
	func testTamperedAndMalformedEnvelopesFailAndMissingDeletesSucceed() throws {
		let access = MemoryKeychain(), namespace = AIStorageNamespace.application(identifier: "fixture.app"), s = store(access)
		try s.save("value", for: "record")
		var data = try s.getRawData(for: "record"); data[data.startIndex] ^= 1
		access.replace(service: namespace.serviceName, account: "record", data: data)
		XCTAssertThrowsError(try s.get(for: "record")) { XCTAssertEqual($0 as? AIKeychainError, .integrityCheckFailed) }
		access.replace(service: namespace.serviceName, account: "record", data: Data(repeating: 0, count: 32))
		XCTAssertThrowsError(try s.get(for: "record")) { XCTAssertEqual($0 as? AIKeychainError, .invalidData) }
		XCTAssertNoThrow(try s.delete(for: "missing"))
	}
	func testDateContinuousRollbackRebootAndLegacyUptimeMigration() throws {
		let access = MemoryKeychain(), s = store(access)
		try s.saveDate(Date(timeIntervalSince1970: 1000), for: "date")
		XCTAssertEqual(try s.get(for: "date"), "1000.0|200.0")
		XCTAssertFalse(try store(access, env: environment(now: 1500, continuous: 700)).getDate(for: "date").clockRollbackDetected)
		XCTAssertTrue(try store(access, env: environment(now: 1000, continuous: 2000, uptime: 2000)).getDate(for: "date").clockRollbackDetected)
		XCTAssertFalse(try store(access, env: environment(now: 1000, continuous: 10)).getDate(for: "date").clockRollbackDetected)
		let migrating = store(access, env: environment(now: 1100, continuous: 2000, uptime: 300))
		XCTAssertFalse(try migrating.getDate(for: "date").clockRollbackDetected)
		XCTAssertEqual(try s.get(for: "date"), "1000.0|2000.0")
	}
	func testConcurrentInstallSecretCreationDoesNotRotateTheWinningSecret() async throws {
		let access = MemoryKeychain(), s = store(access)
		try await withThrowingTaskGroup(of: Void.self) { group in
			for i in 0..<40 { group.addTask { try s.save("value-\(i)", for: "record-\(i)") } }
			try await group.waitForAll()
		}
		for i in 0..<40 { XCTAssertEqual(try s.get(for: "record-\(i)"), "value-\(i)") }
		XCTAssertEqual(access.installSecretAdds, 1)
	}
	func testPersistenceSelectionFailsClosedAndRequiresExplicitSigningIdentity() {
		let good = AIStorageSigningEvidence(teamIdentifier: "A1B2C3D4E5", codeIdentifier: "fixture.app", isAdHocSignature: false, appleTeamSignatureVerified: true)
		XCTAssertEqual(AIStorageRuntimePolicy.backendKind(for: good, policy: .ephemeralOnly), .ephemeral)
		XCTAssertEqual(AIStorageRuntimePolicy.backendKind(for: good, policy: .verifiedAppleTeam), .persistentKeychain)
		XCTAssertEqual(AIStorageRuntimePolicy.backendKind(for: good, policy: .requiredAppleIdentity(teamIdentifier: "A1B2C3D4E5", codeIdentifier: "other.app")), .ephemeral)
		XCTAssertEqual(AIStorageRuntimePolicy.backendKind(for: good, policy: .requiredAppleIdentity(teamIdentifier: "A1B2C3D4E5", codeIdentifier: "fixture.app")), .persistentKeychain)
		for team in [nil, "", "short", "abcdefghij", "A1B2C3D4E-"] {
			XCTAssertEqual(AIStorageRuntimePolicy.backendKind(for: .init(teamIdentifier: team, codeIdentifier: "fixture.app", isAdHocSignature: false, appleTeamSignatureVerified: true), policy: .verifiedAppleTeam), .ephemeral)
		}
		var persistentConstructed = false
		let selected = AIStorageRuntimePolicy.select(for: good, policy: .ephemeralOnly, persistent: { persistentConstructed = true; return AIEphemeralSecureKeyValueStore() }, ephemeral: { AIEphemeralSecureKeyValueStore() })
		XCTAssertFalse(persistentConstructed); XCTAssertEqual(selected.kind, .ephemeral)
	}
	func testPreferenceSuitesAndLegacyProviderPayloadRemainIsolated() throws {
		let names = (0..<3).map { _ in "AIStorageTests."+UUID().uuidString }
		let defaults = names.map { UserDefaults(suiteName: $0)! }
		defer { for (d, name) in zip(defaults, names) { d.removePersistentDomain(forName: name) } }
		let stores = defaults.map { AIProviderConfigurationStore(preferences: AIDefaultsDataPreferences(defaults: $0), storageKey: { "provider_config_\($0)" }) }
		stores[0].save(.init(temperature: 0.3, maxTokens: 42), for: .openAI)
		XCTAssertEqual(stores[0].configuration(for: .openAI), .init(temperature: 0.3, maxTokens: 42))
		XCTAssertEqual(stores[1].configuration(for: .openAI), .init())
		let body = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults[0].data(forKey: "provider_config_openAI"))) as! [String: Any]
		XCTAssertEqual(body["maxTokens"] as? Int, 42); XCTAssertEqual(body["temperature"] as? Double, 0.3)
		defaults[0].set(Data("malformed".utf8), forKey: "provider_config_openAI")
		XCTAssertEqual(stores[0].configuration(for: .openAI), .init())
		XCTAssertEqual(defaults[0].data(forKey: "provider_config_openAI"), Data("malformed".utf8))
	}
}

private final class MemoryKeychain: AIKeychainAccess, Sendable {
	struct Key: Hashable, Sendable { let service: String; let account: String }
	struct Record: Sendable { let data: Data; let accessibility: AIKeychainAccessibility; let synchronizable: Bool }
	private struct State { var records: [Key: Record] = [:]; var rejectInstall = false; var installAdds = 0 }
	private let state = Mutex(State())
	var records: [Key: Record] { state.withLock { $0.records } }
	var installSecretAdds: Int { state.withLock { $0.installAdds } }
	var rejectInstallSecret: Bool { get { state.withLock { $0.rejectInstall } } set { state.withLock { $0.rejectInstall = newValue } } }
	func read(service: String, account: String) throws -> Data? { state.withLock { $0.records[.init(service: service, account: account)]?.data } }
	func add(service: String, account: String, data: Data, accessibility: AIKeychainAccessibility, synchronizable: Bool) throws {
		try state.withLock {
			if accessibility == .afterFirstUnlockDeviceOnly && $0.rejectInstall { throw AIKeychainError.unexpectedStatus(-1) }
			let key = Key(service: service, account: account); guard $0.records[key] == nil else { throw AIKeychainError.duplicateItem }
			$0.records[key] = .init(data: data, accessibility: accessibility, synchronizable: synchronizable)
			if accessibility == .afterFirstUnlockDeviceOnly { $0.installAdds += 1 }
		}
	}
	func remove(service: String, account: String) throws { _ = state.withLock { $0.records.removeValue(forKey: .init(service: service, account: account)) } }
	func replace(service: String, account: String, data: Data) { state.withLock { $0.records[.init(service: service, account: account)] = .init(data: data, accessibility: .afterFirstUnlock, synchronizable: false) } }
}
