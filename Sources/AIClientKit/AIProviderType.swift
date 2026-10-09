import Foundation

public enum AIProviderType: Codable, Equatable, Hashable, Sendable {
	case anthropic
	case openAI
	case ollama
	case gemini
	case deepseek  // <-- New deepseek provider case
	case featherless // Featherless AI — serverless host for ~thousands of open-weight models
	case customProvider
	case zAI       // <-- New Z.AI provider case
	case claudeCode // <-- New Claude Code provider case
	case codex      // <-- New Codex CLI provider case
	case geminiCli // <-- New Gemini CLI provider case
	case openCode // OpenCode CLI provider case
	case cursor // Cursor CLI provider case
}
