## Agent conversation example - keep a conversation across multiple agent turns.
##
##   OPENAI_API_KEY=... nim c -r examples/conversation.nim

import std/[asyncdispatch, os]
import nimgent
import nimgent/[agent, conversation]
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

# `historyLimit` counts messages, not turns, so a turn with tool calls uses
# several. The transcript keeps every turn, so the conversation can still be saved
# in full.
let chat = newConversation(researcher, id = "weather-demo", historyLimit = 20)

proc main() {.async.} =
  let first = await chat.runAsync("What's the weather like in Paris?")
  echo "assistant: ", first.text
  echo "conversation: ", chat.id
  echo "events: ", chat.events.len

  # A snapshot contains the transcript and lifecycle state, but not the
  # agent's credentials or tool callbacks. Rehydrate it with the agent.
  let snapshot = chat.conversationJsonString
  let resumed = conversationFromJson(researcher, snapshot)
  echo "restored conversation: ", resumed.id

  let second = await resumed.runAsync(
    "Based on that weather, what should I wear? Keep it brief.")
  echo "assistant: ", second.text
  echo "turns: ", resumed.turns
  echo "events after resume: ", resumed.events.len

  # Compaction is application policy. Summarize the older turns, keep the most
  # recent turn verbatim, and replace the transcript so it stops growing.
  let summarizer = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
  let cut = resumed.userEventIndices[^1]
  let summary = (await generateTextAsync(summarizer,
    messages = resumed.events[0 ..< cut].messages,
    system = "Summarize the conversation for future turns.")).text
  resumed.replaceEvents(@[ConversationEvent(kind: cekUser,
      message: userMessage("Conversation so far, summarized:\n" & summary))] &
    resumed.events[cut .. ^1])
  echo "events after compaction: ", resumed.events.len
  echo "turns after compaction: ", resumed.turns

waitFor main()
