---
title: Errors and retries
description: Handle failed model requests, cancellations, and temporary provider errors.
---

nimgent retries temporary provider failures for you. When a request still fails, catch `ProviderError` to show a useful message, reduce an oversized prompt, or record the provider request ID for support.

## Handle a failed request

This example makes a request and distinguishes cancellation, a context overflow, and other provider errors.

```nim title="handle_errors.nim"
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")

try:
  let response = generateText(model, prompt = "Explain Nim in one sentence.")
  echo response.text
except CancelledError:
  echo "Request cancelled."
except ProviderError as error:
  if error.overflow:
    echo "The prompt is too large. Try sending less context."
  else:
    echo "The request failed: ", error.msg
    if error.requestId.len > 0:
      echo "Provider request ID: ", error.requestId
```

`ProviderError` covers network and provider API failures. Its fields let you respond to the kind of failure without parsing an error message.

| Field | Use it for |
| --- | --- |
| `status` | The HTTP status code, or `0` when no response arrived. |
| `overflow` | Reduce the prompt, history, or attached content. |
| `retryable` | Record whether the failure was temporary. |
| `requestId` | Give the provider's request ID to support. |
| `retryAfterMs` | See a delay requested by the provider. |

## Retries happen automatically

`generateText`, `streamText`, structured output, and embeddings retry temporary failures twice by default. This covers rate limits, server errors, and network failures.

Set `maxRetries` when you need a different limit. Set it to `0` when your application should make exactly one attempt.

```nim
let response = generateText(
  model,
  prompt = "Summarize this report.",
  maxRetries = 5
)
```

nimgent does not retry a cancelled request, a context overflow, or a non-temporary provider error. A stream is retried only before it has delivered content, so users never receive a duplicated partial answer.

Provider-provided retry delays are honored. Otherwise, nimgent waits for a short randomized backoff between attempts.

## Observe retries

Use `onRetry` when you want to show status in a UI or record retry activity.

```nim
let response = generateText(
  model,
  prompt = "Summarize this report.",
  callbacks = RunCallbacks(
    onRetry = proc (attempt, delayMs: int, error: ref ProviderError) =
      echo "Retry ", attempt, " in ", delayMs, "ms: ", error.msg
  )
)
```

`attempt` starts at `1` for the first retry.

## Cancel work the user no longer needs

Pass an `abort` callback that returns `true` when your application wants to stop the request.

```nim
var stopRequested = false

let response = generateText(
  model,
  prompt = "Write a detailed guide to Nim.",
  abort = proc (): bool = stopRequested
)
```

When the callback returns `true`, nimgent raises `CancelledError`. Catch it before `ProviderError` when cancellation is a normal user action.

For streaming, return `false` from `onEvent` to stop the stream:

```nim
discard streamText(model, prompt = "List ten ideas.", onEvent =
  proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
    not stopRequested
)
```

Cancellation is cooperative for local tools. If a tool does long-running work, check `context.abort()` during that work so it can stop promptly.

## Other errors you may see

`generateObject` raises `ObjectError`, a subtype of `ProviderError`, when it cannot produce a value that matches your schema. Its `issueDetails` and `raw` fields help you diagnose the output. See [Structured output](/guides/structured-output/) for the repair flow.

Tool failures are different: a failed local tool call becomes a result the model can read and respond to. It does not automatically fail the whole model run. See [Tools and agents](/guides/tools-and-agents/) for returning tool failures.

## Troubleshooting

- **The request fails immediately:** Check your API key, model ID, and request options. Retrying a bad request will not fix it.
- **You receive a rate limit:** Keep the default retries, reduce concurrent work, or raise `maxRetries` if waiting is acceptable for your application.
- **The prompt is too large:** Send less history or context. Do not retry an overflow unchanged.
- **A stream stops after showing text:** Treat the partial response as incomplete. nimgent does not restart streams after content has arrived.

## Next steps

See [Streaming](/guides/streaming/) for rendering partial output, or [Sessions](/guides/sessions/) for managing conversation history before it becomes too large.
