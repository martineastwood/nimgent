---
title: Streaming
description: Stream text, thinking, and tool-call deltas as they arrive.
---

Use `streamText` when the application should render output incrementally:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = streamText(
  model,
  prompt = "Count to three.",
  onEvent = proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    true)

echo ""
echo response.finishReason
```

`StreamEvent` can contain text deltas, thinking deltas, tool-call fragments, a
finish marker, or a wake event. Return `false` from the callback to cancel; the
call raises `CancelledError`.

## Async streaming

The async form is the primitive API:

```nim
let response = await streamTextAsync(
  model,
  onEvent = proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
    true,
  prompt = "Write a short haiku.")
```

Keep callbacks small and hand off expensive work to the surrounding async
application. Providers preserve the normalized response while emitting live
deltas.

## Structured event streams

Agents can expose a normalized lifecycle that includes run boundaries, model
deltas, complete tool calls, approvals, tool results, and errors:

```nim
let events = researcher.events("What should I deploy?")
while true:
  let (available, event) = await events.read()
  if not available: break
  handle(event)

let response = await events.result
```

See [Tools and agents](/guides/tools-and-agents/) for approval handling.
