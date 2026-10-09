import AIClientKit
import AIClientHTTP
@testable import AIClientOpenAICompatible
import Foundation
import Synchronization
import XCTest

@MainActor
final class OpenAICompatibleClientTests: XCTestCase {
    private func request(model: String = "fixture-model", streaming: Bool = true,
                         maxTokens: Int? = nil, temperature: Double? = nil) -> AIRequest {
        AIRequest(model: .init(id: model, provider: .customProvider, displayName: model,
                              capabilities: streaming ? [.streaming] : []),
                  messages: [.init(role: .system, text: "system"), .init(role: .user, text: "hello")],
                  options: .init(maxTokens: maxTokens, temperature: temperature))
    }

    private func client(_ http: ScriptedHTTPClient, configuredMaxTokens: Int? = nil,
                        headers: [String: String] = [:], sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: "https://fixture.invalid/", apiKey: "fixture-key", defaultModel: "fixture-model",
                               customHeaders: headers, configuredMaxTokens: configuredMaxTokens, apiVersion: "v1",
                               httpClient: http, streamingHttpClient: http, sleep: sleep)
    }

    func testCompletionPreservesURLHeadersMessagesAndConfiguredTokenPrecedence() async throws {
        let http = ScriptedHTTPClient(responses: [.okCompletion("answer")])
        let value = try await client(http, configuredMaxTokens: 99, headers: ["Authorization": "Custom fixture", "content-type": "application/custom"]).complete(request(maxTokens: 20, temperature: 0.7))
        XCTAssertEqual(value.text, "answer")
        let calls = await http.state.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url?.absoluteString, "https://fixture.invalid/v1/chat/completions")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Authorization"), "Custom fixture")
        XCTAssertEqual(call.value(forHTTPHeaderField: "Content-Type"), "application/custom")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(call.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 99)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["content"] }, ["system", "hello"])
    }

    func testDefaultTokenSentinelAndModelTemperatureOmissionsRemainCompatible() async throws {
        let http = ScriptedHTTPClient(responses: [.okCompletion("a"), .okCompletion("b")])
        _ = try await client(http).complete(request(maxTokens: 2048))
        _ = try await client(http).complete(request(model: "vendor/openai/o3", temperature: 0.8))
        let calls = await http.state.calls
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls[0].httpBody)) as? [String: Any])
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls[1].httpBody)) as? [String: Any])
        XCTAssertNil(first["max_tokens"])
        XCTAssertEqual(first["temperature"] as? Double, 0.3)
        XCTAssertNil(second["temperature"])
    }

    func testModelsAcceptArrayDataAndModelsEnvelopesWithoutReorderingIDs() async throws {
        for payload in ["[{\"id\":\"b\"},{\"id\":\"a\"}]", "{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"}]}", "{\"models\":[{\"id\":\"b\"},{\"id\":\"a\"}]}"] {
            let http = ScriptedHTTPClient(responses: [.init(status: 200, body: Data(payload.utf8))])
            let models = try await client(http).models()
            XCTAssertEqual(models.map(\.id), ["b", "a"])
            let calls = await http.state.calls
            XCTAssertEqual(calls.first?.url?.path, "/v1/models")
            XCTAssertEqual(calls.first?.httpMethod, "GET")
            XCTAssertNil(calls.first?.value(forHTTPHeaderField: "Content-Type"))
        }
    }

    func testTransientErrorsRetryWithExistingBackoffThenSucceed() async throws {
        let delays = RecordedDelays()
        let http = ScriptedHTTPClient(responses: [.init(status: 503, body: Data("{\"error\":\"unavailable\"}".utf8)), .init(status: 429, body: Data()), .okCompletion("ready")])
        let response = try await client(http, sleep: { await delays.add($0) }).complete(request())
        XCTAssertEqual(response.text, "ready")
        let recorded = await delays.values
        XCTAssertEqual(recorded, [1, 2])
        let count = await http.state.calls.count
        XCTAssertEqual(count, 3)
    }

    func testAuthenticationErrorRetainsServerDetailsAndDoesNotRetry() async throws {
        let http = ScriptedHTTPClient(responses: [.init(status: 401, body: Data("{\"error\":{\"message\":\"denied\",\"type\":\"auth\",\"code\":\"invalid\"}}".utf8))])
        do { _ = try await client(http).complete(request()); XCTFail("Expected authentication failure") }
        catch let error as CustomOpenAIProviderError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.errorMessage, "denied. Type: auth. Code: invalid")
        }
        let count = await http.state.calls.count
        XCTAssertEqual(count, 1)
    }

    func testNonStreamingModelFallsBackToCompletionAndOneStopEvent() async throws {
        let http = ScriptedHTTPClient(responses: [.okCompletion("fallback")])
        let stream = try await client(http).stream(request(streaming: false))
        var events: [AIStreamResult] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(events.first?.text, "fallback")
        let count = await http.state.calls.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationReachesAnInFlightCompletionAndAllowsIDReuse() async throws {
        let started = AsyncStream<Void>.makeStream()
        let http = BlockingHTTPClient(started: started.continuation)
        let provider = OpenAICompatibleClient(baseURL: "https://fixture.invalid", apiKey: "x", defaultModel: "m", httpClient: http, streamingHttpClient: http)
        let input = request()
        let operation = Task { try await provider.complete(input) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await provider.cancel(requestID: input.id)
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        // Registry cleanup is independently pinned below; cancellation must not leave a live operation.
        let registry = CompatibleRequestRegistry()
        let old = try await registry.begin(input.id)
        await registry.cancel(input.id)
        let fresh = try await registry.begin(input.id)
        await registry.finish(input.id, generation: old)
        do { _ = try await registry.begin(input.id); XCTFail("Stale completion removed the fresh operation") }
        catch is AIProviderError {}
        await registry.finish(input.id, generation: fresh)
    }

    func testContextCompositionPreservesLastUserPlacementAndLegacySeparators() {
        let result = OpenAICompatibleMessageBuilder.compose(systemPrompt: "sys", fileTreeXML: "<tree/>", fileContentsXML: "<files/>", metaPrompts: ["meta"], conversation: [.init(role: .user, text: "first"), .init(role: .assistant, text: "reply"), .init(role: .user, text: "last")])
        XCTAssertEqual(result.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(result.map(\.text), ["sys", "first", "reply", "<tree/>\n<files/>\nmeta\n\nlast"])
    }

    func testCancelRequestFinishesStreamAndCancelsPendingHTTPHandshake() async throws {
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let http = BlockingStreamingHTTPClient(started: started.continuation, cancelled: cancelled.continuation)
        let provider = OpenAICompatibleClient(baseURL: "https://fixture.invalid", apiKey: "x", defaultModel: "m", httpClient: http, streamingHttpClient: http)
        let input = request()
        let stream = try await provider.stream(input)
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        await provider.cancel(requestID: input.id)
        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
        var cancellations = cancelled.stream.makeAsyncIterator()
        _ = await cancellations.next()
    }
}

private struct ScriptedResponse: Sendable {
    let status: Int
    let body: Data
    static func okCompletion(_ text: String) -> Self {
        .init(status: 200, body: Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(text)\"}}]}".utf8))
    }
}

private actor ScriptedHTTPState {
    var responses: [ScriptedResponse]
    var calls: [URLRequest] = []
    init(_ responses: [ScriptedResponse]) { self.responses = responses }
    func next(_ request: URLRequest) throws -> ScriptedResponse {
        calls.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private final class ScriptedHTTPClient: AIHTTPClient, Sendable {
    let state: ScriptedHTTPState
    init(responses: [ScriptedResponse]) { state = ScriptedHTTPState(responses) }
    func data(for request: URLRequest) async throws -> AIHTTPResponse {
        let response = try await state.next(request)
        return AIHTTPResponse(data: response.body, http: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) { throw URLError(.unsupportedURL) }
}

private actor RecordedDelays {
    var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}

private final class BlockingHTTPClient: AIHTTPClient, Sendable {
    let started: AsyncStream<Void>.Continuation
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func data(for request: URLRequest) async throws -> AIHTTPResponse {
        started.yield(())
        try await Task.sleep(for: .seconds(60))
        throw URLError(.badServerResponse)
    }
    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) { throw URLError(.unsupportedURL) }
}

private final class BlockingStreamingHTTPClient: AIHTTPClient, Sendable {
    let started: AsyncStream<Void>.Continuation
    let cancelled: AsyncStream<Void>.Continuation
    init(started: AsyncStream<Void>.Continuation, cancelled: AsyncStream<Void>.Continuation) {
        self.started = started; self.cancelled = cancelled
    }
    func data(for request: URLRequest) async throws -> AIHTTPResponse { throw URLError(.unsupportedURL) }
    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        started.yield(())
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled.yield(()); throw error }
        throw URLError(.badServerResponse)
    }
}
