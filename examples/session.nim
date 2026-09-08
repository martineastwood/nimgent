## Agent session example — keep a conversation across multiple agent turns.
##
##   OPENAI_API_KEY=... nim c -r examples/session.nim

import std/[asyncdispatch, os]
import nimgent
import nimgent/[agent, openai, session]

type WeatherInput = object
  city: string

let weather = tool("get_weather", "Get the current weather for a city",
  proc (input: WeatherInput): string = input.city & ": 16C and cloudy")

let researcher = newAgent(
  model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise assistant. Remember the conversation.",
  tools = @[weather],
  maxSteps = 5)

let conversation = newSession(researcher)

proc main() {.async.} =
  let first = await conversation.runAsync("What's the weather like in Paris?")
  echo "assistant: ", first.text

  let second = await conversation.runAsync(
    "Based on that weather, what should I wear? Keep it brief.")
  echo "assistant: ", second.text
  echo "turns: ", conversation.turns

waitFor main()
