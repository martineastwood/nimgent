## First-class Agent example — reusable configuration plus a typed local tool.
##
##   OPENAI_API_KEY=... nim c -r examples/agent.nim

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
