import Foundation
import Synchronization
import AIClientKit
import AIClientHTTP
import AIClientModelDiscovery
internal import SwiftAnthropic

/// Anthropic-specific configuration; credentials, sessions, and catalog transport are host inputs.
public struct AnthropicClientConfiguration: Equatable, Sendable {
	public var baseURL: String
	public var apiVersion: String
	public var betaHeaders: [String]
	public init(baseURL: String = "https://api.anthropic.com", apiVersion: String = "2023-06-01",
	            betaHeaders: [String] = ["messages-2023-12-15", "prompt-caching-2024-07-31", "output-128k-2025-02-19"]) {
		self.baseURL = baseURL; self.apiVersion = apiVersion; self.betaHeaders = betaHeaders
	}
}

/// SDK-neutral error classification with the existing provider display description.
public struct AnthropicClientError: Error, LocalizedError, Equatable, Sendable {
	public enum Kind: String, Sendable { case requestFailed, responseUnsuccessful, invalidData, decoding, missingData, timeout, stream }
	public let kind: Kind
	public let displayDescription: String
	public var errorDescription: String? { displayDescription }
	public init(kind: Kind, displayDescription: String) { self.kind = kind; self.displayDescription = displayDescription }
	static func neutral(_ error: Error) -> Error {
		guard let error = error as? SwiftAnthropic.APIError else { return error }
		let kind: Kind
		switch error {
		case .requestFailed: kind = .requestFailed
		case .responseUnsuccessful: kind = .responseUnsuccessful
		case .invalidData: kind = .invalidData
		case .jsonDecodingFailure, .bothDecodingStrategiesFailed: kind = .decoding
		case .dataCouldNotBeReadMissingData: kind = .missingData
		case .timeOutError: kind = .timeout
		}
		return Self(kind: kind, displayDescription: error.displayDescription)
	}
}

/// Owns a copied session configuration under a lock. Each operation gets a separate
/// URLSession so terminating one request never invalidates another request's transport.
private final class AnthropicSessions: Sendable {
	private let configuration: Mutex<URLSessionConfiguration>
	init(_ configuration: URLSessionConfiguration) {
		self.configuration = Mutex(configuration.copy() as! URLSessionConfiguration)
	}
	func make() -> URLSession { configuration.withLock { URLSession(configuration: $0) } }
}

/// Text-message API execution extracted from RepoPrompt. SDK values never cross this interface.
public final class AnthropicClient: AIClientProviding, Sendable {
	private let apiKey: String
	private let configuration: AnthropicClientConfiguration
	private let sessions: AnthropicSessions
	private let catalogHTTPClient: any AIHTTPClient
	private let requests = AIRequestRegistry()

	public init(apiKey: String, configuration: AnthropicClientConfiguration = .init(),
	            sessionConfiguration: URLSessionConfiguration, catalogHTTPClient: any AIHTTPClient) {
		self.apiKey = apiKey; self.configuration = configuration
		self.sessions = AnthropicSessions(sessionConfiguration); self.catalogHTTPClient = catalogHTTPClient
	}

	public func models() async throws -> [AIModelDescriptor] {
		guard let endpoint = URL(string: configuration.baseURL + "/v1/models") else { throw AIProviderError.missingURL }
		return try await AnthropicModelCatalog.fetchModelIDs(apiKey: apiKey, endpoint: endpoint, apiVersion: configuration.apiVersion, httpClient: catalogHTTPClient).map {
			.init(id: $0, provider: .anthropic, displayName: $0, capabilities: [.streaming])
		}
	}
	public func cancel(requestID: UUID) async { await requests.cancel(requestID) }

	public func complete(_ request: AIRequest) async throws -> AICompletionResult {
		try Task.checkCancellation()
		try validate(request)
		let generation = try await requests.begin(request.id)
		let session = sessions.make()
		let task = Task { try await self.performCompletion(request, session: session) }
		await requests.register(request.id, generation: generation) { task.cancel(); Self.cancelTransport(session) }
		do {
			let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel(); Self.cancelTransport(session) }
			session.invalidateAndCancel()
			await requests.finish(request.id, generation: generation)
			return value
		} catch {
			session.invalidateAndCancel()
			await requests.finish(request.id, generation: generation)
			if task.isCancelled { throw CancellationError() }
			throw AnthropicClientError.neutral(error)
		}
	}

	public func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		try Task.checkCancellation()
		try validate(request)
		let generation = try await requests.begin(request.id)
		let session = sessions.make()
		let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
		let registry = requests
		let task = Task {
			do {
				try Task.checkCancellation()
				if !request.model.capabilities.contains(.streaming) {
					let result = try await self.performCompletion(request, session: session)
					try Task.checkCancellation()
					continuation.yield(.init(type: "content", text: result.text))
					continuation.yield(.init(type: "message_stop", text: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
				} else {
					// Service and non-Sendable SDK elements are created and consumed inside
					// this single task; no unsafe handoff box or shared SDK instance is needed.
					let service = self.service(session)
					let upstream = try await service.streamMessage(Self.parameters(request, streaming: true))
					var projection = AnthropicStreamProjection()
					for try await value in upstream {
						try Task.checkCancellation()
						if let error = value.error { throw AnthropicClientError(kind: .stream, displayDescription: error.message) }
						if let event = projection.receive(value) { continuation.yield(event) }
						if projection.stopped { break }
					}
					try Task.checkCancellation()
					if let final = projection.finish() { continuation.yield(final) }
				}
				continuation.finish()
			} catch {
				if Task.isCancelled { continuation.finish() }
				else { continuation.finish(throwing: AnthropicClientError.neutral(error)) }
			}
			session.invalidateAndCancel()
			await registry.finish(request.id, generation: generation)
		}
		await registry.register(request.id, generation: generation) { task.cancel(); Self.cancelTransport(session); continuation.finish() }
		continuation.onTermination = { _ in
			task.cancel(); Self.cancelTransport(session)
			Task { await registry.finish(request.id, generation: generation) }
		}
		return stream
	}

	private static func cancelTransport(_ session: URLSession) {
		// Keep the session valid until the SDK operation exits. Invalidating here
		// races SDK task creation and Foundation raises NSGenericException.
		// The parent task cancels async data/bytes establishment; this callback also
		// reaches the SDK's independent stream reader after establishment.
		session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
	}

	private func validate(_ request: AIRequest) throws {
		guard request.attachments.isEmpty, !request.messages.contains(where: { $0.role == .tool }) else {
			throw AIProviderError.invalidConfiguration(detail: "This Anthropic client supports text conversations only.")
		}
		let system = request.messages.filter { $0.role == .system }
		guard system.count == 1, !system[0].text.isEmpty else { throw AIProviderError.invalidSystemPrompt }
	}

	private func service(_ session: URLSession) -> sending any AnthropicService {
		AnthropicServiceFactory.service(apiKey: apiKey, apiVersion: configuration.apiVersion, basePath: configuration.baseURL,
		                               betaHeaders: configuration.betaHeaders, httpClient: SwiftAnthropic.URLSessionHTTPClientAdapter(urlSession: session))
	}

	private func performCompletion(_ request: AIRequest, session: URLSession) async throws -> AICompletionResult {
		try Task.checkCancellation()
		let response = try await service(session).createMessage(Self.parameters(request, streaming: false))
		try Task.checkCancellation()
		let text = response.content.compactMap { item -> String? in
			switch item {
			case .text(let text, _): return text
			case .thinking(let thinking): return thinking.thinking
			case .toolUse, .serverToolUse, .webSearchToolResult, .codeExecutionToolResult, .toolResult: return nil
			}
		}.joined()
		return .init(text: text, promptTokens: response.usage.inputTokens,
		             completionTokens: response.usage.outputTokens + (response.usage.thinkingTokens ?? 0))
	}

	/// The legacy streaming path deliberately uses fixed thinking/output budgets;
	/// completion honors an explicit cap. Completion also omits temperature entirely.
	private static func parameters(_ request: AIRequest, streaming: Bool) -> MessageParameter {
		let name = request.model.id
		let maxThinking = name.hasSuffix("-thinking-max")
		let thinking = maxThinking || name.hasSuffix("-thinking")
		let base = maxThinking ? String(name.dropLast(13)) : thinking ? String(name.dropLast(9)) : name
		let budget = maxThinking ? 32_000 : thinking ? 16_000 : 0
		let thinkingOutput = maxThinking ? 64_000 : name.contains("opus") ? 32_000 : 64_000
		let maxTokens = streaming ? (thinking ? thinkingOutput : 8_192) : request.options.maxTokens ?? (thinking ? thinkingOutput : 4_096)
		return MessageParameter(
			model: .other(base),
			messages: request.messages.filter { $0.role != .system }.map { .init(role: $0.role == .user ? .user : .assistant, content: .text($0.text)) },
			maxTokens: maxTokens,
			system: .list([.init(type: .text, text: request.messages.first { $0.role == .system }!.text, cacheControl: .init(type: .ephemeral))]),
			stream: streaming,
			temperature: streaming && !thinking ? request.options.temperature ?? 0 : nil,
			thinking: thinking ? .init(budgetTokens: budget) : nil)
	}
}

/// Retains legacy thinking projection while reconciling native start/delta usage.
/// Exactly one stop is emitted, either for the provider stop or clean EOF.
private struct AnthropicStreamProjection {
	var stopped = false
	private var currentThinking = ""
	private var promptTokens: Int?
	private var completionTokens: Int?
	mutating func receive(_ value: MessageStreamResponse) -> AIStreamResult? {
		guard !stopped else { return nil }
		if let usage = value.message?.usage ?? value.usage {
			if let input = usage.inputTokens { promptTokens = input }
			completionTokens = usage.outputTokens + (usage.thinkingTokens ?? 0)
		}
		var reasoning: String?
		switch value.streamEvent {
		case .contentBlockStart:
			if value.contentBlock?.type == "thinking", let text = value.contentBlock?.thinking { currentThinking = text; reasoning = text }
		case .contentBlockDelta:
			if value.delta?.type == "thinking_delta" { reasoning = value.delta?.thinking }
		case .contentBlockStop:
			if !currentThinking.isEmpty { reasoning = currentThinking; currentThinking = "" }
		case .messageStop: stopped = true
		default: break
		}
		return .init(type: value.type, text: value.contentBlock?.text ?? value.delta?.text, reasoning: reasoning,
		             promptTokens: stopped ? promptTokens : nil, completionTokens: stopped ? completionTokens : nil)
	}
	mutating func finish() -> AIStreamResult? {
		guard !stopped else { return nil }; stopped = true
		return .init(type: "message_stop", text: nil, promptTokens: promptTokens, completionTokens: completionTokens)
	}
}
