import Foundation
import AIClientKit
import AIModelCatalog

/// A resolved model/request snapshot. Hosts resolve preferences before submitting.
public struct OpenAIRequestProfile: Equatable, Sendable {
	public var usesResponsesAPI: Bool
	public var responseModelID: String?
	public var chatMaxTokens: Int?
	public var responsesMaxTokens: Int?
	public var useMaxCompletionTokens: Bool
	public var omitResponseMaxTokens: Bool
	public var chatTemperatureAllowed: Bool
	public var backgroundTemperature: Double?
	public var defaultReasoningEffort: String?
	public var defaultTemperature: Double?
	public init(usesResponsesAPI: Bool = false, responseModelID: String? = nil, chatMaxTokens: Int? = nil,
	            responsesMaxTokens: Int? = nil, useMaxCompletionTokens: Bool = false,
            omitResponseMaxTokens: Bool = false, chatTemperatureAllowed: Bool = true, backgroundTemperature: Double? = nil,
            defaultReasoningEffort: String? = nil, defaultTemperature: Double? = nil) {
		self.usesResponsesAPI = usesResponsesAPI; self.responseModelID = responseModelID
		self.chatMaxTokens = chatMaxTokens; self.responsesMaxTokens = responsesMaxTokens
		self.useMaxCompletionTokens = useMaxCompletionTokens; self.omitResponseMaxTokens = omitResponseMaxTokens
		self.chatTemperatureAllowed = chatTemperatureAllowed; self.backgroundTemperature = backgroundTemperature
		self.defaultReasoningEffort = defaultReasoningEffort; self.defaultTemperature = defaultTemperature
	}
	public static func catalogProfile(for request: AIRequest) -> Self {
		guard let record = AICuratedModelCatalog.record(id: request.model.id, provider: request.model.provider) else {
			return .init(usesResponsesAPI: request.model.capabilities.contains(.responsesAPI))
		}
		return .init(usesResponsesAPI: record.usesResponsesAPI, responseModelID: record.execution.responseModelID,
		             chatMaxTokens: request.options.maxTokens ?? record.execution.geminiMaxTokens ?? record.execution.defaultRequestMaxTokens,
		             responsesMaxTokens: request.options.maxTokens ?? record.execution.defaultRequestMaxTokens, omitResponseMaxTokens: record.execution.omitResponseTokensByDefault,
		             backgroundTemperature: record.defaultTemperature, defaultReasoningEffort: record.execution.reasoningEffort, defaultTemperature: record.defaultTemperature)
	}
}

public struct OpenAIResponseParameters: Encodable, Sendable {
	public struct Reasoning: Codable, Equatable, Sendable { public let effort: String; public let summary: String? }
	public struct Message: Encodable, Sendable {
		public let role: String
		public let content: String
		public let type = "message"
	}
	public let input: [Message]
	public let model: String
	public let instructions: String?
	public let maxOutputTokens: Int?
	public let reasoning: Reasoning?
	public let serviceTier: String?
	public let background: Bool?
	public let stream: Bool
	public let temperature: Double?
	private enum CodingKeys: String, CodingKey {
		case input, model, instructions, reasoning, background, stream, temperature
		case maxOutputTokens = "max_output_tokens", serviceTier = "service_tier"
	}
	public init(request: AIRequest, profile: OpenAIRequestProfile, streaming: Bool, background: Bool = false) {
		input = request.messages.filter { $0.role != .system }.map { .init(role: $0.role.rawValue, content: $0.text) }
		model = profile.responseModelID ?? request.model.id
		instructions = request.messages.first { $0.role == .system && !$0.text.isEmpty }?.text
		maxOutputTokens = profile.omitResponseMaxTokens ? nil : profile.responsesMaxTokens ?? request.options.maxTokens
		reasoning = (request.options.reasoningEffort ?? profile.defaultReasoningEffort).map { .init(effort: $0, summary: streaming ? "auto" : nil) }
		serviceTier = request.options.serviceTier
		self.background = background ? true : nil; stream = streaming
		temperature = background && reasoning == nil ? profile.backgroundTemperature : nil
	}
}

/// Retains unknown fields as original JSON, independent of vendor SDK decoding.
public struct OpenAIResponse: Equatable, Sendable {
	public struct Status: RawRepresentable, Hashable, Codable, Sendable {
		public let rawValue: String
		public init(rawValue: String) { self.rawValue = rawValue }
		public static let queued = Self(rawValue: "queued"), inProgress = Self(rawValue: "in_progress"), completed = Self(rawValue: "completed")
		public static let failed = Self(rawValue: "failed"), incomplete = Self(rawValue: "incomplete"), cancelled = Self(rawValue: "cancelled")
	}
	public struct Failure: Equatable, Sendable { public let code: String?; public let message: String? }
	public struct IncompleteDetails: Equatable, Sendable { public let reason: String? }
	public struct Usage: Equatable, Sendable { public let inputTokens: Int?; public let outputTokens: Int? }
	public let id: String
	public let status: Status?
	public let outputText: String?
	public let reasoningText: String?
	public let error: Failure?
	public let incompleteDetails: IncompleteDetails?
	public let usage: Usage?
	public let rawJSON: Data
	public init(data: Data) throws {
		let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		guard let value, let id = value["id"] as? String, !id.isEmpty else { throw AIProviderError.invalidResponse(detail: "Responses API returned no response identifier.") }
		self.id = id; rawJSON = data
		status = (value["status"] as? String).map { .init(rawValue: $0) }
		let output = value["output"] as? [[String: Any]] ?? []
		let text = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
		let reasoning = output.filter { $0["type"] as? String == "reasoning" }.flatMap { $0["summary"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
		outputText = text.isEmpty ? nil : text; reasoningText = reasoning.isEmpty ? nil : reasoning
		error = (value["error"] as? [String: Any]).map { .init(code: $0["code"] as? String, message: $0["message"] as? String) }
		incompleteDetails = (value["incomplete_details"] as? [String: Any]).map { .init(reason: $0["reason"] as? String) }
		usage = (value["usage"] as? [String: Any]).map { .init(inputTokens: $0["input_tokens"] as? Int, outputTokens: $0["output_tokens"] as? Int) }
	}
}

public struct OpenAIClientError: Error, LocalizedError, Equatable, Sendable {
	public let statusCode: Int?
	public let code: String?
	public let message: String
	public var errorDescription: String? { message }
	public var displayDescription: String { message }
	public init(statusCode: Int? = nil, code: String? = nil, message: String) { self.statusCode = statusCode; self.code = code; self.message = message }
}

public protocol OpenAIResponsesProviding: Sendable {
	func createBackgroundResponse(_ request: AIRequest, profile: OpenAIRequestProfile) async throws -> OpenAIResponse
	func fetchResponse(id: String) async throws -> OpenAIResponse
	func cancelResponse(id: String) async throws -> OpenAIResponse
	func streamResponse(id: String, requestID: UUID) async throws -> AsyncThrowingStream<AIStreamResult, Error>
}
