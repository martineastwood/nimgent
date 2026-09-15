---
title: Session
description: Keep a conversation across agent turns and serialize it.
---

Keep an agent conversation across multiple turns with a `Session`.

The session builds the next request from its transcript and records completed
turns. The example serializes that transcript, restores it with the same agent
configuration, and continues the conversation with a follow-up question.

```nim
import std/[asyncdispatch, os]
import nimgent
import nimgent/[agent, session]
import nimgent/providers/openai

type WeatherInput = object
  city: string

let weather = tool("get_weather", "Get the current weather for a city",
  proc (_: ToolContext, input: WeatherInput): string = input.city & ": 16C and cloudy")

let researcher = newAgent(
  model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise assistant. Remember the conversation.",
  tools = @[weather],
  maxSteps = 5)

let conversation = newSession(researcher, id = "weather-demo")

proc main() {.async.} =
  let first = await conversation.runAsync("What's the weather like in Paris?")
  echo "assistant: ", first.text
  echo "session: ", conversation.id
  echo "events: ", conversation.events.len

  # A snapshot contains the transcript and lifecycle state, but not the
  # agent's credentials or tool callbacks. Rehydrate it with the agent.
  let snapshot = conversation.sessionJsonString
  let resumed = sessionFromJson(researcher, snapshot)
  echo "restored session: ", resumed.id

  let second = await resumed.runAsync(
    "Based on that weather, what should I wear? Keep it brief.")
  echo "assistant: ", second.text
  echo "turns: ", resumed.turns
  echo "events after resume: ", resumed.events.len

waitFor main()
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/session.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/session.nim)
