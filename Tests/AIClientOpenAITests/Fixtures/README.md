# OpenAI SDK wire characterizations

These sanitized request bodies were captured with RepoPrompt's production
OpenAIProvider and a URLProtocol fixture before interface migration. SDK source:
provencher/SwiftOpenAI revision 1211782eb337e7968124448a20d9260df1952012.

The four baseline test cases passed alongside eight token-resolution cases on
2026-10-09. One live case skipped because no stored OpenAI key was available.
Credentials, hosts, messages, and responses are synthetic. Bodies are compared
structurally; key ordering and slash escaping are not API behavior.

`unknown_model` and `gpt-5.2` are actual model resolutions observed for the
legacy gpt41/o1Mini and gpt5High identities in this checkout; the extraction
preserves those values rather than changing existing model metadata.

Never rewrite these fixtures automatically after a failure. A behavior change
requires source evidence and an explicit decision, as with visual baselines.
