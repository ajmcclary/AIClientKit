import Foundation
import AIClientKit
import AIClientHTTP

/// Fetches Anthropic's live model catalog via `GET /v1/models`.
/// Anthropic authenticates with `x-api-key` + `anthropic-version` headers (NOT Bearer), so this
/// cannot reuse `CustomOpenAIProvider`. Response shape: `{"data":[{"id":"...","type":"model"}]}`.
public enum AnthropicModelCatalog {
	public static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!
	public static let anthropicVersion = "2023-06-01"

	private struct ModelsResponse: Decodable {
		struct Entry: Decodable { let id: String }
		let data: [Entry]
	}

	/// Pure decode of a `/v1/models` body into model IDs. Network-free, fully testable.
	public static func decodeModelIDs(from data: Data) throws -> [String] {
		try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
	}

	public static func fetchModelIDs(
		apiKey: String,
		httpClient: any AIHTTPClient
	) async throws -> [String] {
		var request = URLRequest(url: modelsURL)
		request.httpMethod = "GET"
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
		let response = try await httpClient.data(for: request)
		guard response.http.statusCode == 200 else {
			throw AIProviderError.invalidConfiguration(
				detail: "Anthropic /v1/models returned HTTP \(response.http.statusCode)"
			)
		}
		return try decodeModelIDs(from: response.data)
	}
}
