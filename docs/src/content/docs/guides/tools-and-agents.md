---
title: Tools and agents
description: Let a model call your Nim code, then reuse that setup as an agent.
---

Tools let a model ask your application to look up data, call an API, or perform
another action before it answers. You can use a tool for one `generateText`
request, then create an `Agent` when the same model, instructions, and tools
should be reused across many requests.

## Call a typed tool

Start with a typed input and a handler. nimgent uses the input type to tell the
model what arguments the tool accepts:

Typed inputs keep the contract in one place. nimgent derives the JSON Schema
the model sees and decodes the arguments into `WeatherInput` before calling
your handler, so you can use `input.city` directly instead of parsing JSON by
hand. Invalid or missing fields become tool errors that the model can respond
to.

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

Save the example as `weather.nim`, then run it with:

```sh
OPENAI_API_KEY=... nim c -r weather.nim
```

The model decides whether to call `get_weather`. When it does, your handler
receives a `WeatherInput`, returns a result, and the model uses that result to
finish its answer.

`maxSteps` limits how many model steps this request can take. Set it above `1`
when a local tool should run and the model should continue with its result. The
limit prevents an accidental tool loop from running forever.

## Write useful tools

The tool name and description tell the model when to use the tool. Describe the
task, expected input, and important limits. For example: "Get the current
weather for a city. Returns temperature and conditions. Use this for current
conditions, not forecasts."

Return a Nim object when the model needs several related values:

```nim
type ForecastInput = object
  city: string

type Forecast = object
  city: string
  celsius: float
  raining: bool

let forecast = tool(
  "get_forecast",
  "Get a forecast for a city.",
  proc (_: ToolContext, input: ForecastInput): Forecast =
    Forecast(city: input.city, celsius: 16.0, raining: false))
```

nimgent serializes the returned value for the model. Your handler receives only
inputs that match the declared type.

## Handle tool failures

Tool errors become results the model can read. This lets it retry with different
arguments or explain the problem to the user instead of ending the whole run.

Return `toolFailure` when your application knows why a request cannot succeed:

```nim
import std/json
import nimgent

type LookupInput = object
  city: string

let supportedForecast = tool(
  "get_forecast",
  "Get a forecast for a supported city.",
  proc (_: ToolContext, input: LookupInput): ToolResult =
    if input.city != "Paris":
      return toolFailure(
        "unknown_city",
        "No forecast is available for " & input.city & ". Try Paris.",
        %*{"city": input.city},
        retryable = false)
    ToolResult(output: "Paris: 16C and cloudy"))
```

If a handler raises an exception or the model supplies invalid arguments,
nimgent also returns a tool failure to the model. Use exceptions for unexpected
problems and `toolFailure` for expected application outcomes.

## Make a reusable agent

Use an `Agent` when several requests need the same model, instructions, and
tools. It saves you from passing that setup to every call:

```nim
import nimgent/agent

let researcher = newAgent(
  model,
  instructions = "You are a concise research assistant.",
  tools = @[weather],
  maxSteps = 5)

let paris = researcher.run("What's the weather like in Paris?")
let tokyo = researcher.run("What's the weather like in Tokyo?")

echo paris.text
echo tokyo.text
```

Each `researcher.run(...)` call gets its own `maxSteps` limit. You can reuse the
agent as often as you need. Use a [Session](/nimgent/guides/sessions/) when later runs
should remember earlier messages and tool results.

### Choose how tools are used

By default, the model decides whether to call a tool. Set `toolChoice` when a
task requires a different rule:

```nim
let weatherOnly = newAgent(
  model,
  tools = @[weather],
  toolChoice = toolChoiceSpecific("get_weather"))
```

| Choice | Effect |
| --- | --- |
| `toolChoiceAuto()` | The model decides, this is the default. |
| `toolChoiceRequired()` | The model must call one of the available tools. |
| `toolChoiceSpecific("get_weather")` | The model must call the named tool. |
| `toolChoiceNone()` | The model answers without seeing tools. |

## Stream an agent run

Use `stream` to display text as it arrives. You still receive the complete
response when the run finishes:

```nim
import std/[os, strutils]

let response = researcher.stream(
  "Plan a picnic in Paris.",
  proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    true)

echo ""
echo response.finishReason
```

See [Streaming](/nimgent/guides/streaming/) when your UI also needs tool-call updates
or cancellation.

## Ask for approval before a tool runs

Use `approvalPolicy` for actions that need a person to approve them. Return
`tamAsk` for calls that should pause, `tamAllow` for safe calls, or `tamDeny`
to reject a call immediately. For an existing `deleteFile` tool in your
application:

```nim
let cleaner = newAgent(
  model,
  tools = @[deleteFile],
  approvalPolicy = proc (_: int, call: ContentBlock, _: Tool): ToolApproval =
    if call.name == "delete_file":
      ToolApproval(mode: tamAsk, reason: "This deletes a file.")
    else:
      ToolApproval(mode: tamAllow))
```

When a call needs approval, `cleaner.events(...)` emits
`aeToolApprovalRequired`. Call `event.approval.approve()` or
`event.approval.deny()` from your event handler. No tool from that batch runs
until you decide.

## Use provider-hosted tools

Some providers can run tools such as web search themselves. Declare one with
`hostedTool`; it has no local Nim handler:

```nim
import std/os
import nimgent
import nimgent/providers/google

let model = google(getEnv("GEMINI_API_KEY")).model("gemini-3.5-flash-lite")
let response = generateText(
  model,
  prompt = "Find the Nim language homepage.",
  tools = @[hostedTool("web_search")],
  maxSteps = 3)

echo response.text
```

Hosted tools vary by provider and model. Handle a provider error if the selected
model does not offer the hosted tool you request.

## Troubleshooting

- **The model does not call a tool:** generally, this means you need to make the tool's description
more specific so the model has a better understanding of when to call it. Use
  `toolChoiceRequired()` or `toolChoiceSpecific(...)` when a tool is mandatory.
- **The model stops after calling a tool:** set `maxSteps` above `1` so it can
  continue with the tool result.
- **A tool receives unexpected input:** make the input type and description
  match the values your handler accepts.
- **A sensitive action ran unexpectedly:** add an `approvalPolicy` before you
  expose that tool to the model.

## Next steps

- [Sessions](/nimgent/guides/sessions/) to keep a conversation across agent runs.
- [Streaming](/nimgent/guides/streaming/) to render responses while they are generated.
- [Structured output](/nimgent/guides/structured-output/) to receive validated Nim values.
- [Providers](/nimgent/guides/providers/) to configure provider-specific features.
