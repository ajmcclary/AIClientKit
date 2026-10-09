# AIClientKit

SDK-neutral AI request, provider identity, streaming, completion, model metadata,
and credential-store contracts, plus streaming task/buffer coordination extracted from RepoPrompt. Swift 6, strict
concurrency, macOS 27; no app/UI imports. Vendor dependencies are confined to
their provider targets; core contracts and HTTP remain dependency-free.

The initial extraction preserves RepoPrompt's provider Codable spelling and
stream-result metadata. Provider products below contain the extracted network
clients; storage and remaining providers are subsequent adoption slices.

Build and test with `swift build` and `swift test`. Hosts supply credentials,
configuration, request cancellation, and provider implementation explicitly.

Source lineage: RepoPrompt (`github.com/ajmcclary/RepoPrompt`), Apache-2.0.

`AIStreamTaskManager` owns buffering, usage flushes, per-request cancellation,
and late-registration cancellation. Its clock is injectable. Global cancellation
also reaches streams whose provider task has not registered yet.

## Provider products

- `AIClientHTTP`: injectable Foundation HTTP transport and off-executor decoding.
  Session timeout/connectivity profiles are explicit constructor inputs.
- `AIClientOpenAICompatible`: the real custom-endpoint implementation extracted
  from RepoPrompt: chat completions, SSE streaming, model discovery, credential
  validation, headers, token/temperature rules, error mapping, retries, and
  request-scoped cancellation. No application or external vendor SDK imports.

Hosts supply already-composed `AIRequest` messages and resolved model/options.
`OpenAICompatibleMessageBuilder` preserves the legacy custom-endpoint context
placement without consulting preferences. This client supports text requests;
image attachments are rejected explicitly. System/user/assistant/tool text roles
are serialized as supplied; richer vendor-specific tool messages are separate
adapters. HTTP Content-Type and token sentinel behavior are characterized against
the extracted implementation. Normal and cancellation stop events are preserved.

Provider implementations for the OpenAI SDK paths and native agents
remain separate subsequent extraction slices.

- `AIClientModelDiscovery`: live Anthropic, Gemini, Ollama, and Featherless
  catalogs with injected HTTP clients/credentials. Gemini retains its 20-page
  bound, chat-model filtering, and ordered deduplication; Ollama reads installed
  `/api/tags`; Featherless filters on the server and takes an explicit host title.
  Network request and decoding characterizations are package-owned.

- `AIClientAnthropic`: SDK-backed text messages, thinking budgets, ephemeral
  system-prompt caching, streaming projection, completion, model discovery,
  neutral errors, and cancellation. Supply credentials, endpoint/version/beta
  headers, a session configuration, and catalog HTTP transport. Each request
  owns a separate session copied from the supplied configuration. Cancellation
  terminates only that request. SwiftAnthropic 2.2.2 types remain internal.
  Legacy streaming/completion token and temperature differences are retained.
  The bridge emits one stop event and reconciles native start/delta usage.
  Attachments and structured tool turns are rejected by this text client.
