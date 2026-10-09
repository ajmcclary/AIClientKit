import Foundation

/// An extensible provider capability identifier. Unknown identifiers are retained.
public struct AIModelCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let streaming = Self(rawValue: "streaming")
    public static let reasoning = Self(rawValue: "reasoning")
    public static let images = Self(rawValue: "images")
    public static let tools = Self(rawValue: "tools")
    public static let backgroundResponses = Self(rawValue: "backgroundResponses")
    public static let responsesAPI = Self(rawValue: "responsesAPI")
}

/// Model identity and metadata, independent of SDK representations and app preferences.
public struct AIModelDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let provider: AIProviderType
    public let displayName: String
    public let capabilities: Set<AIModelCapability>
    public init(id: String, provider: AIProviderType, displayName: String,
                capabilities: Set<AIModelCapability> = []) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public struct AIRequestMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Attachment payloads are values; file access and lifecycle are owned by the host/session service.
public struct AIRequestAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mediaType: String
    public let data: Data
    public init(id: UUID = UUID(), mediaType: String, data: Data) {
        self.id = id; self.mediaType = mediaType; self.data = data
    }
}

/// Explicit per-request configuration. No preference or credential lookup occurs here.
public struct AIRequestOptions: Codable, Equatable, Sendable {
    public var maxTokens: Int?
    public var temperature: Double?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public init(maxTokens: Int? = nil, temperature: Double? = nil,
                reasoningEffort: String? = nil, serviceTier: String? = nil) {
        self.maxTokens = maxTokens; self.temperature = temperature
        self.reasoningEffort = reasoningEffort; self.serviceTier = serviceTier
    }
}

public struct AIRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let model: AIModelDescriptor
    public let messages: [AIRequestMessage]
    public let attachments: [AIRequestAttachment]
    public let options: AIRequestOptions
    public init(id: UUID = UUID(), model: AIModelDescriptor, messages: [AIRequestMessage],
                attachments: [AIRequestAttachment] = [], options: AIRequestOptions = .init()) {
        self.id = id; self.model = model; self.messages = messages
        self.attachments = attachments; self.options = options
    }
}

/// Provider adapters own request execution; cancellation is scoped to the request identity.
public protocol AIClientProviding: Sendable {
    func stream(_ request: AIRequest) async throws -> AsyncThrowingStream<AIStreamResult, Error>
    func complete(_ request: AIRequest) async throws -> AICompletionResult
    func models() async throws -> [AIModelDescriptor]
    func cancel(requestID: UUID) async
}

/// Hosts select their own credential namespace and signing/storage policy.
public protocol AICredentialStoring: Sendable {
    func credential(for provider: AIProviderType, endpointID: String?) async throws -> String?
    func setCredential(_ value: String?, for provider: AIProviderType, endpointID: String?) async throws
}
