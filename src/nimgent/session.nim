## In-memory conversation state for reusable agents.
##
## A Session owns the transcript and usage for one conversation. Agent remains
## immutable configuration; a session can be used for independent runs and is
## not safe for concurrent mutation from multiple callers.

import std/[asyncdispatch, json]
import nimgent
import nimgent/agent

type
  Session* = ref object
    ## Agent configuration used for each turn.
    agent*: Agent
    ## Provider-neutral transcript, including assistant tool calls and local
    ## tool results needed to replay the conversation.
    messages*: seq[Message]
    turns*: int
    totalUsage*: Usage
    lastResponse*: ProviderResponse

  ## Conversation is the descriptive alias for Session.
  Conversation* = Session

proc copyBlock(part: ContentBlock): ContentBlock =
  result = part
  if not part.googlePart.isNil:
    result.googlePart = copy(part.googlePart)
  case part.kind
  of ckToolUse:
    if not part.input.isNil: result.input = copy(part.input)
  of ckFile:
    result.file = part.file
  of ckSource:
    if not part.source.raw.isNil:
      result.source.raw = copy(part.source.raw)
  else:
    discard

proc copyMessages(messages: openArray[Message]): seq[Message] =
  ## Keep the agent's internal tool-loop mutations isolated from the session.
  for message in messages:
    var copied = Message(role: message.role)
    for part in message.content:
      copied.content.add copyBlock(part)
    result.add copied

proc newSession*(agent: Agent, messages: seq[Message] = @[]): Session =
  ## Create an empty session, or continue from an existing transcript.
  if agent.isNil:
    raiseProviderError("session agent must not be nil")
  Session(agent: agent, messages: copyMessages(messages))

proc newConversation*(agent: Agent, messages: seq[Message] = @[]): Conversation =
  ## Descriptive alias for `newSession`.
  newSession(agent, messages)

proc commit(session: Session, prompt: string, response: ProviderResponse) =
  if prompt.len > 0:
    session.messages.add userMessage(prompt)
  for step in response.steps:
    session.messages.add assistantMessage(step.content)
    if step.toolResults.len > 0:
      session.messages.add userMessage(step.toolResults)
  inc session.turns
  session.totalUsage.addUsage(response.totalUsage)
  session.lastResponse = response

proc requestMessages(session: Session, prompt: string): seq[Message] =
  result = copyMessages(session.messages)
  result.add userMessage(prompt)

proc runAsync*(session: Session, prompt: string,
               abort: AbortCheck = nil,
               callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Run one user turn and append its complete model/tool transcript.
  if session.isNil:
    raiseProviderError("session must not be nil")
  if prompt.len == 0:
    raiseProviderError("session prompt must not be empty")
  let response = await session.agent.runAsync(
    messages = session.requestMessages(prompt), abort = abort,
    callbacks = callbacks)
  session.commit(prompt, response)
  return response

proc run*(session: Session, prompt: string,
          abort: AbortCheck = nil,
          callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `runAsync`.
  waitFor session.runAsync(prompt, abort, callbacks)

proc streamAsync*(session: Session, prompt: string, onEvent: StreamCallback,
                  abort: AbortCheck = nil,
                  callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Stream one user turn and append its transcript after successful completion.
  if session.isNil:
    raiseProviderError("session must not be nil")
  if prompt.len == 0:
    raiseProviderError("session prompt must not be empty")
  if onEvent.isNil:
    raiseProviderError("session stream callback must not be nil")
  let response = await session.agent.streamAsync("", onEvent,
    messages = session.requestMessages(prompt), abort = abort,
    callbacks = callbacks)
  session.commit(prompt, response)
  return response

proc stream*(session: Session, prompt: string, onEvent: StreamCallback,
             abort: AbortCheck = nil,
             callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `streamAsync`.
  waitFor session.streamAsync(prompt, onEvent, abort, callbacks)

proc reset*(session: Session) =
  ## Clear the transcript, counters, and last response while retaining the agent.
  if session.isNil:
    raiseProviderError("session must not be nil")
  session.messages = @[]
  session.turns = 0
  session.totalUsage = Usage()
  session.lastResponse = ProviderResponse()
