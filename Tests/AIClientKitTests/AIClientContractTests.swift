import Foundation
import XCTest
import AIClientKit

final class AIClientContractTests: XCTestCase {
    func testPersistedProviderCaseSpellingsRemainCompatible() throws {
        let fixtures: [(AIProviderType, String)] = [
            (.anthropic, "anthropic"), (.openAI, "openAI"), (.ollama, "ollama"),
            (.gemini, "gemini"), (.deepseek, "deepseek"), (.featherless, "featherless"),
            (.customProvider, "customProvider"), (.zAI, "zAI"), (.claudeCode, "claudeCode"),
            (.codex, "codex"), (.geminiCli, "geminiCli"), (.openCode, "openCode"), (.cursor, "cursor")
        ]
        for (provider, spelling) in fixtures {
            let data = Data("{\"\(spelling)\":{}}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(AIProviderType.self, from: data), provider)
            let encoded = try JSONEncoder().encode(provider)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
    }

    func testRequestRoundTripPreservesOpaqueModelIdentityUnknownCapabilitiesAndUnicode() throws {
        let descriptor = AIModelDescriptor(id: "custom:ABC/Model-X", provider: .customProvider,
            displayName: "Custom model", capabilities: [.streaming, .init(rawValue: "future-provider-feature")])
        let request = AIRequest(model: descriptor, messages: [.init(role: .user, text: "Explain café 🧭")],
            attachments: [.init(mediaType: "image/png", data: Data([0, 1, 255]))],
            options: .init(maxTokens: 200, temperature: 0.2, reasoningEffort: "high", serviceTier: "default"))
        XCTAssertEqual(try JSONDecoder().decode(AIRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testStreamResultRetainsToolCorrelationResumeAndAuthoritativeUsage() {
        let invocation = UUID()
        let result = AIStreamResult(type: "tool_result", text: nil, promptTokens: 123,
            completionTokens: 45, cost: 0.25, toolName: "read_file", toolInvocationID: invocation,
            toolResultJSON: "{\"text\":\"hello\"}", toolIsError: false, providerSessionID: "session-1",
            stopReason: "completed", modelContextWindow: 8192, contextUsedTokens: 500)
        XCTAssertEqual(result.toolInvocationID, invocation)
        XCTAssertEqual(result.providerSessionID, "session-1")
        XCTAssertEqual(result.promptTokens, 123)
        XCTAssertEqual(result.completionTokens, 45)
        XCTAssertEqual(result.contextUsedTokens, 500)
        XCTAssertEqual(result.toolIsError, false)
    }
}
