import Foundation
import AIClientKit
import AIClientHTTP

/// Fetches locally installed Ollama models via `GET {base}/api/tags` — the source of truth for
/// installed models. NOT `/v1/models` (the OpenAI-compat shim) and NOT `/api/ps` (running only).
/// Response shape: `{"models":[{"name":"llama3:latest", ...}]}` — entries carry `name`, not `id`.
public enum OllamaModelCatalog {
	private struct TagsResponse: Decodable {
		struct Entry: Decodable { let name: String }
		let models: [Entry]
	}

	/// Builds the `/api/tags` URL from a user-entered base, tolerating a trailing slash and a
	/// legacy `/v1` suffix (so an existing `http://localhost:11434/v1` config still resolves).
	public static func tagsURL(from base: String) -> URL? {
		var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
		while trimmed.hasSuffix("/") { trimmed.removeLast() }
		if trimmed.hasSuffix("/v1") { trimmed.removeLast(3) }
		while trimmed.hasSuffix("/") { trimmed.removeLast() }
		guard !trimmed.isEmpty else { return nil }
		return URL(string: "\(trimmed)/api/tags")
	}

	/// Pure decode of an `/api/tags` body into model names. Network-free, fully testable.
	public static func decodeModelNames(from data: Data) throws -> [String] {
		try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
	}

	public static func fetchModelNames(
		base: String,
		httpClient: any AIHTTPClient
	) async throws -> [String] {
		guard let url = tagsURL(from: base) else {
			throw AIProviderError.invalidConfiguration(detail: "Invalid Ollama base URL: \(base)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		let response = try await httpClient.data(for: request)
		guard response.http.statusCode == 200 else {
			throw AIProviderError.invalidConfiguration(
				detail: "Ollama /api/tags returned HTTP \(response.http.statusCode)"
			)
		}
		return try decodeModelNames(from: response.data)
	}
}
