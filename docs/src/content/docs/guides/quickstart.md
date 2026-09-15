---
title: Quickstart
description: Send your first model request and build a small tool-using agent.
---

Use nimgent to send a prompt to a language model, then add typed tools when your
application needs to do more than return text.

## Install

Install nimgent with Nimble and set an API key for the provider you want to use:

```sh
nimble install nimgent
export OPENAI_API_KEY=...
```

This guide uses OpenAI. See [Providers](/guides/providers/) for the other
supported providers and their constructors.

## Send your first request

Create `hello.nim`:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(model, prompt = "Say hello in one sentence.")

echo response.text
```

Run it with:

```sh
nim c -r hello.nim
```

The three pieces are:

- `openAI(...)` reads your API key and selects OpenAI.
- `.model("gpt-4o-mini")` selects the model to call.
- `generateText(...)` sends the prompt and returns the response.

The generated text is in `response.text`. You can also inspect
`response.finishReason` and token counts in `response.usage`.

### Add instructions

Use `system` for instructions that should apply across the request:

```nim
let response = generateText(
  model,
  system = "You are a concise systems programmer.",
  prompt = "Explain what a file descriptor is.")

echo response.text
```

Keep the system instructions focused on the model's role and behavior. Put the
actual question or task in `prompt`.

## Call a tool with generateText

For a one-off task, pass local tools directly to `generateText`. The model can
call a tool, read its result, then write its answer in the same request:

```nim
import std/os
import nimgent
import nimgent/providers/openai

type WeatherInput = object
  city: string

let weather = tool(
  "get_weather",
  "Return a sample weather report for a city.",
  proc (_: ToolContext, input: WeatherInput): string =
    input.city & ": 16C and cloudy")

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(
  model,
  prompt = "Should I bring an umbrella to Paris?",
  tools = @[weather],
  maxSteps = 5)

echo response.text
```

The `WeatherInput` type describes the tool's input. The model can request
`get_weather` with a city, your handler runs, and the result is sent back so the
model can finish its answer.

`maxSteps` limits how many model steps one request can take. The
limit prevents an accidental tool loop from running forever.

## Make a simple agent

Use an `Agent` when you want to reuse the same model, instructions, and tools
across many requests. It keeps the setup in one value, so each call only needs
the new task.

Add `nimgent/agent` to the imports above, then replace the `generateText` call
with this:

```nim
let researcher = newAgent(
  model,
  instructions = "You are a concise research assistant.",
  tools = @[weather],
  maxSteps = 5)

let first = researcher.run("What's the weather like in Paris?")
let second = researcher.run("What's the weather like in Tokyo?")

echo first.text
echo second.text
```

## Keep a conversation with a session

Without a session, each agent run starts fresh. Use a session when a follow-up
question needs the earlier prompt, answer, or tool result:

```nim
import nimgent/session

let conversation = newSession(researcher)
discard conversation.run("What's the weather like in Paris?")
let response = conversation.run("What should I wear?")

echo response.text
```

The second request includes the earlier weather result, so the model can answer
the follow-up without asking for the city again. See [Sessions](/guides/sessions/)
to persist or inspect a conversation.

## Use nimgent asynchronously

The `Async` form fits servers and applications that already use Nim's event
loop:

```nim
import std/[asyncdispatch, os]
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

proc main() {.async.} =
  let response = await generateTextAsync(model, prompt = "Say hello.")
  echo response.text

waitFor main()
```

Use the blocking helpers for scripts and command-line programs. Do not call
them from inside an existing async event loop.

## Use another provider

The request and agent code stays the same when you switch providers. Change the
import, constructor, API key, and model id:

```nim
import std/os
import nimgent
import nimgent/providers/anthropic

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
let response = generateText(model, prompt = "Say hello.")

echo response.text
```

## Where to go next

- [Providers](/guides/providers/): choose a provider and configure its options.
- [Streaming](/guides/streaming/): display text as it arrives.
- [Tools and agents](/guides/tools-and-agents/): handle richer tools, failures, and approvals.
- [Structured output](/guides/structured-output/): receive validated Nim values.
- [Sessions](/guides/sessions/): keep a transcript across runs.
