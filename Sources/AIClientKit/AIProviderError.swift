import Foundation

public enum AIProviderError: Error {
	case missingOllamaURL
	case missingAPIKey
	case missingURL
	case providerNotConfigured
	case invalidModel
	case invalidSystemPrompt
	case messageCreationFailed
	case invalidResponse(detail: String) // Add associated value 'detail'
	case invalidConfiguration(detail: String) // Added for configuration issues
	case apiError(source: Error?) // Added for underlying API errors
	case unknown(source: Error?) // Added for other unexpected errors
}

extension AIProviderError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .missingOllamaURL:
			return "Missing Ollama URL."
		case .missingAPIKey:
			return "Missing API key."
		case .missingURL:
			return "Missing provider URL."
		case .providerNotConfigured:
			return "Provider is not configured."
		case .invalidModel:
			return "Invalid model."
		case .invalidSystemPrompt:
			return "Invalid system prompt."
		case .messageCreationFailed:
			return "Failed to create provider message."
		case .invalidResponse(let detail), .invalidConfiguration(let detail):
			return detail
		case .apiError(let source), .unknown(let source):
			return source?.localizedDescription ?? String(describing: self)
		}
	}
}
