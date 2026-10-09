import Foundation
import AIClientKit
import AIClientHTTP

/// Server-side-searchable model listing for Featherless `/v1/models`. Unlike a generic
/// OpenAI-compatible `/models` dump (~42k for Featherless), this passes `q`/`page`/`per_page`/
/// `available_on_current_plan` so we never download the whole catalog.
public enum FeatherlessModelCatalog {
    public static let base = URL(string: "https://api.featherless.ai")!

    public struct Model: Decodable, Equatable, Sendable {
        public let id: String
        public let model_class: String?
        public let context_length: Int?
        public let max_completion_tokens: Int?
        public let is_gated: Bool?
        public let available_on_current_plan: Bool?

        public init(id: String, model_class: String?, context_length: Int?, max_completion_tokens: Int?, is_gated: Bool?, available_on_current_plan: Bool?) {
            self.id = id
            self.model_class = model_class
            self.context_length = context_length
            self.max_completion_tokens = max_completion_tokens
            self.is_gated = is_gated
            self.available_on_current_plan = available_on_current_plan
        }
    }
    private struct Response: Decodable { let data: [Model] }

    /// Pure: builds the request URL. Omits `q` when blank.
    public static func modelsURL(query: String, availableOnCurrentPlan: Bool, page: Int, perPage: Int) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "available_on_current_plan", value: availableOnCurrentPlan ? "true" : "false"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.insert(URLQueryItem(name: "q", value: q), at: 0) }
        comps.queryItems = items
        return comps.url!
    }

    /// Pure: decodes a `/v1/models` body. Network-free, testable.
    public static func decode(_ data: Data) throws -> [Model] {
        try JSONDecoder().decode(Response.self, from: data).data
    }

    public static func search(
        query: String,
        apiKey: String,
        availableOnCurrentPlan: Bool,
        page: Int = 1,
        perPage: Int,
        clientTitle: String?,
        httpClient: any AIHTTPClient
    ) async throws -> [Model] {
        var request = URLRequest(url: modelsURL(query: query, availableOnCurrentPlan: availableOnCurrentPlan, page: page, perPage: perPage))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let clientTitle { request.setValue(clientTitle, forHTTPHeaderField: "X-Title") }
        let response = try await httpClient.data(for: request)
        guard response.http.statusCode == 200 else {
            throw AIProviderError.invalidConfiguration(detail: "Featherless /v1/models returned HTTP \(response.http.statusCode)")
        }
        return try decode(response.data)
    }
}
