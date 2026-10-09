import AIClientKit

/// Preserves the custom-endpoint context layout: context precedes only the last user turn.
/// Hosts pass resolved XML/text; this builder reads no preferences or application state.
public enum OpenAICompatibleMessageBuilder {
    public static func compose(
        systemPrompt: String,
        fileTreeXML: String? = nil,
        fileContentsXML: String? = nil,
        metaPrompts: [String] = [],
        conversation: [AIRequestMessage]
    ) -> [AIRequestMessage] {
        var messages: [AIRequestMessage] = []
        if !systemPrompt.isEmpty { messages.append(.init(role: .system, text: systemPrompt)) }
        var additions = ""
        if let fileTreeXML { additions += fileTreeXML + "\n" }
        if let fileContentsXML { additions += fileContentsXML + "\n" }
        for prompt in metaPrompts { additions += prompt + "\n" }
        let lastUser = conversation.lastIndex { $0.role == .user }
        for (index, entry) in conversation.enumerated() {
            let text = index == lastUser && !additions.isEmpty ? additions + "\n" + entry.text : entry.text
            messages.append(.init(role: entry.role, text: text))
        }
        return messages
    }
}
