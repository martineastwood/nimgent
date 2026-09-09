---
title: Tools and agents
description: Add typed local tools and bounded model-to-tool loops.
---

## Define a typed tool

The generic `tool` helper derives the input schema from a Nim object type:

```nim
type WeatherInput = object
  city: string

let weather = tool(
  "get_weather",
  "Get the current weather for a city",
  proc (_: ToolContext, input: WeatherInput): string =
    input.city & ": 16C and cloudy")
```

nimgent validates tool arguments against the generated JSON Schema before
execution. Invalid arguments and thrown tool exceptions become structured tool
failures that the model can handle.

## Run a bounded agent

`Agent` stores reusable configuration and owns a bounded model → tool → model
loop:

```nim
let researcher = newAgent(
  model,
  instructions = "You are a concise research assistant.",
  tools = @[weather],
  maxSteps = 5)

let response = researcher.run("What's the weather like in Paris?")
echo response.text
```

`maxSteps` is the maximum number of model turns, not the maximum number of
individual tool calls. Use `RunCallbacks` when you need retry, tool, step, or
completion instrumentation.

## Stream normalized agent events

```nim
let response = await researcher.streamAsync(
  "What should I deploy?",
  proc (event: AgentEvent): bool =
    case event.kind
    of aeTextDelta:
      stdout.write event.text
    of aeToolResult:
      echo "tool result: ", event.toolResult.output
    else:
      discard
    true)
```

The normalized callback is useful when a UI needs more than model token
deltas. The existing `StreamCallback` overload remains available for simple
text rendering.

## Require approval

An approval policy returns `tamAllow`, `tamAsk`, or `tamDeny`:

```nim
let researcher = newAgent(
  model,
  tools = @[deleteTool],
  approvalPolicy = proc (_: int, call: ContentBlock, _: Tool): ToolApproval =
    if call.name == "delete_file":
      ToolApproval(mode: tamAsk, reason: "This changes the workspace.")
    else:
      ToolApproval(mode: tamAllow))
```

When a call requires approval, handle `aeToolApprovalRequired` and resolve the
request:

```nim
if event.kind == aeToolApprovalRequired:
  event.approval.approve()
```

Denials are returned to the model as structured `approval_denied` tool
failures. Approval-aware execution is sequential so sibling side effects do
not start while a decision is pending.
