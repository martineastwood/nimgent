---
title: Streaming
description: Show model output as it arrives, while keeping the completed response.
---

Streaming lets your program show a response while the model is still writing
it. Use it for command-line tools, chat interfaces, and any task where waiting
for the full answer would feel slow.

## Stream text

`streamText` calls your callback as text arrives, then returns the complete
response when the stream finishes:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = streamText(
  model,
  prompt = "Explain why the sky is blue in one paragraph.",
  onEvent = proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    true)

echo ""
echo "Finished: ", response.finishReason
```

Save the example as `stream.nim`, then run it with:

```sh
OPENAI_API_KEY=... nim c -r -d:ssl stream.nim
```

Return `true` from the callback to continue streaming. `response.text` contains
the complete answer after `streamText` returns, and `response.usage` contains
the reported token counts.

## Cancel a stream

Return `false` from the callback when your application wants to stop. nimgent
then raises `CancelledError`:

```nim
var stopRequested = false

try:
  discard streamText(
    model,
    prompt = "Write a long story.",
    onEvent = proc (event: StreamEvent): bool =
      if event.kind == seTextDelta:
        stdout.write event.text
      not stopRequested)
except CancelledError:
  echo "\nStopped."
```

Set `stopRequested` from your UI, signal handler, or surrounding application.
Keep stream callbacks short so rendering or other slow work does not delay the
next event.

## Handle more than text

Most programs only need `seTextDelta`. When you stream a request with tools,
you can also show progress as the model prepares a tool call:

```nim
let response = streamText(
  model,
  prompt = "Should I bring an umbrella to Paris?",
  tools = @[weather],
  maxSteps = 5,
  onEvent = proc (event: StreamEvent): bool =
    case event.kind
    of seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    of seToolCallDelta:
      echo "\nCalling ", event.toolName
    else:
      discard
    true)
```

`seThinkingDelta` is available when a provider returns visible reasoning.
`seToolCallDelta` contains tool-call progress, so use it to update your UI
rather than to run a tool yourself. See [Tools and agents](/guides/tools-and-agents/)
to define `weather` and other local tools.

## Stream asynchronously

Use `streamTextAsync` in servers and applications that already run Nim's event
loop:

```nim
import std/[asyncdispatch, os]
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

proc main() {.async.} =
  let response = await streamTextAsync(
    model,
    prompt = "Write a short haiku.",
    onEvent = proc (event: StreamEvent): bool =
      if event.kind == seTextDelta:
        stdout.write event.text
      true)
  echo "\nFinished: ", response.finishReason

waitFor main()
```

Use `streamText` for scripts and command-line programs. Do not call the
blocking helper from inside an existing async event loop.

## Stream an agent

An agent streams with the same callback shape. This is useful when you want to
show both the answer and the tools it is using:

```nim
let response = researcher.stream(
  "Plan a picnic in Paris.",
  proc (event: StreamEvent): bool =
    case event.kind
    of seTextDelta:
      stdout.write event.text
    of seToolCallDelta:
      echo "\nCalling ", event.toolName
    else:
      discard
    true)
```

`researcher` can be any `Agent` you created with `newAgent`. The callback above
receives only model deltas. Use the pull-based event API when your interface
also needs approval requests, run boundaries, tool results, or errors.

## Observe the full agent lifecycle

`events` starts an agent run in the background and lets you read lifecycle
events from a queue. This is a good fit for chat UIs, approval dialogs, and
event loops that already process other input:

```nim
import std/[asyncdispatch, os]
import nimgent/agent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let researcher = newAgent(model, instructions = "Be concise.")

let events = researcher.events("Plan a picnic in Paris.")
while true:
  let item = waitFor events.read()
  if not item[0]: break
  let event = item[1]
  case event.kind
  of aeTextDelta:
    stdout.write event.text
  of aeToolCall:
    echo "\nCalling ", event.call.name
  of aeToolResult:
    echo "\nTool finished in ", event.durationMs, "ms"
  of aeRunFinish:
    echo "\nDone: ", event.response.finishReason
  else:
    discard

let response = waitFor events.result
```

`read` returns `(false, _)` when the stream closes. `events.result` completes
with the final `ProviderResponse` or raises the same error that ended the run.

| Event | When it arrives |
| --- | --- |
| `aeRunStart` | The run begins. |
| `aeStepStart` | A new model step starts. |
| `aeTextDelta` / `aeThinkingDelta` | Text or reasoning arrives. |
| `aeToolCall` | The model requested a tool. |
| `aeToolApprovalRequired` | A tool is waiting for approval. |
| `aeToolResult` | A tool finished. |
| `aeStepFinish` | A model step completed. |
| `aeRunFinish` | The run completed successfully. |
| `aeError` | The run failed. |

You can also call `model.events(...)` on a `LanguageModel` or `chat.events(...)`
on a `Conversation` when you are not using an `Agent` wrapper. See
[Agent events](/examples/agent-events/) for approval handling.

## Cancel while waiting on the provider

Streaming checks cancellation between events, but a provider may block for a
long time before the next chunk arrives. Pass `wakeFd` with a readable file
descriptor, such as a pipe or eventfd, and nimgent emits `seWake` events while
waiting so your callback can return `false` promptly:

```nim
import std/posix

var stopRequested = false
var fds: array[2, cint]
pipe(fds)
let wakeFd = fds[0]

discard streamText(
  model,
  prompt = "Write a long story.",
  wakeFd = wakeFd,
  onEvent = proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
    elif event.kind == seWake and stopRequested:
      return false
    true)
```

Write one byte to the write end of the pipe when your UI or signal handler
wants the stream to notice cancellation. This is most useful in interactive
applications that already multiplex other input alongside model output.

## Troubleshooting

- **Nothing appears until the end:** write `seTextDelta` text to your output
  and call `flushFile(stdout)` for a command-line program.
- **The stream stops unexpectedly:** returning `false` raises `CancelledError`.
- **A callback makes streaming sluggish:** move slow rendering, parsing, or
  database work outside the callback.
- **Your provider does not stream:** handle the provider error and offer a
  non-streaming fallback if your application needs one.

## Next steps

- [Tools and agents](/guides/tools-and-agents/) to stream tool-using runs.
- [Structured output](/guides/structured-output/) to stream a validated object.
- [Conversations](/guides/conversations/) to keep a conversation across runs.
- [Providers](/guides/providers/) to choose and configure a provider.
