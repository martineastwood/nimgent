---
title: Sessions
description: Persist a conversation transcript around a reusable agent.
---

`Session` owns the append-only transcript and derived usage state while the
`Agent` remains reusable configuration:

```nim
import nimgent/[agent, session]

let conversation = newSession(researcher, id = "weather-demo")
let response = conversation.run("What's the weather like in Paris?")
echo response.text
echo conversation.turns
```

Completed turns record user messages, assistant steps, local tool results, and
a final turn event. Failed or cancelled turns remain observable without
polluting the model-facing transcript with incomplete messages.

## Resume from a snapshot

Serialize a session and rehydrate it with the same agent configuration:

```nim
let snapshot = conversation.sessionJsonString
let resumed = sessionFromJson(researcher, snapshot)

let next = resumed.run("What should I wear? Keep it brief.")
```

The snapshot contains conversation state, not credentials or tool callbacks.
Provide the agent again when restoring it.

## Stream a session

Session streaming commits only after the run completes:

```nim
let response = conversation.stream(
  "Summarize the weather.",
  proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
    true)
```

For UIs that need approvals and lifecycle boundaries, use the normalized
`AgentEvent` overload or the pull-based `conversation.events(prompt)` stream.
