import Foundation

/// Updated `AIStreamResult` to include optional `reasoning`, token counts, and tool metadata.
public struct AIStreamResult: Sendable {
	/// Standard type strings for stream results
	public static let lifecycleType = "lifecycle"

	public let type: String            // e.g. "content", "message_stop", "tool_call", "tool_result", "final_content", "lifecycle"
	public let text: String?           // normal content (like streaming tokens)
	public let reasoning: String?      // optional reasoning content
	public let promptTokens: Int?      // token usage
	public let completionTokens: Int?  // token usage
	public let cost: Double?

	// Tool-specific metadata (for type: "tool_call" or "tool_result")
	public let toolName: String?       // Name of the tool being called/completed
	public let toolArgs: String?       // JSON string of tool arguments (for tool_call)
	public let toolOutput: String?     // Tool execution result (for tool_result)
	public let toolInvocationID: UUID?
	public let toolResultJSON: String?
	public let toolArgsJSON: String?
	public let toolIsError: Bool?

	/// Provider-specific session ID for resuming conversations (e.g., Claude CLI session_id)
	public let providerSessionID: String?
	public let stopReason: String?
	public let modelContextWindow: Int?
	/// Best-effort estimate of input-side context used for the turn (e.g. Claude input + cache tokens)
	public let contextUsedTokens: Int?
	/// Stable provider message identifier for content chunks when available.
	/// Used by lightweight aggregators to separate whole-message chunks without affecting token deltas.
	public let contentMessageID: String?

	public init(
		type: String,
		text: String?,
		reasoning: String? = nil,
		promptTokens: Int? = nil,
		completionTokens: Int? = nil,
		cost: Double? = nil,
		toolName: String? = nil,
		toolArgs: String? = nil,
		toolOutput: String? = nil,
		toolInvocationID: UUID? = nil,
		toolResultJSON: String? = nil,
		toolArgsJSON: String? = nil,
		toolIsError: Bool? = nil,
		providerSessionID: String? = nil,
		stopReason: String? = nil,
		modelContextWindow: Int? = nil,
		contextUsedTokens: Int? = nil,
		contentMessageID: String? = nil
	) {
		self.type = type
		self.text = text
		self.reasoning = reasoning
		self.promptTokens = promptTokens
		self.completionTokens = completionTokens
		self.cost = cost
		self.toolName = toolName
		self.toolArgs = toolArgs
		self.toolOutput = toolOutput
		self.toolInvocationID = toolInvocationID
		self.toolResultJSON = toolResultJSON
		self.toolArgsJSON = toolArgsJSON
		self.toolIsError = toolIsError
		self.providerSessionID = providerSessionID
		self.stopReason = stopReason
		self.modelContextWindow = modelContextWindow
		self.contextUsedTokens = contextUsedTokens
		self.contentMessageID = contentMessageID
	}
}

/// Result type for non-streaming completions, includes token counts
public struct AICompletionResult: Sendable {
	public let text: String
	public let promptTokens: Int?
	public let completionTokens: Int?
	public let cost: Double?

	public init(text: String, promptTokens: Int? = nil, completionTokens: Int? = nil, cost: Double? = nil) {
		self.text = text
		self.promptTokens = promptTokens
		self.completionTokens = completionTokens
		self.cost = cost
	}
}
