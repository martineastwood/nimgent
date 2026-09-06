## Tool-call example — the model asks for weather, a local function answers.
##
##   OPENAI_API_KEY=... nim c -r examples/tool_call.nim

import std/[json, os]
import nimgent
import nimgent/openai

let provider = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))

let weather = tool("get_weather", "Get the current weather for a city",
  %*{"type": "object",
     "properties": {"city": {"type": "string"}},
     "required": ["city"]},
  proc (input: JsonNode): ToolOutput =
    ToolOutput(output: "16C and cloudy"))

echo "calling the model..."
let response = generateText(
  provider,
  model = "gpt-4o-mini",
  prompt = "What's the weather like in Paris?",
  tools = @[weather],
  maxSteps = 5)

echo response.textContent
