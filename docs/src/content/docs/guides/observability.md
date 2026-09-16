---
title: Observability
description: Observe model runs, tools, retries, and embeddings with a small callback.
---

Use nimgent's observability callbacks to inspect model runs, agent steps, tool
calls, retries, and embedding operations as they complete. Each callback
receives a completed span with timing, status, and operation metadata that you
can print, save, or forward to your telemetry system. Prompts, messages, tool
arguments, tool output, and model output are excluded by default.

## Capture spans

Pass a `TraceSink` through `RunCallbacks`:

```nim title="trace_run.nim"
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let trace: TraceSink = proc (span: TraceSpan) =
  echo span.name, " ", span.status, " ", durationMs(span), "ms"

let response = generateText(
  model,
  prompt = "Give me one short greeting.",
  callbacks = RunCallbacks(trace: trace))

echo response.text
```

The callback runs when each span is complete. A simple request usually emits a
model span, a step span, and a run span. The run span finishes last, so you can
use it as the overall result for the operation.

## Understand the spans

| Span | What it represents |
| --- | --- |
| `nimgent.run` | One text, agent, or structured-output run |
| `nimgent.step` | One model turn in a run |
| `nimgent.model` | One provider attempt, including retries |
| `nimgent.tool` | One local tool call |
| `nimgent.embedding` | One `embed` or `embedMany` operation |
| `nimgent.embedding.attempt` | One embedding provider attempt |

Each span has a `kind`, `status`, start and end timestamps, and an optional
`error` message. Use `durationMs(span)` for elapsed time. `spanId` and
`parentSpanId` let you rebuild the nesting between a run, its steps, model
attempts, and tools.

The available span kinds are `skRun`, `skStep`, `skModel`, `skTool`, and
`skEmbedding`. Status is one of `ssOk`, `ssError`, or `ssCancelled`.

## Inspect attributes

`span.attributes` is a `JsonNode` containing useful operation details. Depending
on the span, it can include:

- provider and model names
- step and attempt numbers
- token usage and request IDs
- finish reasons
- tool names, call IDs, and whether the tool failed
- retry status and delay

Built-in spans do not include prompts, messages, tool arguments, tool output, or
model output. Conversation IDs and turn IDs are included when your request supplies
them, so treat those values according to your application's privacy rules.
Run spans expose them as `conversation_id` and `turn_id` attributes.

## Trace agents and streams

Use the same callback with an `Agent`, `streamText`, or an agent event stream:

```nim
let response = researcher.run(
  "Find the answer.",
  callbacks = RunCallbacks(trace: trace),
  conversationId = "research-session")
```

Streaming runs use the same spans. The model span stays open until the provider
stream finishes, and its attributes include `stream: true`.

Retries appear as separate `nimgent.model` spans. A failed attempt has
`ssError`, while a later successful attempt has `ssOk`.

## Trace embeddings and structured output

Embedding functions receive the sink directly:

```nim
let result = embedMany(
  provider.embeddingModel("text-embedding-3-small"),
  @["first document", "second document"],
  trace = trace)
```

Structured-output functions do the same:

```nim
let result = generateObject(model, schema, prompt = "Extract the data.",
  trace = trace)
```

If structured output needs repair turns, those turns appear as additional model
spans.

## Send spans somewhere useful

The sink receives a normal Nim callback, so you can forward each completed span
to your existing logger, metrics collector, or tracing backend. Keep the sink
quick for streaming applications, and handle any I/O or buffering inside your
application.

If the sink itself raises an exception, nimgent ignores that exception and
continues the model operation. Handle delivery failures in the sink when lost
telemetry matters to you.

## Troubleshooting

- **No spans appear:** Pass the sink through `RunCallbacks(trace: trace)` for text, agent, and streaming calls. Pass it through `trace = trace` for embeddings and structured output.
- **The run is missing from the list:** Spans are delivered when they complete. The run span arrives after its child spans.
- **Sensitive data appears in your records:** Check the fields your sink forwards and any conversation or turn IDs you provide.
- **Tracing slows down a stream:** Avoid blocking network or disk writes in the callback, or queue the span for later delivery.

## Next steps

See [Error Handling](/nimgent/guides/error-handling/) for retry behavior, or
[Testing](/nimgent/guides/testing/) for deterministic model calls you can use to test
your tracing code.
