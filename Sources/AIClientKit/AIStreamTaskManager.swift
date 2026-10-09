import Foundation

/// Per-stream identifier for cancellation.
public typealias ChatStreamID = UUID

/// Groups all token-usage info so we can extend it later.
///
/// `Sendable` is a checked conformance: every stored property is an immutable
/// optional of a `Sendable` value type. The conformance has to be spelled out
/// because the type is `public` (Swift only infers `Sendable` for non-public
/// value types), and the streaming pipeline hands these values from the
/// `TaskManager` actor back to the stream's continuation.
public struct ChatTokenInfo: Codable, Equatable, Sendable {
	public let promptTokens: Int?
	public let completionTokens: Int?
	public let cost: Double?

	public init(
		promptTokens: Int? = nil,
		completionTokens: Int? = nil,
		cost: Double? = nil
	) {
		self.promptTokens = promptTokens
		self.completionTokens = completionTokens
		self.cost = cost
	}
}

/// The output of our Chat stream, now carrying a TokenInfo block.
///
/// `Sendable` is a checked conformance: `text`/`reasoning`/`isFinal` are
/// immutable standard-library values and `tokens` is the `Sendable`
/// `ChatTokenInfo` above. Spelled out for the same reason: the type is `public`,
/// and it travels from actor-isolated buffer flushes into the async stream.
public struct ChatStreamOutput: Sendable {
	public let text: String
	public let reasoning: String?
	public let tokens: ChatTokenInfo
	public let isFinal: Bool

	public init(text: String, reasoning: String?, tokens: ChatTokenInfo, isFinal: Bool) {
		self.text = text; self.reasoning = reasoning; self.tokens = tokens; self.isFinal = isFinal
	}
}

struct PartialBuffer {
	var chunks: [String] = []
	var charCount: Int = 0
	var reasoningChunks: [String] = []     // NEW: Buffer for reasoning text
	var reasoningCharCount: Int = 0          // NEW: Count of reasoning characters
	var lastFlushTime: Date = Date()

	// Token & cost tracking
	var promptTokens: Int?
	var completionTokens: Int?
	var cost: Double?       // NEW: track cost
}

public enum ReasoningTextFormatter {
	public static func normalize(_ text: String) -> String {
		guard !text.isEmpty else { return text }

		var normalized = text
		let replacements: [(pattern: String, template: String)] = [
			(#"\*\*([^\n*]+)\*\*\*\*([^\n*]+)\*\*"#, "**$1**\n\n**$2**"),
			(#"\*\*([^\n*]+)\*\*\*\*([^\n*]+)$"#, "**$1**\n\n**$2")
		]

		var didChange = true
		while didChange {
			didChange = false
			for replacement in replacements {
				let updated = normalized.replacingOccurrences(
					of: replacement.pattern,
					with: replacement.template,
					options: .regularExpression
				)
				if updated != normalized {
					normalized = updated
					didChange = true
				}
			}
		}

		return normalized
	}
}

/// Manages streaming tasks and partial output buffers for AI responses.
public actor AIStreamTaskManager {
	private let now: @Sendable () -> Date

	public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }
	/// Store tasks as `Task<Void, Never>`, so they don't throw
	private var tasks: [UUID: Task<Void, Never>] = [:]

	/// Each UUID has a PartialBuffer for storing streamed text and reasoning
	private var partialBuffers: [UUID: PartialBuffer] = [:]

	/// Keep track of each stream's continuation so we can explicitly finish it on cancel
	private var continuations: [UUID: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]

	/// Tracks streams that have been requested to cancel before the task or continuation existed.
	/// This prevents race conditions where cancelTask is called before addTask/storeContinuation.
	private var cancelledIDs: Set<UUID> = []

	// MARK: - Registering Tasks & Continuations

	public func addTask(_ task: Task<Void, Never>, for id: UUID) {
		// If cancellation was requested before task was registered, cancel immediately
		if cancelledIDs.contains(id) {
			task.cancel()
			return
		}
		tasks[id] = task
	}

	/// Store the AsyncThrowingStream continuation so we can signal cancellation later.
	public func storeContinuation(
		_ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation,
		for id: UUID
	) {
		// If cancellation was requested before continuation was stored, finish immediately
		if cancelledIDs.contains(id) {
			continuation.finish(throwing: CancellationError())
			return
		}
		continuations[id] = continuation
	}

	public func removeTask(for id: UUID) {
		tasks[id] = nil
		partialBuffers[id] = nil
		continuations[id] = nil
		cancelledIDs.remove(id)
	}

	// MARK: - Partial Buffer

	public func createPartialBuffer(for id: UUID) {
		// Clear any stale cancelled flag when starting fresh
		cancelledIDs.remove(id)
		partialBuffers[id] = PartialBuffer(lastFlushTime: now())
	}

	/// Check if a stream ID has been marked for cancellation
	public func isCancelled(_ id: UUID) -> Bool {
		cancelledIDs.contains(id)
	}

	/// Accumulates text / reasoning / token counts in the partial buffer.
	/// Returns `true` if either buffer exceeds the threshold or the time-limit.
	public func bufferChunk(
		_ text: String,
		for id: UUID,
		chunkSizeThreshold: Int,
		timeThreshold: TimeInterval,
		isReasoning: Bool = false,
		promptTokens: Int? = nil,
		completionTokens: Int? = nil,
		cost: Double? = nil       // NEW parameter
	) -> Bool {
		guard var buffer = partialBuffers[id] else { return false }

		if isReasoning {
			buffer.reasoningChunks.append(text)
			buffer.reasoningCharCount += text.count
		} else {
			buffer.chunks.append(text)
			buffer.charCount += text.count
		}

		// Keep the latest non-nil token counts and cost
		if let p = promptTokens { buffer.promptTokens = p }
		if let c = completionTokens { buffer.completionTokens = c }
		if let costValue = cost { buffer.cost = costValue }   // NEW

		let now = now()
		let elapsed = now.timeIntervalSince(buffer.lastFlushTime)

		let shouldYieldText = buffer.charCount >= chunkSizeThreshold
		let shouldYieldReasoning = buffer.reasoningCharCount >= chunkSizeThreshold
		let shouldYield = (shouldYieldText || shouldYieldReasoning) || (elapsed >= timeThreshold)

		partialBuffers[id] = buffer
		return shouldYield
	}

	/// Flushes the accumulated chunks and any stored token counts.
	/// Returns `(text, reasoning, tokenInfo, didReset)`.
	public func flushBuffer(for id: UUID) -> (String, String?, ChatTokenInfo?, Bool) {
		guard var buffer = partialBuffers[id] else {
			return ("", nil, nil, false)
		}
		let combinedText = buffer.chunks.joined()
		let combinedReasoning = buffer.reasoningChunks.joined()

		// Include cost in token info if available
		let hasTokenInfo = buffer.promptTokens != nil || buffer.completionTokens != nil || buffer.cost != nil
		let tokenInfo: ChatTokenInfo? = hasTokenInfo
			? ChatTokenInfo(
				promptTokens: buffer.promptTokens,
				completionTokens: buffer.completionTokens,
				cost: buffer.cost         // NEW
			)
			: nil

		// Reset buffer
		buffer.chunks.removeAll()
		buffer.charCount = 0
		buffer.reasoningChunks.removeAll()
		buffer.reasoningCharCount = 0
		buffer.promptTokens = nil
		buffer.completionTokens = nil
		buffer.cost = nil                 // NEW reset cost
		buffer.lastFlushTime = now()

		partialBuffers[id] = buffer
		let didReset = !(combinedText.isEmpty && combinedReasoning.isEmpty && tokenInfo == nil)
		return (combinedText, combinedReasoning.isEmpty ? nil : combinedReasoning, tokenInfo, didReset)
	}

	// MARK: - Cancellation

	/// Cancel only the given stream: task + stream continuation + buffer.
	/// Records the ID so that late-arriving task/continuation registrations are also cancelled.
	public func cancelTask(for id: UUID) {
		// Record cancellation intent - handles race where cancel arrives before registration
		cancelledIDs.insert(id)

		if let task = tasks[id] {
			task.cancel()
		}
		if let cont = continuations.removeValue(forKey: id) {
			cont.finish(throwing: CancellationError())
		}
		tasks[id] = nil
		partialBuffers[id] = nil
	}

	/// Cancels all tasks by delegating to cancelTask(for:) for each.
	public func cancelAllTasks() {
		let allIds = Set(tasks.keys).union(continuations.keys).union(partialBuffers.keys)
		for id in allIds {
			cancelTask(for: id)
		}
	}
}
