import AIClientKit
import AIClientStorage
import AIModelCatalog
import AIModelCatalogStorage
import Foundation
import Synchronization
import XCTest

final class ModelCatalogTests: XCTestCase, @unchecked Sendable {
	func testCuratedMetadataMatchesAllPreExtractionRows() throws {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "CuratedAPIBaseline", withExtension: "json"))
		let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
		XCTAssertEqual(values.count, 47); XCTAssertEqual(AICuratedModelCatalog.records.count, 47)
		for (expected, record) in zip(values, AICuratedModelCatalog.records) {
			XCTAssertEqual(record.id, expected["id"] as? String)
			XCTAssertEqual(record.modelName, expected["modelName"] as? String)
			XCTAssertEqual(record.displayName, expected["displayName"] as? String)
			XCTAssertEqual(String(describing: record.provider), expected["provider"] as? String)
			XCTAssertEqual(record.defaultReasoningEffort ?? "", expected["defaultReasoningEffort"] as? String)
		}
		XCTAssertEqual(Set(AICuratedModelCatalog.records.map(\.id)).count, 47)
	}
	func testDescriptorsKeepIdentitySeparateFromCapabilitiesAndDefaults() throws {
		let pro = try XCTUnwrap(AICuratedModelCatalog.record(id: "gpt-5.5-pro", provider: .openAI))
		XCTAssertFalse(pro.descriptor.capabilities.contains(.streaming)); XCTAssertTrue(pro.descriptor.capabilities.contains(.backgroundResponses))
		XCTAssertEqual(pro.defaultReasoningEffort, "high")
		XCTAssertEqual(AICuratedModelCatalog.record(id: "gemini-2.5-pro", provider: .gemini)?.defaultTemperature, 0.7)
		XCTAssertEqual(AICuratedModelCatalog.record(id: "deepseek-reasoner", provider: .deepseek)?.defaultTemperature, 0.6)
		XCTAssertNil(AICuratedModelCatalog.record(id: "gpt-5.5-pro", provider: .gemini))
	}
	func testProviderScopedReconciliationPreservesOrderAliasesAndUnknownIDs() {
		let values = AICuratedModelCatalog.reconcile(["deepseek-chat", "unknown/model", "deepseek-v4-flash", "unknown/model"], provider: .deepseek)
		XCTAssertEqual(values.map(\.id), ["deepseek-v4-flash", "unknown/model"])
		XCTAssertEqual(values.first?.displayName, "DeepSeek V4 Flash")
		XCTAssertEqual(values.last?.displayName, "unknown/model")
		XCTAssertEqual(AICuratedModelCatalog.reconcile(["gpt-5.5"], provider: .gemini).first?.provider, .gemini)
	}
	func testAvailabilityUsesInjectedDateAndPinnedAnthropicFallbacks() {
		let record = AIModelCatalogRecord(id: "future", provider: .openAI, modelName: "future", displayName: "Future", availableFrom: Date(timeIntervalSince1970: 100))
		XCTAssertFalse(record.isAvailable(at: Date(timeIntervalSince1970: 99))); XCTAssertTrue(record.isAvailable(at: Date(timeIntervalSince1970: 100)))
		let fallback = AICuratedModelCatalog.fallback(provider: .anthropic, at: Date(timeIntervalSince1970: 0)).map(\.id)
		for id in ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"] { XCTAssertTrue(fallback.contains(id)) }
	}
	func testIdentityHexAndStringOrderingRetainLegacyBehavior() {
		for value in ["", "endpoint__name:/", "🧭 hé\u{0}"] { XCTAssertEqual(AIHexIdentityCoding.decode(AIHexIdentityCoding.encode(value)), value) }
		XCTAssertNil(AIHexIdentityCoding.decode("f")); XCTAssertNil(AIHexIdentityCoding.decode("zz")); XCTAssertNil(AIHexIdentityCoding.decode("ff"))
		XCTAssertTrue(AIModelStringOrdering.precedes("A", "a"))
		XCTAssertTrue(AIModelStringOrdering.precedes("model 1", "model-1"))
	}
	func testModelListCapKeepsRequiredIDsAtThresholdAndRejectsBlankIDs() {
		XCTAssertEqual(AIModelListCap.enabledModels(fetched: [" a ", "a", ""], threshold: 1, required: [" pinned "]), ["a", "pinned"])
		XCTAssertEqual(AIModelListCap.enabledModels(fetched: ["a", "b"], threshold: 1, required: ["pinned"]), ["pinned"])
	}
	func testConcurrentOverrideUpdatesCopySnapshotsBeforeCalloutsAndAdvanceRevision() async throws {
		let records = Mutex<[(AIModelOverrideSnapshot, UInt64)]>([])
		let store = AIModelOverrideStore(initial: .init(), persist: { snapshot, revision in records.withLock { $0.append((snapshot, revision)) } })
		await withTaskGroup(of: Void.self) { group in
			for i in 0..<40 { group.addTask { store.update { $0.stream["model-\(i)"] = true } } }
			await group.waitForAll()
		}
		XCTAssertEqual(store.snapshot.stream.count, 40)
		XCTAssertEqual(Set(records.withLock { $0.map { $0.1 } }).count, 40)
		let final = records.withLock { $0.max { $0.1 < $1.1 } }; XCTAssertEqual(final?.0, store.snapshot)
	}
	func testLiveCacheRetainsLegacyJSONKeysUnknownProvidersAndNotifications() throws {
		let name = "ModelCacheTests."+UUID().uuidString, defaults = UserDefaults(suiteName: name)!
		defer { defaults.removePersistentDomain(forName: name) }
		defaults.set(try JSONEncoder().encode(["future-provider": ["future"]]), forKey: "LiveProviderModels")
		let changes = Mutex(0)
		let cache = AILiveModelCache(preferences: AIDefaultsDataPreferences(defaults: defaults), storageKey: "LiveProviderModels", providerKey: { $0 == .openAI ? "openai" : nil }, onChange: { changes.withLock { $0 += 1 } })
		cache.store(["gpt-5.2", "text-embedding-3", "gpt-4o-audio-preview"], for: .openAI)
		XCTAssertEqual(cache.models(for: .openAI), ["gpt-5.2", "gpt-4o-audio-preview"])
		let data = try XCTUnwrap(defaults.data(forKey: "LiveProviderModels")); let map = try JSONDecoder().decode([String: [String]].self, from: data)
		XCTAssertEqual(map["future-provider"], ["future"])
		cache.store(["ignored"], for: .codex); XCTAssertEqual(changes.withLock { $0 }, 1)
		cache.store(["only-image"], for: .openAI); XCTAssertNil(cache.models(for: .openAI)); XCTAssertEqual(changes.withLock { $0 }, 2)
		cache.clear(.openAI); XCTAssertEqual(changes.withLock { $0 }, 2)
	}
	func testConcurrentProviderCacheWritesDoNotLoseOtherProviderLists() async throws {
		let name = "ModelCacheConcurrency."+UUID().uuidString, defaults = UserDefaults(suiteName: name)!
		defer { defaults.removePersistentDomain(forName: name) }
		let cache = AILiveModelCache(preferences: AIDefaultsDataPreferences(defaults: defaults), storageKey: "cache", providerKey: { String(describing: $0) }, onChange: {})
		await withTaskGroup(of: Void.self) { group in
			for provider in [AIProviderType.openAI, .anthropic, .gemini, .deepseek, .zAI, .ollama] { group.addTask { cache.store(["model"], for: provider) } }
			await group.waitForAll()
		}
		for provider in [AIProviderType.openAI, .anthropic, .gemini, .deepseek, .zAI, .ollama] { XCTAssertEqual(cache.models(for: provider), ["model"]) }
	}
	func testSeparateSuitesKeepModelCacheAndOverrideStateIndependent() {
		let names = ["ModelIsolation."+UUID().uuidString, "ModelIsolation."+UUID().uuidString], defaults = names.map { UserDefaults(suiteName: $0)! }
		defer { for (d, name) in zip(defaults, names) { d.removePersistentDomain(forName: name) } }
		let caches = defaults.map { AILiveModelCache(preferences: AIDefaultsDataPreferences(defaults: $0), storageKey: "cache", providerKey: { String(describing: $0) }, onChange: {}) }
		caches[0].store(["first"], for: .openAI); XCTAssertNil(caches[1].models(for: .openAI))
		let first = AIModelOverrideStore(initial: .init(), persist: { _, _ in }), second = AIModelOverrideStore(initial: .init(), persist: { _, _ in })
		first.update { $0.temperature["model"] = 0.7 }; XCTAssertNil(second.temperatureOverride(for: "model"))
	}
	func testCalloutCanReenterOverrideStoreWithoutHoldingItsLock() {
		let holder = Mutex<AIModelOverrideStore?>(nil)
		let reads = Mutex<[Int]>([])
		let store = AIModelOverrideStore(initial: .init(), persist: { _, _ in
			let current = holder.withLock { $0 }; reads.withLock { $0.append(current?.snapshot.stream.count ?? -1) }
		})
		holder.withLock { $0 = store }
		store.update { $0.stream["model"] = false }
		XCTAssertEqual(reads.withLock { $0 }, [1])
		holder.withLock { $0 = nil }
	}
	func testMalformedLiveCacheRemainsUnreadableUntilExplicitStore() {
		let name = "MalformedCache."+UUID().uuidString, defaults = UserDefaults(suiteName: name)!
		defer { defaults.removePersistentDomain(forName: name) }
		defaults.set(Data("invalid".utf8), forKey: "cache")
		let cache = AILiveModelCache(preferences: AIDefaultsDataPreferences(defaults: defaults), storageKey: "cache", providerKey: { String(describing: $0) }, onChange: {})
		XCTAssertNil(cache.models(for: .openAI)); XCTAssertEqual(defaults.data(forKey: "cache"), Data("invalid".utf8))
		cache.store(["model"], for: .openAI); XCTAssertEqual(cache.models(for: .openAI), ["model"])
	}
}
