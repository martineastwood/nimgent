---
title: Custom provider
description: Connect nimgent to a model API that does not have a built-in provider.
---

You can add support for another model API by defining a subtype of `Provider`. Once it returns normalized nimgent responses, your provider works with `generateText`, agents, sessions, tools, retries, and structured output.

## Build a minimal provider

This complete example makes a local provider that always returns the same answer. It demonstrates the smallest adapter nimgent needs.

```nim title="custom_provider.nim"
import std/asyncdispatch
import nimgent

type EchoProvider = ref object of Provider

method generateAsync(provider: EchoProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  result = ProviderResponse(
    model: request.model,
    content: @[text("Hello from the custom provider.")],
    finishReason: frStop
  )

let provider = EchoProvider(name: "echo")
let model = provider.model("echo-1")

echo generateText(model, prompt = "Say hello.").text
```

Run it with:

```sh
nim c -r custom_provider.nim
```

For a real provider, replace the fixed response with a request to the vendor API. `generateAsync` receives the requested model, messages, system instruction, tools, generation settings, and provider options in `ProviderRequest`.

## Return normalized content

Convert the provider's response into `ProviderResponse` and its `content` blocks. The most common blocks are:

| Provider response | nimgent block |
| --- | --- |
| Answer text | `text("...")` |
| Model tool call | `toolUse(id, name, input)` |
| Model reasoning, when the provider returns it | `thinking(...)` |
| Citation or source | `source(...)` |

Set `finishReason` to `frToolUse` when the response contains an executable tool call. Otherwise use the finish reason that best matches the provider response, such as `frStop` or `frEndTurn`.

Include `usage` and `requestId` when the provider supplies them. They appear in the final result and make cost reporting and support troubleshooting more useful.

## Report provider failures

Use `raiseProviderError` when the remote API rejects a request or its transport fails.

```nim
raiseProviderError(
  "Example AI API error: rate limit exceeded",
  status = 429,
  requestId = "request-id-from-the-provider"
)
```

The status marks rate limits and server errors as retryable. nimgent then applies the normal retry policy. Mark a context-window failure with `overflow = true` so the application can reduce its prompt instead of retrying unchanged.

## Add native streaming

You do not need to implement streaming to get started. The base provider streams the completed response after `generateAsync` returns.

Implement `generateStreamAsync` when the vendor offers a streaming API and you want text to reach `onEvent` as it arrives. Send `seTextDelta`, `seThinkingDelta`, and `seToolCallDelta` events while you receive the provider stream, then return the assembled `ProviderResponse`.

## Add optional features

Implement `embedAsync` when the provider offers embeddings. Without it, embedding calls fail with a clear unsupported-provider error.

`generateObject` works with its JSON fallback without extra provider code. Implement `nativeObjectOptions` and `nativeObjectSchemaIssues` only when the vendor has a native structured-output format that you want nimgent to use.

## Troubleshooting

- **The model does not continue after a tool call:** Return a `toolUse` block with a stable call ID and set `finishReason` to `frToolUse`.
- **A request loses part of the conversation:** Convert every message role and content block your application sends, including tool results and attachments where you support them.
- **Streaming waits for the full answer:** Implement `generateStreamAsync` for the vendor's streaming protocol.
- **The retry behavior is wrong:** Raise `ProviderError` with the HTTP status and request ID instead of a plain exception.

## Next steps

Use [Tools and agents](/nimgent/guides/tools-and-agents/) to support tool calls, and [Testing](/nimgent/guides/testing/) to test application behavior with deterministic model responses.
