import Foundation
import Synchronization
import AIClientKit
import AIClientStorage
import XCTest

final class CredentialAndConfigurationTests: XCTestCase, @unchecked Sendable {
	func testCachesAreAppAndEndpointScopedAndMissingValuesAreNotMemoized() async throws {
		let access = CredentialAccess()
		let first = AIAccountCredentialStore(access: access, account: { provider, endpoint in "app1.\(provider).\(endpoint ?? "default")" })
		let second = AIAccountCredentialStore(access: access, account: { provider, endpoint in "app2.\(provider).\(endpoint ?? "default")" })
		try await first.setCredential("one", for: .openAI, endpointID: "endpoint1")
		try await first.setCredential("two", for: .openAI, endpointID: "endpoint2")
		let one = try await first.credential(for: .openAI, endpointID: "endpoint1"), two = try await first.credential(for: .openAI, endpointID: "endpoint2")
		XCTAssertEqual(one, "one"); XCTAssertEqual(two, "two")
		let missing = try await second.credential(for: .openAI, endpointID: "endpoint1"); XCTAssertNil(missing)
		try access.saveAPIKey("later", for: "app2.openAI.endpoint1")
		let loaded = try await second.credential(for: .openAI, endpointID: "endpoint1"); XCTAssertEqual(loaded, "later")
		try await first.setCredential(nil, for: .openAI, endpointID: "endpoint1")
		let deleted = try await first.credential(for: .openAI, endpointID: "endpoint1"); XCTAssertNil(deleted)
	}
	func testSafeCachePolicyDoesNotAdoptFailedWritesButLegacyPolicyIsPreserved() async throws {
		let access = CredentialAccess(); access.rejectWrites = true
		let safe = AIAccountCredentialStore(access: access, account: { _, _ in "key" })
		let legacy = AIAccountCredentialStore(access: access, account: { _, _ in "key" }, cacheWritePolicy: .legacyBeforeStorage)
		do { try await safe.setCredential("safe", for: .openAI, endpointID: nil); XCTFail("Expected failure") } catch AIKeychainError.unexpectedStatus {}
		do { try await legacy.setCredential("legacy", for: .openAI, endpointID: nil); XCTFail("Expected failure") } catch AIKeychainError.unexpectedStatus {}
		let safeValue = try await safe.credential(for: .openAI, endpointID: nil), legacyValue = try await legacy.credential(for: .openAI, endpointID: nil)
		XCTAssertNil(safeValue); XCTAssertEqual(legacyValue, "legacy")
	}
	func testInjectedGenericConfigurationStoreSupportsUnknownFieldsAndRemoval() throws {
		let name = "AIConfigTests."+UUID().uuidString, defaults = UserDefaults(suiteName: name)!
		defer { defaults.removePersistentDomain(forName: name) }
		let json = AIJSONConfigurationStore(preferences: AIDefaultsDataPreferences(defaults: defaults))
		defaults.set(Data("{\"maxTokens\":42,\"future\":true}".utf8), forKey: "config")
		XCTAssertEqual(try json.load(AIProviderConfiguration.self, forKey: "config"), .init(maxTokens: 42))
		try json.save(AIProviderConfiguration(temperature: 0.7), forKey: "config")
		let value = try json.load(AIProviderConfiguration.self, forKey: "config"); XCTAssertEqual(value?.temperature, 0.7)
		json.remove(forKey: "config"); XCTAssertNil(try json.load(AIProviderConfiguration.self, forKey: "config"))
	}
	func testParallelIndependentPreferenceWritesRemainReadable() async throws {
		let name = "AIConfigConcurrency."+UUID().uuidString, defaults = UserDefaults(suiteName: name)!
		defer { defaults.removePersistentDomain(forName: name) }
		let json = AIJSONConfigurationStore(preferences: AIDefaultsDataPreferences(defaults: defaults))
		try await withThrowingTaskGroup(of: Void.self) { group in
			for i in 0..<30 { group.addTask { try json.save(AIProviderConfiguration(maxTokens: i), forKey: "config-\(i)") } }
			try await group.waitForAll()
		}
		for i in 0..<30 { XCTAssertEqual(try json.load(AIProviderConfiguration.self, forKey: "config-\(i)")?.maxTokens, i) }
	}
	func testSuspendedReadCannotOverwriteNewlySavedCredentialCache() async throws {
		let access = SuspendedCredentialAccess()
		let store = AIAccountCredentialStore(access: access, account: { _, _ in "key" })
		let read = Task { try await store.credential(for: .openAI, endpointID: nil) }
		let deadline = ContinuousClock.now.advanced(by: .seconds(3))
		while !access.readStarted && ContinuousClock.now < deadline { await Task.yield() }
		XCTAssertTrue(access.readStarted)
		try await store.setCredential("new", for: .openAI, endpointID: nil)
		access.releaseRead(); let old = try await read.value; XCTAssertEqual(old, "old")
		let cached = try await store.credential(for: .openAI, endpointID: nil); XCTAssertEqual(cached, "new")
	}
}

private final class SuspendedCredentialAccess: AISecureCredentialAccess, Sendable {
	private struct State { var value = "old"; var pending: CheckedContinuation<Void, Never>? }
	private let state = Mutex(State())
	var readStarted: Bool { state.withLock { $0.pending != nil } }
	func releaseRead() { let pending = state.withLock { let p = $0.pending; $0.pending = nil; return p }; pending?.resume() }
	func saveAPIKey(_ value: String, for identifier: String) throws { state.withLock { $0.value = value } }
	func deleteAPIKey(for identifier: String) throws { state.withLock { $0.value = "" } }
	func getAPIKey(for identifier: String) async throws -> String? {
		let captured = state.withLock { $0.value }
		await withCheckedContinuation { continuation in state.withLock { $0.pending = continuation } }
		return captured
	}
}
private final class CredentialAccess: AISecureCredentialAccess, Sendable {
	private struct State { var values: [String: String] = [:]; var rejectWrites = false }
	private let state = Mutex(State())
	var rejectWrites: Bool { get { state.withLock { $0.rejectWrites } } set { state.withLock { $0.rejectWrites = newValue } } }
	func saveAPIKey(_ value: String, for identifier: String) throws { try state.withLock { if $0.rejectWrites { throw AIKeychainError.unexpectedStatus(-1) }; $0.values[identifier] = value } }
	func getAPIKey(for identifier: String) async throws -> String? { state.withLock { $0.values[identifier] } }
	func deleteAPIKey(for identifier: String) throws { state.withLock { $0.values[identifier] = nil } }
}
