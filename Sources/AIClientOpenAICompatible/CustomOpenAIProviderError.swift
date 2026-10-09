import Foundation

public enum CustomOpenAIProviderError: Error {
	case invalidToken(statusCode: Int = 401, message: String = "Invalid or missing authentication token")
	case invalidModel(statusCode: Int = 400, message: String = "The specified model is not available or invalid")
	case requestFailed(statusCode: Int, message: String)
	case invalidResponse(statusCode: Int = 500, message: String = "Failed to parse response from server")
	case streamingNotSupported(statusCode: Int = 422, message: String = "Streaming is not supported for this model")
	case rateLimitExceeded(statusCode: Int = 429, message: String = "Rate limit exceeded. Please try again later")
	case serverError(statusCode: Int = 500, message: String = "Internal server error")
	case serviceUnavailable(statusCode: Int = 503, message: String = "Service temporarily unavailable")
	case requestTooLarge(statusCode: Int = 413, message: String = "This model has very strict token limits, and the provided request is too large.")

	public var statusCode: Int {
		switch self {
		case .invalidToken(let code, _): return code
		case .invalidModel(let code, _): return code
		case .requestFailed(let code, _): return code
		case .invalidResponse(let code, _): return code
		case .streamingNotSupported(let code, _): return code
		case .rateLimitExceeded(let code, _): return code
		case .serverError(let code, _): return code
		case .serviceUnavailable(let code, _): return code
		case .requestTooLarge(statusCode: let code, _): return code
		}
	}

	public var errorMessage: String {
		switch self {
		case .invalidToken(_, let message): return message
		case .invalidModel(_, let message): return message
		case .requestFailed(_, let message): return message
		case .invalidResponse(_, let message): return message
		case .streamingNotSupported(_, let message): return message
		case .rateLimitExceeded(_, let message): return message
		case .serverError(_, let message): return message
		case .serviceUnavailable(_, let message): return message
		case .requestTooLarge(_, let message): return message
		}
	}
}
