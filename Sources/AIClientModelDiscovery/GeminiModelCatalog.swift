import Foundation
import AIClientKit
import AIClientHTTP

/// Fetches Gemini's live model catalog via `GET /v1beta/models`.
/// Gemini authenticates with an `x-goog-api-key` header (NOT Bearer), and the list endpoint
/// paginates via `nextPageToken`, so this cannot reuse `CustomOpenAIProvider`.
/// Response shape: `{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent",...]}],"nextPageToken":"..."}`.
/// Only models that support `generateContent` are kept (filters out embedding/vision-only/legacy entries),
/// and the `models/` prefix is stripped from `name` to yield the bare model id.
public enum GeminiModelCatalog {
	public static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
	private static let pageSize = 1000
	/// Hard cap on pages followed, so a misbehaving `nextPageToken` can't loop forever.
	private static let maxPages = 20

	private struct ModelsResponse: Decodable {
		struct Entry: Decodable {
			let name: String
			let supportedGenerationMethods: [String]?
		}
		let models: [Entry]?
		let nextPageToken: String?
	}

	/// Pure decode of one `/v1beta/models` page. Network-free, fully testable.
	/// Returns the chat-capable model ids on the page plus the page's `nextPageToken` (if any).
	public static func decodePage(from data: Data) throws -> (ids: [String], nextPageToken: String?) {
		let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
		let ids = (response.models ?? []).compactMap { entry -> String? in
			guard entry.supportedGenerationMethods?.contains("generateContent") == true else { return nil }
			return entry.name.hasPrefix("models/") ? String(entry.name.dropFirst("models/".count)) : entry.name
		}
		return (ids, response.nextPageToken)
	}

	public static func fetchModelIDs(
		apiKey: String,
		httpClient: any AIHTTPClient
	) async throws -> [String] {
		var ids: [String] = []
		var seen = Set<String>()
		var pageToken: String?

		for _ in 0..<maxPages {
			var components = URLComponents(string: baseURL)!
			var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
			if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
			components.queryItems = query
			guard let url = components.url else {
				throw AIProviderError.invalidConfiguration(detail: "Could not build Gemini /v1beta/models URL")
			}

			var request = URLRequest(url: url)
			request.httpMethod = "GET"
			request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
			let response = try await httpClient.data(for: request)
			guard response.http.statusCode == 200 else {
				throw AIProviderError.invalidConfiguration(
					detail: "Gemini /v1beta/models returned HTTP \(response.http.statusCode)"
				)
			}

			let (pageIDs, next) = try decodePage(from: response.data)
			for id in pageIDs where seen.insert(id).inserted { ids.append(id) }

			guard let next, !next.isEmpty else { break }
			pageToken = next
		}

		return ids
	}
}
