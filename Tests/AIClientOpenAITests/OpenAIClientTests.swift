import AIClientKit
import AIClientHTTP
import AIClientOpenAI
import Foundation
import Synchronization
import XCTest

@MainActor
final class OpenAIClientTests: XCTestCase {
	private func client(_ f: OpenAIWireFixture, usage: Bool = true, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> OpenAIClient {
		let http = URLSessionAIHTTPClient(configuration: f.configuration)
		return .init(apiKey: "fixture-key", configuration: .init(baseURL: f.url, includeUsageInStream: usage), httpClient: http, streamingHTTPClient: http, sleep: sleep)
	}
	private func input(responses: Bool = false, model: String = "fixture", reasoning: String? = nil, tier: String? = nil, stream: Bool = true, id: UUID = UUID()) -> AIRequest {
		let tail = "<file_tree>\nroot\n</file_tree>"
		let messages: [AIRequestMessage] = [.init(role: .system, text: "sys"), .init(role: .user, text: responses ? tail+"\n\nfirst" : "first"), .init(role: .assistant, text: "reply"), .init(role: .user, text: responses ? "last" : tail+"\nlast")]
		return .init(id: id, model: .init(id: model, provider: .openAI, displayName: model, capabilities: stream ? [.streaming] : []), messages: messages, options: .init(reasoningEffort: reasoning, serviceTier: tier))
	}
	private func golden(_ name: String) throws -> NSDictionary {
		let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json")))
		return try JSONSerialization.jsonObject(with: data) as! NSDictionary
	}
	private func collect(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] { var result: [AIStreamResult] = []; for try await event in stream { result.append(event) }; return result }
	private func waitRequests(_ f: OpenAIWireFixture, _ count: Int = 1) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(3))
		while f.requests.count < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
		XCTAssertGreaterThanOrEqual(f.requests.count, count)
	}
	func testWholeChatPayloadMatchesSDKBaseline() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.chat]); defer { f.remove() }
		let result = try await client(f).complete(input(model: "unknown_model"), profile: .init(chatMaxTokens: 16384))
		XCTAssertEqual(result.text, "answer"); XCTAssertEqual(result.promptTokens, 11)
		XCTAssertEqual(try f.body() as NSDictionary, try golden("chat"))
		XCTAssertEqual(f.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
	}
	func testWholeO1PayloadMatchesSDKBaseline() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.chat]); defer { f.remove() }
		let r = input(model: "unknown_model")
		let messages: [AIRequestMessage] = [.init(role: .user, text: "first"), .init(role: .assistant, text: "reply"), .init(role: .user, text: "<file_tree>\nroot\n</file_tree>\n\n\n\nsys\nlast")]
		_ = try await client(f).complete(.init(model: r.model, messages: messages), profile: .init(chatMaxTokens: 65536, useMaxCompletionTokens: true, chatTemperatureAllowed: false))
		XCTAssertEqual(try f.body() as NSDictionary, try golden("o1"))
	}
	func testAllResponsesPayloadsMatchSDKBaseline() async throws {
		for (name, model, reasoning, tier) in [("responses", "fixture", nil as String?, nil as String?), ("reasoning", "fixture", "high", nil), ("builtIn", "gpt-5.2", "high", "priority")] {
			let f = OpenAIWireFixture([OpenAIWireFixture.response()]); defer { f.remove() }
			let result = try await client(f).complete(input(responses: true, model: model, reasoning: reasoning, tier: tier), profile: .init(usesResponsesAPI: true, omitResponseMaxTokens: name == "builtIn"))
			XCTAssertEqual(result.text, "answer"); XCTAssertEqual(result.completionTokens, 7)
			XCTAssertEqual(try f.body() as NSDictionary, try golden(name))
		}
	}
	func testWholeBackgroundPayloadAndMethodsMatchSDKBaseline() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.response("queued"), OpenAIWireFixture.response(), OpenAIWireFixture.response("cancelled")]); defer { f.remove() }
		let c = client(f)
		let result = try await c.createBackgroundResponse(input(responses: true, model: "gpt-5.2", reasoning: "high", tier: "priority"), profile: .init(usesResponsesAPI: true, responsesMaxTokens: 42))
		XCTAssertEqual(result.status, .queued); XCTAssertEqual(try f.body() as NSDictionary, try golden("background"))
		_ = try await c.fetchResponse(id: result.id); _ = try await c.cancelResponse(id: result.id)
		XCTAssertEqual(f.requests.map(\.httpMethod), ["POST", "GET", "POST"])
	}
	func testStreamPayloadUsageAndUnicodeMatchSDKBaseline() async throws {
		for usage in [true, false] {
			let f = OpenAIWireFixture([OpenAIWireFixture.chatStream]); defer { f.remove() }
			let values = try await collect(client(f, usage: usage).stream(input(model: "unknown_model"), profile: .init(chatMaxTokens: 16384)))
			XCTAssertEqual(values.map(\.type), ["content", "message_stop"]); XCTAssertEqual(values.first?.text, "hé 🧭"); XCTAssertEqual(values.first?.reasoning, "think"); XCTAssertEqual(values.last?.completionTokens, 7)
			XCTAssertEqual(try f.body() as NSDictionary, try golden(usage ? "chatStream" : "chatStreamNoUsage"))
		}
	}
	func testResponsesIgnoreUnknownKeepaliveAndRejectLateContentAfterCompletion() async throws {
		let body = "data: {\"type\":\"keepalive\"}\n\ndata: {\"type\":\"response.future_event\"}\n\ndata: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":11,\"output_tokens\":7}}}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"late\"}\n\n"
		let f = OpenAIWireFixture([body]); defer { f.remove() }
		let result = try await collect(client(f).stream(input(responses: true, reasoning: "high"), profile: .init(usesResponsesAPI: true)))
		XCTAssertEqual(result.map(\.type), ["content", "content", "message_stop"])
		XCTAssertEqual(result.first?.reasoning, "thinking"); XCTAssertEqual(result[1].text, "answer"); XCTAssertEqual(result.last?.promptTokens, 11)
		XCTAssertEqual((try f.body()["reasoning"] as? [String: Any])?["summary"] as? String, "auto")
	}
	func testBackgroundPollingBackoffStatusAndExactlyOnceCompletion() async throws {
		let bodies = [OpenAIWireFixture.response("queued"), OpenAIWireFixture.response("in_progress"), OpenAIWireFixture.response()]
		let f = OpenAIWireFixture(bodies); defer { f.remove() }; let durations = Mutex<[Duration]>([])
		let values = try await collect(client(f, sleep: { d in durations.withLock { $0.append(d) } }).streamResponse(id: "resp_fixture"))
		XCTAssertEqual(values.filter { $0.type == "message_stop" }.count, 1); XCTAssertEqual(values.last?.completionTokens, 7)
		XCTAssertEqual(durations.withLock { $0 }, [.seconds(3), .seconds(4)])
		XCTAssertEqual(f.requests.count, 3); XCTAssertFalse(f.requests.contains { $0.url?.path.hasSuffix("cancel") == true })
	}
	func testBackgroundTerminalFailuresAndUnknownStatusRetention() async throws {
		for status in ["failed", "incomplete", "cancelled"] {
			let f = OpenAIWireFixture([OpenAIWireFixture.response(status)]); defer { f.remove() }
			do { _ = try await collect(client(f).streamResponse(id: "resp_fixture")); XCTFail("Expected terminal failure") } catch AIProviderError.invalidResponse {}
		}
		let data = Data(OpenAIWireFixture.response("future_status").utf8), response = try OpenAIResponse(data: data)
		XCTAssertEqual(response.status?.rawValue, "future_status"); XCTAssertEqual(response.rawJSON, data)
	}
	func testConsumerCancellationSendsOneRemoteCancelAndStopsPolling() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.response("queued"), OpenAIWireFixture.response("cancelled")]); defer { f.remove() }
		let c = client(f, sleep: { _ in try await Task.sleep(for: .seconds(100)) })
		let stream = try await c.streamResponse(id: "resp_fixture")
		let task = Task { for try await _ in stream {} }
		try await waitRequests(f); task.cancel(); try await task.value
		try await waitRequests(f, 2)
		XCTAssertEqual(f.requests.filter { $0.url?.path.hasSuffix("/cancel") == true }.count, 1)
	}
	func testExplicitCancellationDuringCreationCancelsLateOwnedResponseExactlyOnce() async throws {
		let gate = LateCreationHTTP()
		let r = input(responses: true, stream: false)
		let c = OpenAIClient(apiKey: "fixture", httpClient: gate, streamingHTTPClient: gate, sleep: { _ in })
		let stream = try await c.stream(r, profile: .init(usesResponsesAPI: true)); let consumer = Task { for try await _ in stream {} }
		let started = await gate.waitForCreation(); XCTAssertTrue(started); await c.cancel(requestID: r.id); await gate.release(); try await consumer.value
		let cancelled = await gate.waitForCancel(); XCTAssertTrue(cancelled); let count = await gate.cancelCount; XCTAssertEqual(count, 1)
	}
	func testMalformedResponsesValidationAndHTTPErrorClassification() async throws {
		do { _ = try OpenAIResponse(data: Data("{\"status\":\"completed\"}".utf8)); XCTFail("Missing ID accepted") } catch AIProviderError.invalidResponse {}
		let f = OpenAIWireFixture(["{\"error\":{\"code\":\"denied\",\"message\":\"bad key\"}}"], status: 401); defer { f.remove() }
		do { _ = try await client(f).complete(input()); XCTFail("Expected authentication failure") } catch let e as OpenAIClientError { XCTAssertEqual(e.statusCode, 401); XCTAssertEqual(e.code, "denied") }
		let c = client(f), r = input()
		do { _ = try await c.complete(.init(model: r.model, messages: r.messages, attachments: [.init(mediaType: "image/png", data: Data())])); XCTFail("Expected attachment rejection") } catch AIProviderError.invalidConfiguration {}
	}
	func testRequestCancellationAndIDReuse() async throws {
		let stopped = expectation(description: "URLSession delivers stopLoading for cancelled transport")
		let f = OpenAIWireFixture([""], hang: true, onStop: { stopped.fulfill() }); defer { f.remove() }; let c = client(f), r = input()
		let task = Task { try await c.complete(r) }; try await waitRequests(f); await c.cancel(requestID: r.id)
		do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
		// Task cancellation may complete before URLSession invokes the protocol callback.
		await fulfillment(of: [stopped], timeout: 3)
		XCTAssertGreaterThan(f.stops, 0)
		let second = Task { try await c.complete(r) }; second.cancel()
		do { _ = try await second.value; XCTFail("Expected cancellation") } catch is CancellationError {}
	}
	func testErasedProviderUsesNeutralResponsesCapability() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.response()]); defer { f.remove() }
		let c: any AIClientProviding = client(f), r = input(responses: true)
		let request = AIRequest(model: .init(id: "fixture", provider: .openAI, displayName: "Fixture", capabilities: [.streaming, .responsesAPI]), messages: r.messages)
		let result = try await c.complete(request)
		XCTAssertEqual(result.text, "answer"); XCTAssertEqual(f.requests.first?.url?.path, "/v1/responses")
	}
	func testVariantsKeepBasePathsVersionsAndFeatherlessUsagePolicy() async throws {
		for config in [OpenAIClientConfiguration.deepSeek, .gemini, .featherless, .zAI(codingPlan: true), .zAI(codingPlan: false), .ollama(baseURL: URL(string: "http://localhost:11434")!)] {
			let http = RecordingHTTP()
			let c = OpenAIClient(apiKey: "fixture", configuration: config, httpClient: http, streamingHTTPClient: http)
			_ = try await c.complete(input())
			let calls = await http.calls, call = try XCTUnwrap(calls.first)
			XCTAssertEqual(call.url?.host, config.baseURL?.host)
			XCTAssertEqual(call.url?.path, (config.baseURL?.path ?? "") + "/" + (config.apiVersion ?? "v1") + "/chat/completions")
		}
	}
	func testSDKProxyAzureAndBaseQueryRulesAndEscapedResponseIDs() async throws {
		for (base, expected) in [("https://fixture.invalid/proxy/?ignored=1", "/proxy/v1/chat/completions"), ("https://fixture.invalid/openai.azure.com?ignored=1", "/v1/chat/completions")] {
			let http = RecordingHTTP()
			let c = OpenAIClient(apiKey: "fixture", configuration: .init(baseURL: URL(string: base)!), httpClient: http, streamingHTTPClient: http)
			_ = try await c.complete(input()); let calls = await http.calls
			XCTAssertEqual(calls.first?.url?.path, expected); XCTAssertEqual(calls.first?.url?.query, "ignored=1")
		}
		let f = OpenAIWireFixture([OpenAIWireFixture.response()]); defer { f.remove() }
		_ = try await client(f).fetchResponse(id: "resp/../other?query")
		let call = try XCTUnwrap(f.requests.first)
		XCTAssertNil(call.url?.query)
		XCTAssertTrue(call.url!.absoluteString.contains("resp%2F%2E%2E%2Fother%3Fquery"))
	}
	func testCuratedDescriptorUsesSharedRequestDefaultsThroughErasedClient() async throws {
		let f = OpenAIWireFixture([OpenAIWireFixture.response()]); defer { f.remove() }
		let c: any AIClientProviding = client(f)
		let request = AIRequest(model: .init(id: "gpt-5.5-high", provider: .openAI, displayName: "High", capabilities: [.streaming]), messages: [.init(role: .user, text: "hello")])
		_ = try await c.complete(request)
		let body = try f.body()
		XCTAssertEqual(body["model"] as? String, "gpt-5.5")
		XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
		XCTAssertNil(body["max_output_tokens"])
	}
}

private actor RecordingHTTP: AIHTTPClient {
	private(set) var calls: [URLRequest] = []
	func data(for request: URLRequest) async throws -> AIHTTPResponse {
		calls.append(request)
		return .init(data: Data(OpenAIWireFixture.chat.utf8), http: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
	}
	func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) { throw URLError(.unsupportedURL) }
}

/// Non-cooperating completion fixture exercises cancellation after server allocation.
private actor LateCreationHTTP: AIHTTPClient {
	private var started = false, cancelled = false
	private var pending: CheckedContinuation<Void, Never>?
	private(set) var cancelCount = 0
	func waitForCreation() async -> Bool { let deadline = ContinuousClock.now.advanced(by: .seconds(3)); while !started && ContinuousClock.now < deadline { await Task.yield() }; return started }
	func waitForCancel() async -> Bool { let deadline = ContinuousClock.now.advanced(by: .seconds(3)); while !cancelled && ContinuousClock.now < deadline { await Task.yield() }; return cancelled }
	func release() { pending?.resume(); pending = nil }
	func data(for request: URLRequest) async throws -> AIHTTPResponse {
		if request.url!.path.hasSuffix("cancel") { cancelCount += 1; cancelled = true }
		else { await withCheckedContinuation { pending = $0; started = true } }
		return .init(data: Data(OpenAIWireFixture.response("queued").utf8), http: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
	}
	func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) { throw URLError(.unsupportedURL) }
}
