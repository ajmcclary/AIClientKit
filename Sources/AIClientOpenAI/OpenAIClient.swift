import Foundation
import AIClientKit
import AIClientHTTP

public struct OpenAIClientConfiguration: Sendable {
	public var baseURL: URL?
	public var apiVersion: String?
	public var includeUsageInStream: Bool
	public var provider: AIProviderType
	public init(baseURL: URL? = nil, apiVersion: String? = nil, includeUsageInStream: Bool = true, provider: AIProviderType = .openAI) {
		self.baseURL = baseURL; self.apiVersion = apiVersion; self.includeUsageInStream = includeUsageInStream; self.provider = provider
	}
	public static let deepSeek = Self(baseURL: URL(string: "https://api.deepseek.com")!, apiVersion: "v1", provider: .deepseek)
	public static let gemini = Self(baseURL: URL(string: "https://generativelanguage.googleapis.com")!, apiVersion: "v1beta", provider: .gemini)
	public static let featherless = Self(baseURL: URL(string: "https://api.featherless.ai")!, apiVersion: "v1", includeUsageInStream: false, provider: .featherless)
	public static func ollama(baseURL: URL) -> Self { .init(baseURL: baseURL, provider: .ollama) }
	public static func zAI(codingPlan: Bool) -> Self { .init(baseURL: URL(string: codingPlan ? "https://api.z.ai/api/coding/paas" : "https://api.z.ai/api/paas")!, apiVersion: "v4", provider: .zAI) }
}

/// Poll ownership is local to a run. Cancellation before creation is remembered
/// until an ID arrives; only one server-cancel call can claim that ID.
private actor BackgroundOwnership {
	private var id: String?
	private var cancelled = false
	private var sent = false
	private var terminal = false
	init(id: String? = nil) { self.id = id }
	func adopt(_ id: String) -> String? { self.id = id; return claim() }
	func cancel() -> String? { cancelled = true; return claim() }
	func finish() { terminal = true }
	private func claim() -> String? {
		guard cancelled, !sent, !terminal, let id else { return nil }
		sent = true; return id
	}
}

/// OpenAI chat/Responses wire execution, preserving the characterized SDK path.
/// All transports, credentials, model policy, and polling timing are injectable.
public final class OpenAIClient: AIClientProviding, OpenAIResponsesProviding, Sendable {
	private let apiKey: String
	private let configuration: OpenAIClientConfiguration
	private let http: any AIHTTPClient
	private let streamingHTTP: any AIHTTPClient
	private let sleep: @Sendable (Duration) async throws -> Void
	private let profileResolver: @Sendable (AIRequest) -> OpenAIRequestProfile
	private let requests = AIRequestRegistry()
	public init(apiKey: String, configuration: OpenAIClientConfiguration = .init(), httpClient: any AIHTTPClient,
	            streamingHTTPClient: any AIHTTPClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
	            profileResolver: @escaping @Sendable (AIRequest) -> OpenAIRequestProfile = { .init(usesResponsesAPI: $0.model.capabilities.contains(.responsesAPI)) }) {
		self.apiKey = apiKey; self.configuration = configuration; http = httpClient; streamingHTTP = streamingHTTPClient; self.sleep = sleep; self.profileResolver = profileResolver
	}
	public func cancel(requestID: UUID) async { await requests.cancel(requestID) }
	public func models() async throws -> [AIModelDescriptor] {
		let value = try await http.data(for: request(path: "models", method: "GET")); try check(value)
		let body = try JSONSerialization.jsonObject(with: value.data) as? [String: Any]
		return (body?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.map { .init(id: $0, provider: configuration.provider, displayName: $0, capabilities: [.streaming]) }
	}
	public func complete(_ input: AIRequest) async throws -> AICompletionResult { try await complete(input, profile: profileResolver(input)) }
	public func complete(_ input: AIRequest, profile: OpenAIRequestProfile) async throws -> AICompletionResult {
		try validate(input)
		return try await operation(input.id) { try await self.performCompletion(input, profile: profile) }
	}
	private func operation<Value: Sendable>(_ id: UUID, onCancelledResult: (@Sendable (Value) async -> Void)? = nil, body: @escaping @Sendable () async throws -> Value) async throws -> Value {
		try Task.checkCancellation(); let generation = try await requests.begin(id)
		let task = Task { try await body() }
		await requests.register(id, generation: generation) { task.cancel() }
		do {
			let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
			await requests.finish(id, generation: generation)
			if task.isCancelled || Task.isCancelled {
				await onCancelledResult?(value); throw CancellationError()
			}
			return value
		} catch {
			await requests.finish(id, generation: generation)
			if task.isCancelled { throw CancellationError() }; throw error
		}
	}
	public func stream(_ input: AIRequest) async throws -> AsyncThrowingStream<AIStreamResult, Error> { try await stream(input, profile: profileResolver(input)) }
	public func stream(_ input: AIRequest, profile: OpenAIRequestProfile) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		try validate(input)
		let ownership = BackgroundOwnership()
		return try await managedStream(input.id, ownership: ownership) { continuation in
			if profile.usesResponsesAPI && !input.model.capabilities.contains(.streaming) {
				let response = try await self.postResponse(input, profile: profile, background: true)
				if let id = await ownership.adopt(response.id) { await self.cancelRemote(id) }
				try Task.checkCancellation()
				try await self.poll(response.id, continuation: continuation, ownership: ownership)
			} else if !input.model.capabilities.contains(.streaming) {
				let result = try await self.performCompletion(input, profile: profile); try Task.checkCancellation()
				continuation.yield(.init(type: "content", text: result.text, completionTokens: result.completionTokens))
				continuation.yield(.init(type: "message_stop", text: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
			} else {
				try await self.pump(input, profile: profile, continuation: continuation)
			}
		}
	}
	private func managedStream(_ id: UUID, ownership: BackgroundOwnership,
	                          body: @escaping @Sendable (AsyncThrowingStream<AIStreamResult, Error>.Continuation) async throws -> Void) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		try Task.checkCancellation(); let generation = try await requests.begin(id)
		let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
		let registry = requests
		let task = Task {
			do { try await body(continuation); try Task.checkCancellation(); continuation.finish() }
			catch {
				if Task.isCancelled {
					if let remoteID = await ownership.cancel() { await self.cancelRemote(remoteID) }
					continuation.finish()
				} else { continuation.finish(throwing: error) }
			}
			await registry.finish(id, generation: generation)
		}
		let cancel: @Sendable () -> Void = {
			task.cancel(); continuation.finish()
			Task { if let remoteID = await ownership.cancel() { await self.cancelRemote(remoteID) } }
		}
		await registry.register(id, generation: generation, cancel: cancel)
		continuation.onTermination = { termination in
			if case .cancelled = termination { cancel() } else { task.cancel() }
			Task { await registry.finish(id, generation: generation) }
		}
		return stream
	}
	public func createBackgroundResponse(_ input: AIRequest, profile: OpenAIRequestProfile) async throws -> OpenAIResponse {
		try validate(input)
		return try await operation(input.id, onCancelledResult: { value in
			if ![.completed, .failed, .incomplete, .cancelled].contains(value.status) { await self.cancelRemote(value.id) }
		}) {
			try await self.postResponse(input, profile: profile, background: true)
		}
	}
	private func postResponse(_ input: AIRequest, profile: OpenAIRequestProfile, background: Bool) async throws -> OpenAIResponse {
		let body = try JSONEncoder().encode(OpenAIResponseParameters(request: input, profile: profile, streaming: false, background: background))
		let value = try await http.data(for: request(path: "responses", body: body)); try check(value)
		let response = try OpenAIResponse(data: value.data)
		if background && response.status == .failed { throw AIProviderError.invalidResponse(detail: response.error?.message ?? response.incompleteDetails?.reason ?? "Responses API returned a failed status.") }
		return response
	}
	public func fetchResponse(id: String) async throws -> OpenAIResponse {
		let value = try await http.data(for: request(path: "responses/" + escapedID(id), method: "GET")); try check(value); return try .init(data: value.data)
	}
	public func cancelResponse(id: String) async throws -> OpenAIResponse {
		let value = try await http.data(for: request(path: "responses/" + escapedID(id) + "/cancel")); try check(value); return try .init(data: value.data)
	}
	public func streamResponse(id: String, requestID: UUID = UUID()) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		let ownership = BackgroundOwnership(id: id)
		return try await managedStream(requestID, ownership: ownership) { continuation in try await self.poll(id, continuation: continuation, ownership: ownership) }
	}
	private func poll(_ id: String, continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation, ownership: BackgroundOwnership) async throws {
		continuation.yield(.init(type: "content", text: nil, reasoning: "Background job started, polling for updates...\n"))
		var previous: OpenAIResponse.Status?; var count = 0
		while true {
			try Task.checkCancellation()
			let response = try await fetchResponse(id: id); count += 1
			if [.completed, .failed, .incomplete, .cancelled].contains(response.status) { await ownership.finish() }
			try Task.checkCancellation()
			if response.status != previous {
				previous = response.status
				let text = response.status == .queued ? "Job queued, waiting for processing...\n" : response.status == .inProgress ? "Processing started...\n" : ""
				if !text.isEmpty { continuation.yield(.init(type: "content", text: nil, reasoning: text)) }
			}
			switch response.status {
			case .completed:
				if let text = response.reasoningText { continuation.yield(.init(type: "content", text: nil, reasoning: text)) }
				if let text = response.outputText { continuation.yield(.init(type: "content", text: text)) }
				continuation.yield(.init(type: "message_stop", text: nil, promptTokens: response.usage?.inputTokens, completionTokens: response.usage?.outputTokens)); return
			case .failed: throw AIProviderError.invalidResponse(detail: response.error?.message ?? "Background job failed.")
			case .incomplete: throw AIProviderError.invalidResponse(detail: response.incompleteDetails?.reason ?? "Background job incomplete.")
			case .cancelled: throw AIProviderError.invalidResponse(detail: "Background job was cancelled.")
			default: try await sleep(.seconds(min(2 + count, 10)))
			}
		}
	}
	private func performCompletion(_ input: AIRequest, profile: OpenAIRequestProfile) async throws -> AICompletionResult {
		try Task.checkCancellation()
		if profile.usesResponsesAPI {
			do {
				let response = try await postResponse(input, profile: profile, background: false); try Task.checkCancellation()
				guard response.status == .completed else {
					let status = response.status?.rawValue ?? "unknown"
					let detail = response.error?.message ?? response.incompleteDetails?.reason ?? "Response status was '\(status)'"
					throw AIProviderError.invalidResponse(detail: "Responses API call did not complete successfully. Status: \(status). Detail: \(detail)")
				}
				guard let text = response.outputText else { throw AIProviderError.invalidResponse(detail: "Responses API call completed but returned no text content.") }
				return .init(text: text, promptTokens: response.usage?.inputTokens, completionTokens: response.usage?.outputTokens)
			} catch let error as OpenAIClientError { throw AIProviderError.apiError(source: error) }
			catch let error as AIProviderError { throw error }
			catch { if Task.isCancelled { throw CancellationError() }; throw AIProviderError.unknown(source: error) }
		}
		let value = try await http.data(for: request(path: "chat/completions", body: try chatBody(input, profile: profile, streaming: false))); try check(value); try Task.checkCancellation()
		let body = try object(value.data)
		let choice = (body["choices"] as? [[String: Any]])?.first
		let message = choice?["message"] as? [String: Any]
		let usage = body["usage"] as? [String: Any]
		return .init(text: message?["content"] as? String ?? "", promptTokens: usage?["prompt_tokens"] as? Int, completionTokens: usage?["completion_tokens"] as? Int)
	}
	private func chatBody(_ input: AIRequest, profile: OpenAIRequestProfile, streaming: Bool) throws -> Data {
		var body: [String: Any] = ["model": input.model.id, "stream": streaming, "messages": input.messages.map { ["role": $0.role.rawValue, "content": $0.text] }]
		if let tokens = profile.chatMaxTokens ?? input.options.maxTokens, tokens != 2048 { body[profile.useMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = tokens }
		if profile.chatTemperatureAllowed, let temperature = input.options.temperature { body["temperature"] = temperature }
		if let effort = input.options.reasoningEffort { body["reasoning_effort"] = effort }
		if streaming {
			body["stream"] = true
			if configuration.baseURL == nil || configuration.includeUsageInStream { body["stream_options"] = ["include_usage": true] }
		}
		return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
	}
	private func pump(_ input: AIRequest, profile: OpenAIRequestProfile, continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) async throws {
		let body = profile.usesResponsesAPI ? try JSONEncoder().encode(OpenAIResponseParameters(request: input, profile: profile, streaming: true)) : try chatBody(input, profile: profile, streaming: true)
		let (bytes, response) = try await streamingHTTP.bytes(for: request(path: profile.usesResponsesAPI ? "responses" : "chat/completions", body: body))
		guard response.statusCode == 200 else {
			var data = Data(); for try await byte in bytes { data.append(byte) }; throw failure(status: response.statusCode, data: data)
		}
		var prompt: Int?, completion: Int?
		for try await line in bytes.lines {
			try Task.checkCancellation()
			guard line.hasPrefix("data:") else { continue }
			let text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
			if text == "[DONE]" { break }
			guard !text.isEmpty else { continue }
			let value = try object(Data(text.utf8))
			if profile.usesResponsesAPI {
				let kind = value["type"] as? String ?? ""
				switch kind {
				case "response.output_text.delta", "response.reasoning_summary_text.delta":
					if let delta = value["delta"] as? String, !delta.isEmpty { continuation.yield(.init(type: "content", text: kind == "response.output_text.delta" ? delta : nil, reasoning: kind == "response.reasoning_summary_text.delta" ? delta : nil)) }
				case "response.completed":
					if let payload = value["response"] as? [String: Any], let usage = payload["usage"] as? [String: Any] { prompt = usage["input_tokens"] as? Int; completion = usage["output_tokens"] as? Int }
					continuation.yield(.init(type: "message_stop", text: nil, promptTokens: prompt, completionTokens: completion)); return
				case "response.failed", "response.incomplete":
					let payload = value["response"] as? [String: Any] ?? [:]
					let detail = kind == "response.failed" ? (payload["error"] as? [String: Any])?["message"] as? String ?? "Responses API returned a failure." : (payload["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "Responses API marked the response as incomplete."
					throw AIProviderError.invalidResponse(detail: detail)
				case "error": throw OpenAIClientError(code: value["code"] as? String, message: value["message"] as? String ?? (value["code"] as? String).map { "OpenAI error (\($0))" } ?? "OpenAI error (no additional details)")
				default: continue
				}
			} else {
				if let usage = value["usage"] as? [String: Any] { prompt = usage["prompt_tokens"] as? Int; completion = usage["completion_tokens"] as? Int }
				let delta = (value["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] ?? [:]
				let content = delta["content"] as? String ?? "", reasoning = delta["reasoning_content"] as? String ?? ""
				if !content.isEmpty || !reasoning.isEmpty { continuation.yield(.init(type: "content", text: content, reasoning: reasoning, promptTokens: prompt, completionTokens: completion)) }
			}
		}
		try Task.checkCancellation()
		continuation.yield(.init(type: "message_stop", text: nil, promptTokens: prompt, completionTokens: completion))
	}
	private func validate(_ input: AIRequest) throws {
		guard input.attachments.isEmpty, !input.messages.contains(where: { $0.role == .tool }) else { throw AIProviderError.invalidConfiguration(detail: "This OpenAI client supports text conversations only.") }
	}
	private func object(_ data: Data) throws -> [String: Any] {
		guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.invalidResponse(detail: "Expected a JSON object.") }; return value
	}
	private func request(path: String, method: String = "POST", body: Data? = nil) throws -> URLRequest {
		let base = configuration.baseURL ?? URL(string: "https://api.openai.com")!
		let version = configuration.baseURL == nil ? "v1" : configuration.apiVersion ?? "v1"
		let suffix = (version.isEmpty ? "" : "/"+version) + "/"+path
		guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix) else { throw AIProviderError.missingURL }
		var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization"); return request
	}
	private func escapedID(_ id: String) throws -> String {
		guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))) else { throw AIProviderError.invalidConfiguration(detail: "Missing response identifier.") }; return encoded
	}
	private func check(_ value: AIHTTPResponse) throws { guard value.http.statusCode == 200 else { throw failure(status: value.http.statusCode, data: value.data) } }
	private func failure(status: Int, data: Data) -> OpenAIClientError {
		let value = try? object(data); let error = value?["error"] as? [String: Any]
		let message = "status code \(status)" + (error == nil ? "" : " " + (error?["message"] as? String ?? "NO ERROR MESSAGE PROVIDED"))
		return .init(statusCode: status, code: error?["code"] as? String, message: message)
	}
	private func cancelRemote(_ id: String) async {
		// The caller may already be cancelled. A separate task lets the authenticated
		// cancellation request reach the server instead of inheriting that state.
		let task = Task { _ = try? await self.cancelResponse(id: id) }
		await task.value
	}
}
