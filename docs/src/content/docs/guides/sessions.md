---
title: Sessions
description: Keep conversation context across agent runs and restore it later.
---

Use a session when one request should remember an earlier request. A session
keeps the conversation transcript for one agent, so follow-up questions can use
earlier prompts, answers, and tool results.

## Start a conversation

Create an agent, then create one session for each conversation:

```nim
import std/os
import nimgent
import nimgent/[agent, session]
import nimgent/providers/openai

let assistant = newAgent(
  openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise assistant.")

let conversation = newSession(assistant, id = "onboarding-demo")

discard conversation.run("My name is Ada.")
let response = conversation.run("What is my name?")

echo response.text
```

Save the example as `conversation.nim`, then run it with:

```sh
OPENAI_API_KEY=... nim c -r conversation.nim
```

The second call includes the earlier message, so the model can answer "Ada"
without you assembling a message history yourself.

An `Agent` holds reusable setup such as the model, instructions, and tools. A
`Session` holds the history for one conversation. You can create many sessions
from the same agent. The id is optional, but setting one helps you correlate a
saved conversation with your application record.

## Use a session with tools

Sessions also retain tool results. This is useful when a follow-up depends on a
lookup you already performed. Create the session from an agent that has the
tools it needs, then a question such as "What should I wear?" can use an
earlier weather result without calling the weather tool again. See
[Tools and agents](/nimgent/guides/tools-and-agents/) for defining those tools.

## Stream a conversation

Sessions stream in the same way as agents. The completed turn is added to the
conversation after the stream finishes:

```nim
let response = conversation.stream(
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

## Save and restore a session

Use `sessionJsonString` to save a conversation, then restore it with the agent
that should continue it:

```nim
let saved = conversation.sessionJsonString
writeFile("conversation.json", saved)

# Later, including after a process restart:
let restored = sessionFromJson(assistant, readFile("conversation.json"))
let response = restored.run("What was my name again?")

echo response.text
```

The saved session contains the conversation and its state. It does not contain
the agent configuration, API key, or tool handlers, so you always choose what
can run when you restore it.

## Inspect or reset a session

You can inspect the number of completed turns, cumulative usage, and the latest
response:

```nim
echo "turns: ", conversation.turns
echo "input tokens: ", conversation.totalUsage.inputTokens
echo "last answer: ", conversation.lastResponse.text
```

Use `reset` when a user starts over. It clears the conversation history and
usage while keeping the agent and session id:

```nim
conversation.reset()
```

## Troubleshooting and limits

- **The model forgets earlier context:** use the same `Session` for each
  related request. Calling `agent.run(...)` directly starts a new request.
- **The conversation grows too large:** each session run includes completed
  history, so long conversations use more context. Reset the session or start
  a new conversation when the old history is no longer useful.
- **Restoring fails:** restore with an agent and a session JSON document created
  by nimgent. The saved format has a version and rejects incompatible data.
- **Two requests modify the same session at once:** serialize access to one
  session, or use separate sessions for separate conversations.

## Next steps

- [Tools and agents](/nimgent/guides/tools-and-agents/) to give a session access to local tools.
- [Streaming](/nimgent/guides/streaming/) to show session responses as they arrive.
- [Structured output](/nimgent/guides/structured-output/) to receive validated Nim values.
