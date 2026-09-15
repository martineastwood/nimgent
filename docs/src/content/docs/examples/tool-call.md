---
title: Tool call
description: Let a model call a typed local function.
---

Give a model a local function it can call to answer a question.

`tool` derives the input schema from `WeatherInput` and connects the schema to a
Nim callback. `generateText` runs the callback when the model requests the tool,
then continues the model turn because `maxSteps` is greater than `1`.

```nim
import std/[json, os]
import nimgent
import nimgent/providers/openai

type WeatherInput = object
  city: string

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

let weather = tool("get_weather", "Get the current weather for a city",
  proc (_: ToolContext, input: WeatherInput): string = input.city & ": 16C and cloudy")

echo "calling the model..."
let response = generateText(
  model,
  prompt = "What's the weather like in Paris?",
  tools = @[weather],
  maxSteps = 5)

echo response.text
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/tool_call.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/tool_call.nim)
