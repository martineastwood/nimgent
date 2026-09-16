---
title: Core API
description: The small set of types and entry points used by most applications.
---

## Models

| Type | Purpose |
| --- | --- |
| `Provider` | Provider adapter and model factory |
| `LanguageModel` | A text-generation model bound to a provider |
| `EmbeddingModel` | An embedding model bound to a provider |
| `ProviderRequest` | Provider-neutral request for direct adapter use |
| `ProviderResponse` | Normalized model response, usage, and steps |
| `GenerationOptions` | Portable sampling, stopping, seeding, and reasoning settings |

Create models through a provider:

```nim
let chat = openAI(apiKey).model("gpt-4o-mini")
let embeddings = openAI(apiKey).embeddingModel("text-embedding-3-small")
```

For every exported type and procedure, see the [generated API reference](/reference/api/nimgent/).

## Generation

```nim
generateText(model, prompt = "Hello")
generateTextAsync(model, prompt = "Hello")
streamText(model, prompt = "Hello", onEvent = callback)
streamTextAsync(model, prompt = "Hello", onEvent = callback)
```

The response exposes `text`, `content`, `usage`, `finishReason`, `requestId`,
and `steps`. A multi-turn tool run aggregates usage in `totalUsage`.
Pass portable generation controls through `generationOptions` and provider
extensions through `providerOptions`; see [Providers](/guides/providers/).

## Observability

Set `RunCallbacks.trace` to a `TraceSink` to receive completed spans for runs,
steps, provider attempts, and local tools. The core has no telemetry dependency
and omits prompts, tool arguments, and model output by default. Embeddings accept
the same sink through their `trace` parameter, as do structured-output calls.
See [Observability](/guides/observability/) for the span names and attributes.

## Embeddings

```nim
let one = embed(embeddings, "sunny day")
let many = embedMany(embeddings, @["sunny day", "rainy day"])
let similarity = cosineSimilarity(many.embeddings[0], many.embeddings[1])
```

`nimgent/vector_store` adds an in-memory store — `upsert`, `search`, `delete`,
`save`, and `loadInMemoryVectorStore` — for local retrieval. See
[Embeddings & RAG](/guides/embeddings-rag/).

## Cancellation and retries

Pass `abort` to stop before the next provider attempt or tool call:

```nim
let response = await generateTextAsync(
  model,
  prompt = "Continue until done.",
  abort = proc (): bool = shouldStop())
```

Transient HTTP and transport failures are retried by default. Configure the
limit with `maxRetries`. Context overflow, ordinary client errors, and a
started stream are not retried. See
[Error Handling](/guides/error-handling/) for the `ProviderError`
fields and backoff rules.

## MCP clients

```nim
import nimgent/mcp

let client = await connectMcpStdioAsync(@["./my-mcp-server"])
let remoteTools = await client.asToolsAsync(prefix = "fs_")
```

See [MCP tools](/guides/mcp/).

## Composing providers

`wrapProvider(inner, mapRequest, mapResponse)` intercepts every request and
response; `routeProvider(default, route)` sends each model to the provider that
serves it. See [Middleware and routing](/guides/middleware-and-routing/).

## Testing

```nim
import nimgent/testing

let model = scriptedModel(@[textResponse("hello")])
```

`FakeProvider` records every request it received. See
[Testing](/guides/testing/).

## Direct provider requests

Use a ready-made `ProviderRequest` when the application owns the request
shape. `generateText(provider, request)` and `streamText(provider, request,`
`callback)` provide retrying wrappers without running a local tool loop. Its
`options` field is raw provider wire JSON for low-level integrations; normal
generation calls use `generationOptions` and `providerOptions` instead.
