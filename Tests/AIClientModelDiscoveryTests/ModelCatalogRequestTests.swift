import AIClientKit
import AIClientHTTP
import AIClientModelDiscovery
import Foundation
import XCTest

@MainActor
final class ModelCatalogRequestTests: XCTestCase {
    func testAnthropicUsesItsVersionAndKeyHeaders() async throws {
        let http = CatalogHTTPClient([.init(status: 200, body: #"{"data":[{"id":"fixture-claude"}]}"#)])
        let ids = try await AnthropicModelCatalog.fetchModelIDs(apiKey: "fixture-key", httpClient: http)
        XCTAssertEqual(ids, ["fixture-claude"])
        let calls = await http.state.calls
        let request = try XCTUnwrap(calls.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGeminiPaginatesFiltersAndDeduplicatesWithoutReordering() async throws {
        let http = CatalogHTTPClient([
            .init(status: 200, body: #"{"models":[{"name":"models/a","supportedGenerationMethods":["generateContent"]},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next+/ &"}"#),
            .init(status: 200, body: #"{"models":[{"name":"models/a","supportedGenerationMethods":["generateContent"]},{"name":"models/b","supportedGenerationMethods":["generateContent"]}]}"#)
        ])
        let ids = try await GeminiModelCatalog.fetchModelIDs(apiKey: "fixture-key", httpClient: http)
        XCTAssertEqual(ids, ["a", "b"])
        let calls = await http.state.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        XCTAssertNil(calls[0].value(forHTTPHeaderField: "Authorization"))
        let query = URLComponents(url: calls[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "next+/ &")
        XCTAssertEqual(query.first { $0.name == "pageSize" }?.value, "1000")
    }

    func testGeminiRetainsTwentyPageBoundOnRepeatedPaginationToken() async throws {
        let response = CatalogResponse(status: 200, body: #"{"models":[{"name":"models/a","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"repeat"}"#)
        let http = CatalogHTTPClient(Array(repeating: response, count: 20))
        let ids = try await GeminiModelCatalog.fetchModelIDs(apiKey: "x", httpClient: http)
        let count = await http.state.calls.count
        XCTAssertEqual(ids, ["a"])
        XCTAssertEqual(count, 20)
    }

    func testOllamaUsesInstalledModelsEndpointAndDoesNotInjectCredentials() async throws {
        let http = CatalogHTTPClient([.init(status: 200, body: #"{"models":[{"name":"fixture:latest"}]}"#)])
        let names = try await OllamaModelCatalog.fetchModelNames(base: " http://localhost:11434/v1/ ", httpClient: http)
        XCTAssertEqual(names, ["fixture:latest"])
        let calls = await http.state.calls
        XCTAssertEqual(calls.first?.url?.path, "/api/tags")
        XCTAssertNil(calls.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testFeatherlessSearchUsesHostTitleAndServerSideFilters() async throws {
        let http = CatalogHTTPClient([.init(status: 200, body: #"{"data":[{"id":"fixture/model","context_length":8192,"available_on_current_plan":true}]}"#)])
        let models = try await FeatherlessModelCatalog.search(query: " qwen ", apiKey: "key", availableOnCurrentPlan: true, page: 2, perPage: 25, clientTitle: "AnotherHost", httpClient: http)
        XCTAssertEqual(models.first?.id, "fixture/model")
        XCTAssertEqual(models.first?.context_length, 8192)
        let calls = await http.state.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(call.value(forHTTPHeaderField: "X-Title"), "AnotherHost")
        let query = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "qwen")
        XCTAssertEqual(query.first { $0.name == "available_on_current_plan" }?.value, "true")
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
        XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "25")
    }

    func testStatusFailureRemainsAProviderConfigurationError() async throws {
        let http = CatalogHTTPClient([.init(status: 401, body: "{}")])
        do { _ = try await AnthropicModelCatalog.fetchModelIDs(apiKey: "x", httpClient: http); XCTFail("Expected failure") }
        catch let error as AIProviderError {
            guard case .invalidConfiguration(let detail) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(detail, "Anthropic /v1/models returned HTTP 401")
        }
    }
}

private struct CatalogResponse: Sendable { let status: Int; let body: String }
private actor CatalogHTTPState {
    var calls: [URLRequest] = []
    private var responses: [CatalogResponse]
    init(_ responses: [CatalogResponse]) { self.responses = responses }
    func next(_ request: URLRequest) throws -> CatalogResponse {
        calls.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
private final class CatalogHTTPClient: AIHTTPClient, Sendable {
    let state: CatalogHTTPState
    init(_ responses: [CatalogResponse]) { state = CatalogHTTPState(responses) }
    func data(for request: URLRequest) async throws -> AIHTTPResponse {
        let response = try await state.next(request)
        return .init(data: Data(response.body.utf8), http: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) { throw URLError(.unsupportedURL) }
}
