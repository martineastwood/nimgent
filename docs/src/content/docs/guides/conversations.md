---
title: Conversations
description: Keep conversation context across agent runs and restore it later.
---

Use a `Conversation` when an agent needs to remember earlier turns. It stores
prompts, responses, and tool results so you can continue the same thread across
runs, save it, or restore it later.

## Start a conversation

Create an agent, then create one conversation for each independent thread:

```nim
import std/os
import nimgent
import nimgent/[agent, conversation]
import nimgent/providers/openai

let assistant = newAgent(
  openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise assistant.")

let chat = newConversation(assistant, id = "onboarding-demo")

discard chat.run("My name is Ada.")
let response = chat.run("What is my name?")

echo response.text
```

Save the example as `conversation.nim`, then run it with:

```sh
OPENAI_API_KEY=... nim c -r conversation.nim
```

The second call includes the earlier message, so the model can answer "Ada"
without you assembling a message history yourself.

An `Agent` holds reusable setup such as the model, instructions, and tools. A
`Conversation` holds the history for one conversation. You can create many conversations
from the same agent. The id is optional, but setting one helps you correlate a
saved conversation with your application record.

## Use a conversation with tools

Conversations also retain tool results. This is useful when a follow-up depends on a
lookup you already performed. Create the conversation from an agent that has the
tools it needs, then a question such as "What should I wear?" can use an
earlier weather result without calling the weather tool again. See
[Tools and agents](/nimgent/guides/tools-and-agents/) for defining those tools.

## Stream a conversation

Conversations stream in the same way as agents. The completed turn is added to the
conversation after the stream finishes:

```nim
let response = chat.stream(
  "Summarize what we discussed.",
  proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    true)

echo ""
echo response.finishReason
```

Return `false` from the callback to cancel. A cancelled or failed run is not
used as incomplete conversation context in the next request.

## Save and restore a conversation

Use `conversationJsonString` to save a conversation, then restore it with the agent
that should continue it:

```nim
let saved = chat.conversationJsonString
writeFile("conversation.json", saved)

# Later, including after a process restart:
let restored = conversationFromJson(assistant, readFile("conversation.json"))
let response = restored.run("What was my name again?")

echo response.text
```

The saved conversation contains its transcript and state. It does not contain
the agent configuration, API key, or tool handlers, so you always choose what
can run when you restore it.

## Keep only the recent messages

`historyLimit` counts messages, not turns. One turn with tool calls is several
messages: your prompt, the assistant tool call, the tool results, and the final
answer. Set it when each turn should stop sending old messages to the model:

```nim
let chat = newConversation(assistant, historyLimit = 20)
```

Each turn then sends at most the 20 most recent messages. Twenty messages is
roughly ten simple question and answer exchanges, and fewer once tools are
involved.

The window can be larger than the limit, never smaller. It never starts in the
middle of a turn: if the cut lands on a tool result, nimgent widens the window to
include the turn that produced the tool call, so calls stay with their results.

The transcript still keeps every turn, `turns` and `totalUsage` still describe
the whole conversation, and the window is saved and restored with the conversation.
You can change it at any time, and `0` sends the whole transcript again:

```nim
chat.historyLimit = 40
```

Use a window when older context is no longer useful. When the model should
still remember something about older turns, summarize them instead.

## Compact a long conversation

Every conversation run sends the completed history, so a long conversation keeps
growing. A window caps what the model sees; compaction changes the transcript
itself, so a saved conversation stays small. nimgent does not decide when or how
to compact: `messages` gives you the model-facing view of the transcript, and
`replaceEvents` installs what the model should see next. This example summarizes
older turns with a cheaper model and keeps the last few turns verbatim:

```nim
let summarizer = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

# User events are the safe cut points, so tool calls stay with their results.
let starts = chat.userEventIndices
if starts.len > 2:
  let cut = starts[^2]
  let summary = generateText(summarizer,
    messages = chat.events[0 ..< cut].messages,
    system = "Summarize the conversation for future turns. Keep facts and decisions."
  ).text

  chat.replaceEvents(@[ConversationEvent(kind: cekUser,
      message: userMessage("Conversation so far, summarized:\n" & summary))] &
    chat.events[cut .. ^1])
```

`replaceEvents` copies the events you pass and rebuilds `turns`, `totalUsage`,
and `lastResponse` from the new transcript. The next run sends the summary and
the kept events, and the conversation id stays the same. New turn ids keep counting
forward, so they stay unique even though the transcript got shorter.

Always cut at a user event. Slicing inside a turn can start the model input
with an assistant or tool message that has no preceding request.

## Inspect or reset a conversation

You can inspect the number of completed turns, cumulative usage, and the latest
response:

```nim
echo "turns: ", chat.turns
echo "input tokens: ", chat.totalUsage.inputTokens
echo "last answer: ", chat.lastResponse.text
```

Use `reset` when a user starts over. It clears the conversation history and
usage while keeping the agent and conversation id:

```nim
chat.reset()
```

## Troubleshooting and limits

- **The model forgets earlier context:** use the same `Conversation` for each
  related request. Calling `agent.run(...)` directly starts a new request.
- **The conversation grows too large:** set `historyLimit` to cap how many
  messages each turn sends (counted in messages, not turns), or summarize
  older turns with `messages` and `replaceEvents` when the model needs to
  remember them.
- **Restoring fails:** restore with an agent and a conversation JSON document created
  by nimgent. The saved format has a version and rejects incompatible data.
- **Two requests modify the same conversation at once:** serialize access to one
  conversation, or use separate conversations for separate threads.

## Next steps

- [Tools and agents](/nimgent/guides/tools-and-agents/) to give a conversation access to local tools.
- [Streaming](/nimgent/guides/streaming/) to show conversation responses as they arrive.
- [Structured output](/nimgent/guides/structured-output/) to receive validated Nim values.
