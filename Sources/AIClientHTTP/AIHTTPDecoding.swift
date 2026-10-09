import Foundation

public enum AIHTTPDecoding {
	/// `T: Sendable` is required because the decoded value (and `T.Type` itself)
	/// crosses out of the detached task's isolation region. Both current call
	/// sites decode plain value-type response models, so the constraint costs
	/// nothing and the decoding still happens off the caller's executor.
	public static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
		try await Task.detached(priority: .utility) {
			let decoder = JSONDecoder()
			return try decoder.decode(T.self, from: data)
		}.value
	}
}
