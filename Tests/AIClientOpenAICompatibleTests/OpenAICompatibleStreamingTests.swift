import AIClientKit
import AIClientHTTP
import AIClientOpenAICompatible
import Foundation
import Synchronization
import XCTest

@MainActor
final class OpenAICompatibleStreamingTests: XCTestCase {
    private func provider(_ baseURL: URL, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> OpenAICompatibleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let transport = URLSessionAIHTTPClient(configuration: configuration)
        return OpenAICompatibleClient(baseURL: baseURL.absoluteString, apiKey: "fixture-key", defaultModel: "fixture-model",
                                      httpClient: transport, streamingHttpClient: transport, sleep: sleep)
    }

    private func input() -> AIRequest {
        .init(model: .init(id: "fixture-model", provider: .customProvider, displayName: "Fixture", capabilities: [.streaming]),
              messages: [.init(role: .user, text: "hello")])
    }

    func testSSEPreservesFragmentedUnicodeAndDoneProducesOneStop() async throws {
        let text = ": comment\nevent: message\ndata: {\"choices\":[{\"delta\":{\"content\":\"hé 🧭\"},\"finish_reason\":null}]}\r\n\r\ndata: [DONE]\n\n"
        let bytes = Array(text.utf8)
        let fixture = FixtureURLProtocol.install([.init(status: 200, chunks: bytes.map { Data([$0]) })])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        let stream = try await provider(fixture).stream(input())
        var events: [AIStreamResult] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(events.first?.text, "hé 🧭")
        XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 1)
    }

    func testFinishReasonStopsBeforeFollowingDoneMarker() async throws {
        let text = "data: {\"choices\":[{\"delta\":{\"content\":\"last\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let fixture = FixtureURLProtocol.install([.init(status: 200, chunks: [Data(text.utf8)])])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        var events: [AIStreamResult] = []
        for try await event in try await provider(fixture).stream(input()) { events.append(event) }
        XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
    }

    func testStreamEstablishmentRetriesTransientStatusAndUsesServerErrorDetails() async throws {
        let fixture = FixtureURLProtocol.install([
            .init(status: 503, chunks: [Data("{\"error\":\"temporarily unavailable\"}".utf8)]),
            .init(status: 200, chunks: [Data("data: [DONE]\n\n".utf8)])
        ])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        var kinds: [String] = []
        for try await event in try await provider(fixture).stream(input()) { kinds.append(event.type) }
        XCTAssertEqual(kinds, ["message_stop"])
        XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 2)
    }

    func testStreamAuthenticationFailureDoesNotRetry() async throws {
        let fixture = FixtureURLProtocol.install([.init(status: 401, chunks: [Data("{\"error\":{\"message\":\"denied\"}}".utf8)])])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        do {
            for try await _ in try await provider(fixture).stream(input()) {}
            XCTFail("Expected authentication error")
        } catch let error as CustomOpenAIProviderError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.errorMessage, "denied")
        }
        XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 1)
    }

    private func chunk(_ content: String, finish: String? = nil) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"},\"finish_reason\":\(finish.map { "\"\($0)\"" } ?? "null")}]}\n\n"
    }

    private func drain(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async -> (events: [AIStreamResult], error: Error?) {
        var events: [AIStreamResult] = []
        do { for try await event in stream { events.append(event) }; return (events, nil) }
        catch { return (events, error) }
    }

    func testConnectionLostAfterContentIsThrownWithoutRestartingTheStream() async throws {
        let fixture = FixtureURLProtocol.install([
            .init(status: 200, chunks: [Data(chunk("partial").utf8)], failure: .networkConnectionLost),
            .init(status: 200, chunks: [Data((chunk("again", finish: "stop") + "data: [DONE]\n\n").utf8)])
        ])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        let (events, error) = await drain(try await provider(fixture).stream(input()))
        XCTAssertEqual(events.map(\.type), ["content"])
        XCTAssertEqual(events.compactMap(\.text).joined(), "partial")
        XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 1)
    }

    func testInBandErrorChunkIsThrownAndNeverRetried() async throws {
        for (prefix, error) in [("", "{\"message\":\"upstream overloaded\"}"), (chunk("partial"), "{\"message\":\"upstream overloaded\"}"), ("", "\"upstream overloaded\"")] {
            let fixture = FixtureURLProtocol.install([
                .init(status: 200, chunks: [Data((prefix + "data: {\"error\":\(error)}\n\n").utf8)]),
                .init(status: 200, chunks: [Data((chunk("again", finish: "stop") + "data: [DONE]\n\n").utf8)])
            ])
            defer { FixtureURLProtocol.remove(fixture.host!) }
            let (events, error) = await drain(try await provider(fixture).stream(input()))
            XCTAssertFalse(events.contains { $0.type == "message_stop" })
            XCTAssertEqual(events.compactMap(\.text).joined(), prefix.isEmpty ? "" : "partial")
            XCTAssertEqual((error as? CustomOpenAIProviderError)?.errorMessage, "upstream overloaded")
            XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 1)
        }
    }

    func testDataLinesWithoutASpaceAfterTheColonAreRead() async throws {
        let text = "data:{\"choices\":[{\"delta\":{\"content\":\"tight\"},\"finish_reason\":null}]}\n\ndata:[DONE]\n\n"
        let fixture = FixtureURLProtocol.install([.init(status: 200, chunks: [Data(text.utf8)])])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        let (events, error) = await drain(try await provider(fixture).stream(input()))
        XCTAssertNil(error)
        XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(events.first?.text, "tight")
    }

    func testFinishReasonIsReportedOnTheStopEvent() async throws {
        for reason in ["stop", "length", "content_filter"] {
            let fixture = FixtureURLProtocol.install([.init(status: 200, chunks: [Data((chunk("text", finish: reason) + "data: [DONE]\n\n").utf8)])])
            defer { FixtureURLProtocol.remove(fixture.host!) }
            let (events, error) = await drain(try await provider(fixture).stream(input()))
            XCTAssertNil(error)
            XCTAssertEqual(events.map(\.type), ["content", "message_stop"])
            XCTAssertEqual(events.last?.stopReason, reason)
        }
    }

    func testStreamThatEndsWithoutACompletionSignalThrows() async throws {
        let fixture = FixtureURLProtocol.install([
            .init(status: 200, chunks: [Data(chunk("cut").utf8)]),
            .init(status: 200, chunks: [Data((chunk("again", finish: "stop") + "data: [DONE]\n\n").utf8)])
        ])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        let (events, error) = await drain(try await provider(fixture).stream(input()))
        XCTAssertEqual(events.map(\.type), ["content"])
        XCTAssertNotNil(error as? CustomOpenAIProviderError)
        XCTAssertEqual(FixtureURLProtocol.callCount(fixture.host!), 1)
    }

    func testStreamEstablishmentHonoursRetryAfterAndGivesUpWhenItIsTooLong() async throws {
        let delays = Mutex<[TimeInterval]>([])
        let fixture = FixtureURLProtocol.install([
            .init(status: 429, chunks: [Data("{\"error\":\"slow down\"}".utf8)], headers: ["Retry-After": "7"]),
            .init(status: 200, chunks: [Data("data: [DONE]\n\n".utf8)])
        ])
        defer { FixtureURLProtocol.remove(fixture.host!) }
        let (events, error) = await drain(try await provider(fixture, sleep: { d in delays.withLock { $0.append(d) } }).stream(input()))
        XCTAssertNil(error); XCTAssertEqual(events.map(\.type), ["message_stop"])
        XCTAssertEqual(delays.withLock { $0 }, [7])

        let long = FixtureURLProtocol.install([
            .init(status: 429, chunks: [Data("{\"error\":\"slow down\"}".utf8)], headers: ["Retry-After": "3600"]),
            .init(status: 200, chunks: [Data("data: [DONE]\n\n".utf8)])
        ])
        defer { FixtureURLProtocol.remove(long.host!) }
        let (_, longError) = await drain(try await provider(long).stream(input()))
        XCTAssertEqual((longError as? CustomOpenAIProviderError)?.statusCode, 429)
        XCTAssertEqual(FixtureURLProtocol.callCount(long.host!), 1)
    }
}

/// URLProtocol's callbacks may run concurrently; fixture state is serialized by Mutex.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let status: Int; let chunks: [Data]; var failure: URLError.Code? = nil; var headers: [String: String] = [:] }
    private struct Script: Sendable { var responses: [Response]; var calls: Int = 0 }
    private static let scripts = Mutex<[String: Script]>([:])

    static func install(_ responses: [Response]) -> URL {
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        scripts.withLock { $0[host] = Script(responses: responses) }
        return URL(string: "https://" + host)!
    }
    static func remove(_ host: String) { scripts.withLock { $0[host] = nil } }
    static func callCount(_ host: String) -> Int { scripts.withLock { $0[host]?.calls ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let response: Response? = Self.scripts.withLock { scripts in
            guard var script = scripts[host], !script.responses.isEmpty else { return nil }
            let next = script.responses.removeFirst()
            script.calls += 1
            scripts[host] = script
            return next
        }
        guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"].merging(response.headers) { $1 })!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = response.failure {
            // Fail after the delivered bytes have been consumed; an immediate failure
            // lets URLSession discard data that the reader has not pulled yet.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { client?.urlProtocol(self, didFailWithError: URLError(failure)) }
        } else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
