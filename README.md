# AIClientKit

SDK-neutral AI request, provider identity, streaming, completion, model metadata,
and credential-store contracts extracted from RepoPrompt. Swift 6, strict
concurrency, macOS 27; no package dependencies and no app/UI imports.

The initial extraction preserves RepoPrompt's provider Codable spelling and
stream-result metadata. Provider implementations and storage adapters are the
next adoption slices; this release does not claim to implement network clients.

Build and test with `swift build` and `swift test`. Hosts supply credentials,
configuration, request cancellation, and provider implementation explicitly.

Source lineage: RepoPrompt (`github.com/ajmcclary/RepoPrompt`), Apache-2.0.
