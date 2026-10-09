import AIClientKit
import AIClientHTTP
import AIClientOpenAICompatible
import Foundation
import Synchronization
import XCTest

@MainActor
final class OpenAICompatibleStreamingTests: XCTestCase {
    private func provider(_ baseURL: URL) -> OpenAICompatibleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let transport = URLSessionAIHTTPClient(configuration: configuration)
        return OpenAICompatibleClient(baseURL: baseURL.absoluteString, apiKey: "fixture-key", defaultModel: "fixture-model",
                                      httpClient: transport, streamingHttpClient: transport, sleep: { _ in })
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
}

/// URLProtocol's callbacks may run concurrently; fixture state is serialized by Mutex.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let status: Int; let chunks: [Data] }
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
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
