import Foundation
import Synchronization
import AIClientKit
import AIClientHTTP
import AIClientAnthropic
import XCTest

@MainActor
final class AnthropicClientTests: XCTestCase {
	private func client(_ fixture: AnthropicFixture) -> AnthropicClient {
		.init(apiKey: "fixture-key", configuration: .init(baseURL: fixture.url.absoluteString), sessionConfiguration: fixture.configuration,
		      catalogHTTPClient: URLSessionAIHTTPClient(configuration: fixture.configuration))
	}
	private func request(_ model: String = "fixture", stream: Bool = true, tokens: Int? = nil, temperature: Double? = nil, id: UUID = UUID()) -> AIRequest {
		.init(id: id, model: .init(id: model, provider: .anthropic, displayName: model, capabilities: stream ? [.streaming] : []),
		      messages: [.init(role: .system, text: "sys"), .init(role: .user, text: "hello")], options: .init(maxTokens: tokens, temperature: temperature))
	}
	private func events(_ client: AnthropicClient, _ request: AIRequest) async throws -> [AIStreamResult] {
		var result: [AIStreamResult] = []
		for try await value in try await client.stream(request) { result.append(value) }
		return result
	}
	private func waitForRequest(_ fixture: AnthropicFixture) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(3))
		while fixture.requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
		XCTAssertFalse(fixture.requests.isEmpty)
	}

	func testCompletionPreservesSystemCacheHeadersTextAndUsage() async throws {
		let f = AnthropicFixture(body: AnthropicFixture.completion); defer { f.remove() }
		let result = try await client(f).complete(request(tokens: 123, temperature: 0.7))
		XCTAssertEqual(result.text, "reasonanswer"); XCTAssertEqual(result.promptTokens, 11); XCTAssertEqual(result.completionTokens, 8)
		let call = try XCTUnwrap(f.requests.first)
		XCTAssertEqual(call.url?.path, "/v1/messages"); XCTAssertEqual(call.httpMethod, "POST")
		XCTAssertEqual(call.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
		XCTAssertEqual(call.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
		XCTAssertEqual(call.value(forHTTPHeaderField: "anthropic-beta"), "messages-2023-12-15,prompt-caching-2024-07-31,output-128k-2025-02-19")
		let body = try f.jsonBody(); XCTAssertEqual(body["max_tokens"] as? Int, 123); XCTAssertNil(body["temperature"])
		let system = try XCTUnwrap(body["system"] as? [[String: Any]])
		XCTAssertEqual(system.first?["text"] as? String, "sys")
		XCTAssertEqual((system.first?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
	}

	func testThinkingCompletionCapsAndSuffixesMatchLegacy() async throws {
		for (model, base, budget, output) in [("fixture-thinking-max", "fixture", 32000, 64000), ("fixture-opus-thinking", "fixture-opus", 16000, 32000), ("fixture-sonnet-thinking", "fixture-sonnet", 16000, 64000)] {
			let f = AnthropicFixture(body: AnthropicFixture.completion); defer { f.remove() }
			_ = try await client(f).complete(request(model)); let body = try f.jsonBody()
			XCTAssertEqual(body["model"] as? String, base); XCTAssertEqual(body["max_tokens"] as? Int, output)
			XCTAssertEqual((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int, budget)
		}
		let f = AnthropicFixture(body: AnthropicFixture.completion); defer { f.remove() }
		_ = try await client(f).complete(request("fixture-thinking-max", tokens: 44))
		XCTAssertEqual(try f.jsonBody()["max_tokens"] as? Int, 44)
	}

	func testStreamPreservesThinkingProjectionAndEmitsOneStop() async throws {
		let f = AnthropicFixture(body: AnthropicFixture.stream); defer { f.remove() }
		let result = try await events(client(f), request("fixture-opus-thinking", tokens: 44, temperature: 0.9))
		XCTAssertEqual(result.map(\.type), ["content_block_start", "content_block_delta", "content_block_stop", "content_block_delta", "message_stop"])
		XCTAssertEqual(result.compactMap(\.reasoning), ["r", "d", "r"])
		XCTAssertEqual(result.compactMap(\.text).joined(), "hé 🧭")
		XCTAssertEqual(result.last?.promptTokens, 11); XCTAssertEqual(result.last?.completionTokens, 8)
		let body = try f.jsonBody(); XCTAssertEqual(body["max_tokens"] as? Int, 32000); XCTAssertNil(body["temperature"])
	}

	func testStreamDefaultAndExplicitTemperatureKeepFixedCap() async throws {
		for temperature: Double? in [nil, 0.8] {
			let f = AnthropicFixture(body: AnthropicFixture.stream); defer { f.remove() }
			_ = try await events(client(f), request(tokens: 123, temperature: temperature))
			let body = try f.jsonBody(); XCTAssertEqual(body["max_tokens"] as? Int, 8192)
			XCTAssertEqual(body["temperature"] as? Double, temperature ?? 0)
		}
	}

	func testNativeStartAndDeltaUsageAreReconciledAtStop() async throws {
		let body = "data: {\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7,\"thinking_tokens\":2}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
		let f = AnthropicFixture(body: body); defer { f.remove() }
		let result = try await events(client(f), request())
		XCTAssertNil(result.first?.promptTokens); XCTAssertEqual(result.last?.promptTokens, 11); XCTAssertEqual(result.last?.completionTokens, 9)
	}

	func testCleanEOFFinalizesOnceAndRejectsTrailingEventsAfterStop() async throws {
		for body in ["data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"before\"}}\n\n", "data: {\"type\":\"message_stop\"}\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"late\"}}\n\n"] {
			let f = AnthropicFixture(body: body); defer { f.remove() }
			let result = try await events(client(f), request())
			XCTAssertEqual(result.filter { $0.type == "message_stop" }.count, 1)
			XCTAssertFalse(result.contains { $0.text == "late" })
		}
	}

	func testNonStreamingCapabilityFallsBackToCompletion() async throws {
		let f = AnthropicFixture(body: AnthropicFixture.completion); defer { f.remove() }
		let result = try await events(client(f), request(stream: false, tokens: 123))
		XCTAssertEqual(result.map(\.type), ["content", "message_stop"]); XCTAssertEqual(result.last?.completionTokens, 8)
		XCTAssertEqual(try f.jsonBody()["stream"] as? Bool, false)
	}

	func testValidationRejectsMissingSystemAndUnsupportedAttachmentsBeforeNetworking() async throws {
		let f = AnthropicFixture(body: AnthropicFixture.completion); defer { f.remove() }
		let c = client(f), r = request()
		do { _ = try await c.complete(.init(model: r.model, messages: [])); XCTFail("Expected prompt error") } catch AIProviderError.invalidSystemPrompt {}
		do { _ = try await c.stream(.init(model: r.model, messages: r.messages, attachments: [.init(mediaType: "image/png", data: Data())])); XCTFail("Expected attachment error") } catch AIProviderError.invalidConfiguration {}
		XCTAssertTrue(f.requests.isEmpty)
	}

	func testStatusAndStreamErrorsUseNeutralProviderError() async throws {
		let f = AnthropicFixture(body: "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"denied\"}}", status: 401); defer { f.remove() }
		do { _ = try await client(f).complete(request()); XCTFail("Expected error") }
		catch let e as AnthropicClientError { XCTAssertEqual(e.kind, .responseUnsuccessful); XCTAssertEqual(e.displayDescription, "status code 401denied") }
		let s = AnthropicFixture(body: "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"); defer { s.remove() }
		do { _ = try await events(client(s), request()); XCTFail("Expected stream error") }
		catch let e as AnthropicClientError { XCTAssertEqual(e.kind, .stream); XCTAssertEqual(e.displayDescription, "busy") }
	}

	func testExplicitCancellationStopsTransportAndAllowsIDReuse() async throws {
		let f = AnthropicFixture(body: "", hang: true); defer { f.remove() }
		let c = client(f), r = request()
		let task = Task { try await c.complete(r) }
		try await waitForRequest(f); await c.cancel(requestID: r.id)
		do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
		XCTAssertGreaterThan(f.stops, 0)
		let second = Task { try await c.complete(r) }
		await Task.yield(); second.cancel()
		do { _ = try await second.value; XCTFail("Expected cancellation") } catch is CancellationError {}
	}

	func testConsumerCancellationAndActiveIDCollisionAreScoped() async throws {
		let f = AnthropicFixture(body: "", hang: true); defer { f.remove() }
		let c = client(f), r = request()
		let stream = try await c.stream(r)
		let consumer = Task { for try await _ in stream {} }
		try await waitForRequest(f)
		do { _ = try await c.stream(r); XCTFail("Expected active ID rejection") } catch AIProviderError.invalidConfiguration {}
		consumer.cancel(); try await consumer.value
		let deadline = ContinuousClock.now.advanced(by: .seconds(3))
		while f.stops == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
		XCTAssertGreaterThan(f.stops, 0)
	}

	func testCatalogUsesConfiguredEndpointAndNativeAuthentication() async throws {
		let f = AnthropicFixture(body: "{\"data\":[{\"id\":\"fixture-model\"}]}"); defer { f.remove() }
		let c = AnthropicClient(apiKey: "key", configuration: .init(baseURL: f.url.absoluteString, apiVersion: "fixture-version", betaHeaders: []), sessionConfiguration: f.configuration, catalogHTTPClient: URLSessionAIHTTPClient(configuration: f.configuration))
		let models = try await c.models()
		XCTAssertEqual(models.map(\.id), ["fixture-model"])
		XCTAssertEqual(models.first?.provider, .anthropic)
		XCTAssertEqual(f.requests.first?.url?.path, "/v1/models")
		XCTAssertEqual(f.requests.first?.value(forHTTPHeaderField: "anthropic-version"), "fixture-version")
		XCTAssertEqual(f.requests.first?.value(forHTTPHeaderField: "x-api-key"), "key")
	}

	func testPreCancelledCallerStartsNoStream() async throws {
		let f = AnthropicFixture(body: "", hang: true); defer { f.remove() }
		let c = client(f), r = request()
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await c.stream(r)
		}
		do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
		XCTAssertTrue(f.requests.isEmpty)
	}

	func testCancellingOneRequestLeavesAnotherRunning() async throws {
		let f = AnthropicFixture(body: "", hang: true); defer { f.remove() }
		let c = client(f), first = request(), second = request()
		let finished = Mutex<Set<UUID>>([])
		let a = try await c.stream(first), b = try await c.stream(second)
		let one = Task { for try await _ in a {}; finished.withLock { $0.insert(first.id) } }
		let two = Task { for try await _ in b {}; finished.withLock { $0.insert(second.id) } }
		let deadline = ContinuousClock.now.advanced(by: .seconds(3))
		while f.requests.count < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
		XCTAssertEqual(f.requests.count, 2)
		await c.cancel(requestID: first.id); _ = try await one.value
		XCTAssertEqual(finished.withLock { $0 }, [first.id])
		await c.cancel(requestID: second.id); _ = try await two.value
		XCTAssertEqual(finished.withLock { $0 }, [first.id, second.id])
	}
}
