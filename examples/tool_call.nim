## Tool-call example — the model asks for weather, a local function answers.
##
##   OPENAI_API_KEY=... nim c -r examples/tool_call.nim

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
