---
title: Agent
description: Reuse model, instructions, tools, and limits with an agent.
---

Create a reusable agent that can call a typed local tool and finish the answer.

`newAgent` stores the model, instructions, tool list, and `maxSteps` limit in one
place. Each call to `runAsync` then starts a fresh run with those defaults, and
the response reports how many model steps were used.

```nim
import std/[asyncdispatch, os]
import nimgent
import nimgent/agent
import nimgent/providers/openai

type WeatherInput = object
  city: string

let weather: Tool = tool("get_weather", "Get the current weather for a city",
  proc (_: ToolContext, input: WeatherInput): string = input.city & ": 16C and cloudy")

let researcher: Agent = newAgent(
  model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise research assistant.",
  tools = @[weather],
  maxSteps = 5)

proc main() {.async.} =
  echo "running agent..."
  let response: ProviderResponse = await researcher.runAsync("What's the weather like in Paris?")
  echo response.text
  echo "steps: ", response.steps.len

waitFor main()
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/agent.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/agent.nim)
