import AIClientKit
import Foundation
import XCTest

final class AIStreamTaskManagerTests: XCTestCase {
    func testCancelAllFinishesStreamsBeforeTaskRegistration() async throws {
        let manager = AIStreamTaskManager()
        let id = UUID()
        await manager.createPartialBuffer(for: id)
        let channel = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
        await manager.storeContinuation(channel.continuation, for: id)
        await manager.cancelAllTasks()
        var iterator = channel.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("A stream awaiting provider/task registration must be cancelled")
        } catch is CancellationError {}
        let cancelled = await manager.isCancelled(id)
        XCTAssertTrue(cancelled)
    }

    func testCancelAllRejectsLateContinuationRegistration() async throws {
        let manager = AIStreamTaskManager()
        let id = UUID()
        await manager.createPartialBuffer(for: id)
        await manager.cancelAllTasks()
        let channel = AsyncThrowingStream<ChatStreamOutput, Error>.makeStream()
        await manager.storeContinuation(channel.continuation, for: id)
        var iterator = channel.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Cancellation must survive a late registration")
        } catch is CancellationError {}
    }

    func testFlushPreservesOrderReasoningAndLatestUsageThenResets() async {
        let manager = AIStreamTaskManager(now: { Date(timeIntervalSince1970: 10) })
        let id = UUID()
        await manager.createPartialBuffer(for: id)
        _ = await manager.bufferChunk("first ", for: id, chunkSizeThreshold: 100, timeThreshold: 100, promptTokens: 3)
        _ = await manager.bufferChunk("second", for: id, chunkSizeThreshold: 100, timeThreshold: 100, completionTokens: 2)
        _ = await manager.bufferChunk("**Plan****Build**", for: id, chunkSizeThreshold: 100, timeThreshold: 100, isReasoning: true, cost: 0.25)
        let output = await manager.flushBuffer(for: id)
        XCTAssertEqual(output.0, "first second")
        XCTAssertEqual(output.1, "**Plan****Build**")
        XCTAssertEqual(output.2, ChatTokenInfo(promptTokens: 3, completionTokens: 2, cost: 0.25))
        XCTAssertTrue(output.3)
        let next = await manager.flushBuffer(for: id)
        XCTAssertEqual(next.0, "")
        XCTAssertNil(next.1)
        XCTAssertNil(next.2)
        XCTAssertFalse(next.3)
    }
}
