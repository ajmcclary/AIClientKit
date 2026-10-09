import Foundation

public struct AIHTTPResponse: Sendable {
	public let data: Data
	public let http: HTTPURLResponse

	public init(data: Data, http: HTTPURLResponse) { self.data = data; self.http = http }
}

public protocol AIHTTPClient: Sendable {
	func data(for request: URLRequest) async throws -> AIHTTPResponse
	func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse)
}

public final class URLSessionAIHTTPClient: AIHTTPClient, Sendable {

	private let session: URLSession

	public init(configuration: URLSessionConfiguration) {
		session = URLSession(configuration: configuration)
	}

	public func data(for request: URLRequest) async throws -> AIHTTPResponse {
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}
		return AIHTTPResponse(data: data, http: http)
	}

	public func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
		let (bytes, response) = try await session.bytes(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}
		return (bytes: bytes, http: http)
	}

	public static func makeConfiguration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
		let config = URLSessionConfiguration.default
		config.timeoutIntervalForRequest = requestTimeout
		config.timeoutIntervalForResource = resourceTimeout
		config.waitsForConnectivity = false
		return config
	}
}
