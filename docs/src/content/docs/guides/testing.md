---
title: Testing
description: Run your application against a scripted model instead of a provider.
---

Test your nimgent application without an API key, network connection, or model
budget by using a scripted provider. You define the responses it returns, so
tests stay fast and deterministic while still exercising the same generation,
tool, agent, and structured-output code paths.

## A scripted model

```nim
import std/unittest
import nimgent
import nimgent/testing

suite "summarizer":
  test "returns the model's text":
    let model = scriptedModel(@[textResponse("hello")])
    check generateText(model, prompt = "hi").text == "hello"
```

`scriptedModel(responses)` builds a `LanguageModel` backed by `FakeProvider` and
hands back responses one per call. `textResponse(value, finishReason = frStop,
usage = Usage())` is the shorthand for a plain text reply.

From there, nothing else in your test changes: `generateText`, `streamText`,
agents, conversations, and structured output all run against it exactly as they would
against OpenAI. That is the point — the fake is a provider, not a special mode.

## Assert on what was sent

`FakeProvider` records every `ProviderRequest` it received, which turns "did my
prompt actually say that?" into a normal assertion:

```nim
test "system instructions reach the model":
  let fake = scriptedModel(@[textResponse("ok")])
  discard generateText(fake, prompt = "hi", system = "Be terse.")
  let sent = FakeProvider(fake.provider).requests[0]
  check sent.system == @["Be terse."]
  check sent.messages[0].content[0].text == "hi"
```

`requests[i]` is the request for the *i*-th model call, so a multi-step tool loop
leaves one entry per turn — enough to check that a tool result was fed back, that
middleware added a default, or that history grew the way you expected.

## Scripting multi-step runs

For an agent, the sequence of replies is what drives the loop. Build a tool call
in the first response, plain text in the second:

```nim
type EchoInput = object
  text: string

test "agent runs the tool, then answers":
  var calls = 0
  let echo = tool("echo", "Echo text back",
    proc (_: ToolContext, input: EchoInput): string =
      inc calls
      input.text)

  let model = scriptedModel(@[
    ProviderResponse(content: @[toolUse("call_1", "echo", %*{"text": "hi"})],
      finishReason: frToolUse),
    textResponse("done")])

  check newAgent(model, tools = @[echo], maxSteps = 3).run("go").text == "done"
  check calls == 1
```

`toolUse(id, name, input)` and `toolResult(...)` are the exported constructors for
hand-built content blocks; `finishReason: frToolUse` is what tells nimgent the
model is asking rather than answering. Asserting on your handler's side effects
(`calls`) is usually the highest-value check — it is the part that would hurt if
it ran twice.

## Streaming and structured output

The fake provider implements only `generateAsync`; streaming falls back to the
base implementation, which emits thinking, then text, then tool calls, and
finishes. So a streaming test exercises your callback without a special setup:

```nim
test "deltas arrive":
  let model = scriptedModel(@[textResponse("abc")])
  var seen = ""
  discard streamText(model, prompt = "hi",
    onEvent = proc (event: StreamEvent): bool =
      if event.kind == seTextDelta: seen.add event.text
      true)
  check seen == "abc"
```

Structured output works through the JSON path: the fake has no native
structured-output support, so `omAuto` falls back to extracting JSON from the
text you scripted. That means the value you pass to `textResponse` must be the
JSON the model would have produced:

```nim
test "decodes a typed value":
  let model = scriptedModel(@[textResponse("""{"name":"lasagna","servings":6}""")])
  check generateObject[Recipe](model, prompt = "…").value.servings == 6
```

`omNative` is not testable this way, because there is no native format to speak
of — that is a provider-call concern, not a logic concern.

## What this does not cover

Deliberate omissions, so you know when to reach for a fixture server instead:

- **No HTTP.** Nothing about real request encoding, headers, or streaming wire
  formats is exercised. The repository's own suites use local fixture servers
  for that.
- **One script, one order.** Responses are consumed in sequence; the last one
  repeats if the run asks for more. There is no idle-provider simulation beyond
  that.
- **No failure injection.** To test retry handling, wrap the fake in
  `wrapProvider` and raise from a hook, or build your own `Provider` subtype.
- **No usage realism.** Pass `usage = Usage(inputTokens: …)` to `textResponse`
  when a test asserts on token totals; otherwise they are zero.

Related: [Error Handling](/nimgent/guides/error-handling/) for what to assert
when things go wrong, and [Core API](/nimgent/reference/core-api/) for the response
types the fake produces.
