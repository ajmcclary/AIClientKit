import Foundation
import AIClientKit

/// Catalog identity, wire metadata, and defaults never consult host preferences.
public struct AIModelExecutionMetadata: Codable, Equatable, Sendable {
	public let responseModelID: String
	public let reasoningEffort: String?
	public let defaultRequestMaxTokens: Int
	public let geminiMaxTokens: Int?
	public let omitResponseTokensByDefault: Bool
	public init(responseModelID: String, reasoningEffort: String? = nil, defaultRequestMaxTokens: Int = 2048, geminiMaxTokens: Int? = nil, omitResponseTokensByDefault: Bool = false) {
		self.responseModelID = responseModelID; self.reasoningEffort = reasoningEffort; self.defaultRequestMaxTokens = defaultRequestMaxTokens
		self.geminiMaxTokens = geminiMaxTokens; self.omitResponseTokensByDefault = omitResponseTokensByDefault
	}
}

public struct AIModelCatalogRecord: Codable, Equatable, Sendable, Identifiable {
	public let id: String
	public let provider: AIProviderType
	public let modelName: String
	public let displayName: String
	public let streaming: Bool
	public let usesResponsesAPI: Bool
	public let defaultReasoningEffort: String?
	public let defaultTemperature: Double?
	public let availableFrom: Date?
	public let execution: AIModelExecutionMetadata
	public init(id: String, provider: AIProviderType, modelName: String, displayName: String,
	            streaming: Bool = true, usesResponsesAPI: Bool = false, defaultReasoningEffort: String? = nil,
	            defaultTemperature: Double? = nil, availableFrom: Date? = nil, execution: AIModelExecutionMetadata? = nil) {
		self.id = id; self.provider = provider; self.modelName = modelName; self.displayName = displayName
		self.streaming = streaming; self.usesResponsesAPI = usesResponsesAPI; self.defaultReasoningEffort = defaultReasoningEffort
		self.defaultTemperature = defaultTemperature; self.availableFrom = availableFrom; self.execution = execution ?? .init(responseModelID: modelName)
	}
	public var descriptor: AIModelDescriptor {
		var capabilities: Set<AIModelCapability> = []
		if streaming { capabilities.insert(.streaming) }
		if usesResponsesAPI { capabilities.insert(.responsesAPI) }
		if !streaming && usesResponsesAPI { capabilities.insert(.backgroundResponses) }
		if defaultReasoningEffort != nil || execution.reasoningEffort != nil { capabilities.insert(.reasoning) }
		return .init(id: id, provider: provider, displayName: displayName, capabilities: capabilities)
	}
	public func isAvailable(at date: Date) -> Bool { availableFrom.map { date >= $0 } ?? true }
}
public enum AICuratedModelCatalog {
	public static let anthropicFallbackAliasIDs = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
	public static func record(id: String, provider: AIProviderType) -> AIModelCatalogRecord? {
		let id = canonicalAlias(id, provider: provider)
		return records.first { $0.id == id && $0.provider == provider }
	}
	public static func canonicalAlias(_ id: String, provider: AIProviderType) -> String {
		switch (provider, id.lowercased()) {
		case (.deepseek, "deepseek-chat"): return "deepseek-v4-flash"
		case (.gemini, "gemini-3-pro-preview"): return "gemini-3.1-pro-preview"
		default: return id
		}
	}
	/// Provider-scoped enrichment retains fetched order and reconciles legacy aliases.
	/// Discovery bypasses curated release gates; the server is authoritative for fetched IDs.
	public static func reconcile(_ ids: [String], provider: AIProviderType) -> [AIModelDescriptor] {
		var seen = Set<String>(); var result: [AIModelDescriptor] = []
		for id in ids {
			let descriptor = record(id: id, provider: provider)?.descriptor ?? .init(id: id, provider: provider, displayName: id, capabilities: [.streaming])
			if seen.insert(descriptor.id).inserted { result.append(descriptor) }
		}
		return result
	}
	public static func fallback(provider: AIProviderType, at date: Date) -> [AIModelDescriptor] {
		var result = records.filter { $0.provider == provider && $0.isAvailable(at: date) }.map(\.descriptor)
		if provider == .anthropic {
			for id in anthropicFallbackAliasIDs {
				let value = record(id: id, provider: provider)?.descriptor ?? .init(id: id, provider: provider, displayName: id, capabilities: [.streaming])
				if !result.contains(where: { $0.id == value.id }) { result.append(value) }
			}
		}
		return result
	}

	public static let records: [AIModelCatalogRecord] = [
		.init(id: "gpt-5.2", provider: .openAI, modelName: "gpt-5.2", displayName: "GPT-5.2 Med", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "medium", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2", reasoningEffort: "medium", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.2-low", provider: .openAI, modelName: "gpt-5.2-low", displayName: "GPT-5.2 Low", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "low", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2", reasoningEffort: "low", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.2-high", provider: .openAI, modelName: "gpt-5.2-high", displayName: "GPT-5.2 High", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "high", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2", reasoningEffort: "high", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.2-xhigh", provider: .openAI, modelName: "gpt-5.2-xhigh", displayName: "GPT-5.2 XHigh", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "xhigh", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2", reasoningEffort: "xhigh", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5", provider: .openAI, modelName: "gpt-5.5", displayName: "GPT-5.5 Med", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "medium", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5", reasoningEffort: "medium", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5-low", provider: .openAI, modelName: "gpt-5.5", displayName: "GPT-5.5 Low", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "low", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5", reasoningEffort: "low", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5-high", provider: .openAI, modelName: "gpt-5.5", displayName: "GPT-5.5 High", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "high", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5", reasoningEffort: "high", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5-xhigh", provider: .openAI, modelName: "gpt-5.5", displayName: "GPT-5.5 XHigh", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "xhigh", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5", reasoningEffort: "xhigh", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.4-mini", provider: .openAI, modelName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.4-mini", reasoningEffort: "medium", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.4-mini-low", provider: .openAI, modelName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini Low", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.4-mini", reasoningEffort: "low", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.4-mini-high", provider: .openAI, modelName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini High", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.4-mini", reasoningEffort: "high", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.4-mini-xhigh", provider: .openAI, modelName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini XHigh", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.4-mini", reasoningEffort: "xhigh", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.4-nano", provider: .openAI, modelName: "gpt-5.4-nano", displayName: "GPT-5.4 Nano", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.4-nano", reasoningEffort: nil, defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.1-codex-max-low", provider: .openAI, modelName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max Low", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "low", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.1-codex-max", reasoningEffort: "low", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.1-codex-max", provider: .openAI, modelName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max Med", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "medium", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.1-codex-max", reasoningEffort: "medium", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.1-codex-max-high", provider: .openAI, modelName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max High", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "high", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.1-codex-max", reasoningEffort: "high", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.1-codex-max-xhigh", provider: .openAI, modelName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max XHigh", streaming: true, usesResponsesAPI: true, defaultReasoningEffort: "xhigh", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.1-codex-max", reasoningEffort: "xhigh", defaultRequestMaxTokens: 128000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.2-pro", provider: .openAI, modelName: "gpt-5.2-pro", displayName: "GPT-5.2 Pro", streaming: false, usesResponsesAPI: true, defaultReasoningEffort: "high", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2-pro", reasoningEffort: "high", defaultRequestMaxTokens: 100000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.2-pro-xhigh", provider: .openAI, modelName: "gpt-5.2-pro", displayName: "GPT-5.2 Pro XHigh", streaming: false, usesResponsesAPI: true, defaultReasoningEffort: "xhigh", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.2-pro", reasoningEffort: "xhigh", defaultRequestMaxTokens: 100000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5-pro", provider: .openAI, modelName: "gpt-5.5-pro", displayName: "GPT-5.5 Pro", streaming: false, usesResponsesAPI: true, defaultReasoningEffort: "high", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5-pro", reasoningEffort: "high", defaultRequestMaxTokens: 100000, omitResponseTokensByDefault: true)),
		.init(id: "gpt-5.5-pro-xhigh", provider: .openAI, modelName: "gpt-5.5-pro", displayName: "GPT-5.5 Pro XHigh", streaming: false, usesResponsesAPI: true, defaultReasoningEffort: "xhigh", defaultTemperature: nil, execution: .init(responseModelID: "gpt-5.5-pro", reasoningEffort: "xhigh", defaultRequestMaxTokens: 100000, omitResponseTokensByDefault: true)),
		.init(id: "claude-haiku-4-5", provider: .anthropic, modelName: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-haiku-4-5")),
		.init(id: "claude-sonnet-4-5-20250929", provider: .anthropic, modelName: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-sonnet-4-5-20250929")),
		.init(id: "claude-sonnet-4-5-20250929-thinking", provider: .anthropic, modelName: "claude-sonnet-4-5-20250929-thinking", displayName: "Claude Sonnet 4.5 Thinking", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-sonnet-4-5-20250929-thinking")),
		.init(id: "claude-sonnet-4-5-20250929-thinking-max", provider: .anthropic, modelName: "claude-sonnet-4-5-20250929-thinking-max", displayName: "Claude Sonnet 4.5 Thinking Max", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-sonnet-4-5-20250929-thinking-max")),
		.init(id: "claude-opus-4-6", provider: .anthropic, modelName: "claude-opus-4-6", displayName: "Claude Opus 4.6", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-opus-4-6")),
		.init(id: "claude-opus-4-6-thinking", provider: .anthropic, modelName: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 Thinking", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "claude-opus-4-6-thinking")),
		.init(id: "gemini-3.5-flash", provider: .gemini, modelName: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gemini-3.5-flash", geminiMaxTokens: 8192)),
		.init(id: "gemini-2.5-flash", provider: .gemini, modelName: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gemini-2.5-flash", geminiMaxTokens: 65536)),
		.init(id: "gemini-2.5-flash-lite-preview-06-17", provider: .gemini, modelName: "gemini-2.5-flash-lite-preview-06-17", displayName: "Gemini 2.5 Flash Lite Preview 06-17", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gemini-2.5-flash-lite-preview-06-17", geminiMaxTokens: 8192)),
		.init(id: "gemini-2.5-pro", provider: .gemini, modelName: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: 0.7, execution: .init(responseModelID: "gemini-2.5-pro", geminiMaxTokens: 65536)),
		.init(id: "gemini-3.1-pro-preview", provider: .gemini, modelName: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro Preview", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gemini-3.1-pro-preview", geminiMaxTokens: 65536)),
		.init(id: "gemini-3-flash-preview", provider: .gemini, modelName: "gemini-3-flash-preview", displayName: "Gemini 3.0 Flash Preview", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "gemini-3-flash-preview", geminiMaxTokens: 65536)),
		.init(id: "deepseek-v4-flash", provider: .deepseek, modelName: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "deepseek-v4-flash")),
		.init(id: "deepseek-reasoner", provider: .deepseek, modelName: "deepseek-reasoner", displayName: "DeepSeek V4 Flash Thinking", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: 0.6, execution: .init(responseModelID: "deepseek-reasoner")),
		.init(id: "deepseek-v4-pro", provider: .deepseek, modelName: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "deepseek-v4-pro")),
		.init(id: "glm-5.2", provider: .zAI, modelName: "glm-5.2", displayName: "Z.AI GLM-5.2", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-5.2")),
		.init(id: "glm-5.2[1m]", provider: .zAI, modelName: "glm-5.2[1m]", displayName: "Z.AI GLM-5.2 (1M)", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-5.2[1m]")),
		.init(id: "glm-5.1", provider: .zAI, modelName: "glm-5.1", displayName: "Z.AI GLM-5.1", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-5.1")),
		.init(id: "glm-5", provider: .zAI, modelName: "glm-5", displayName: "Z.AI GLM-5", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-5")),
		.init(id: "glm-5-turbo", provider: .zAI, modelName: "glm-5-turbo", displayName: "Z.AI GLM-5-Turbo", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-5-turbo")),
		.init(id: "glm-4.7", provider: .zAI, modelName: "glm-4.7", displayName: "Z.AI GLM-4.7", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.7")),
		.init(id: "glm-4.7-flash", provider: .zAI, modelName: "glm-4.7-flash", displayName: "Z.AI GLM-4.7 Flash", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.7-flash")),
		.init(id: "glm-4.6", provider: .zAI, modelName: "glm-4.6", displayName: "Z.AI GLM-4.6", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.6")),
		.init(id: "glm-4.5", provider: .zAI, modelName: "glm-4.5", displayName: "Z.AI GLM-4.5", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.5")),
		.init(id: "glm-4.5-air", provider: .zAI, modelName: "glm-4.5-air", displayName: "Z.AI GLM-4.5 Air", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.5-air")),
		.init(id: "glm-4.5-flash", provider: .zAI, modelName: "glm-4.5-flash", displayName: "Z.AI GLM-4.5 Flash", streaming: true, usesResponsesAPI: false, defaultReasoningEffort: nil, defaultTemperature: nil, execution: .init(responseModelID: "glm-4.5-flash"))
	]
}
