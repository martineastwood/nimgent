---
title: Examples
description: Runnable examples shipped with the nimgent repository.
---

The repository keeps complete examples in
[`examples/`](https://github.com/martineastwood/nimgent/tree/main/examples).

| Example | Demonstrates |
| --- | --- |
| `generate_text.nim` | Basic generation |
| `stream_text.nim` | Incremental text output |
| `async_generate.nim` | Concurrent async requests |
| `tool_call.nim` | A typed local tool |
| `agent.nim` | A bounded reusable agent |
| `agent_events.nim` | Lifecycle events and approval |
| `lifecycle_callbacks.nim` | Retries, tool timing, and step hooks |
| `structured_output.nim` | Typed JSON output |
| `stream_object.nim` | Partial structured output |
| `session.nim` | Persisted multi-turn conversations |
| `embeddings.nim` | Batch embeddings and similarity |
| `provider_options.nim` | Typed provider settings |
| `wrap_provider.nim` | Request and response middleware |
| `chat_with_pdf.nim` | File input and source citations |
| `mcp_client.nim` | Tools served by an MCP server |
| `anthropic_smoke.nim` | Live Anthropic streaming and structured output |
| `google_smoke.nim` | Live Gemini search, URL context, and tool loops |

Run one from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/stream_text.nim
```

The provider smoke tests use their corresponding credentials:

```sh
ANTHROPIC_API_KEY=... nim c -r examples/anthropic_smoke.nim
GEMINI_API_KEY=... nim c -r examples/google_smoke.nim
```
