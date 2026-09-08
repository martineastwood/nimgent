## Shared OpenAI-family runtime: SSE, wake-fd, stream accumulation, usage JSON.

import std/[asyncdispatch, asyncstreams, json, strutils]
import nimgent/provider

type
  SseAction* = enum
    sseContinue
    sseStop
    sseCancel

  SseDrive* = enum
    sdEnded      ## [DONE] or handle sseStop
    sdCancelled
    sdClosed     ## body ended without a terminal

  WakeWatch* = object
    fd: cint = -1

  PendingTool* = object
    id*: string
    name*: string
    args*: string
    itemId*: string

  StreamAcc* = object
    text*: string
    think*: string
    details*: JsonNode
    tools*: seq[PendingTool]
    parsedFinal*: bool

proc initStreamAcc*(): StreamAcc =
  StreamAcc(details: newJArray())

proc parseOpenAiUsage*(usage: JsonNode, result: var Usage) =
  ## Chat Completions (`prompt_tokens`) and Responses (`input_tokens`) usage.
  if usage.isNil or usage.kind != JObject: return
  result.inputTokens = usage.getOrDefault("prompt_tokens").getInt
  if result.inputTokens == 0:
    result.inputTokens = usage.getOrDefault("input_tokens").getInt
  result.outputTokens = usage.getOrDefault("completion_tokens").getInt
  if result.outputTokens == 0:
    result.outputTokens = usage.getOrDefault("output_tokens").getInt
  var details = usage.getOrDefault("prompt_tokens_details")
  if details.isNil or details.kind != JObject:
    details = usage.getOrDefault("input_tokens_details")
  if details.isNil or details.kind != JObject:
    return
  result.cacheReadTokens = details.getOrDefault("cached_tokens").getInt
  result.cacheWriteTokens = details.getOrDefault("cache_write_tokens").getInt
  result.cacheReported = ("cached_tokens" in details) or
    ("cache_write_tokens" in details)

proc popLine*(buf: var string): tuple[ok: bool, line: string] =
  let nl = buf.find('\n')
  if nl < 0: return (false, "")
  var line = buf[0 ..< nl]
  buf = buf[nl + 1 .. ^1]
  if line.len > 0 and line[^1] == '\r':
    line.setLen(line.len - 1)
  (true, line)

proc register*(w: var WakeWatch, wakeFd: cint) =
  if w.fd >= 0: return
  if wakeFd < 0: return
  try:
    register(AsyncFD(wakeFd))
  except CatchableError:
    return
  w.fd = wakeFd

proc unregister*(w: var WakeWatch) =
  if w.fd < 0: return
  let fd = w.fd
  w.fd = -1
  try:
    unregister(AsyncFD(fd))
  except CatchableError:
    discard
  except Defect:
    # kqueue: unregister of a missing fd is AssertionDefect, not CatchableError.
    discard

proc waitWakeOnce(watch: var WakeWatch, wakeFd: cint): Future[void] =
  result = newFuture[void]("wakeFd")
  watch.register(wakeFd)
  if watch.fd < 0: return
  let afd = AsyncFD(watch.fd)
  var fut = result
  addRead(afd, proc (s: AsyncFD): bool =
    if not fut.finished:
      fut.complete()
    false)

proc awaitWithWakeAsync*[T](fut: Future[T], watch: ptr WakeWatch, wakeFd: cint,
                            onEvent: StreamCallback): Future[bool] {.async.} =
  ## Check cancellation even when another input poller has consumed wakeFd.
  var wake: Future[void]
  while not fut.finished:
    if wakeFd >= 0 and (wake.isNil or wake.finished):
      wake = waitWakeOnce(watch[], wakeFd)
    if wake.isNil:
      await fut or sleepAsync(100)
    else:
      await fut or wake or sleepAsync(100)
    if fut.finished:
      watch[].unregister()
      break
    if not onEvent(StreamEvent(kind: seWake)):
      watch[].unregister()
      return false
  true

proc drainBodyStreamAsync*(bodyStream: FutureStream[string]): Future[string] {.async.} =
  while true:
    let (more, chunk) = await bodyStream.read()
    if not more: break
    result.add chunk

proc forEachSseAsync*(
  bodyStream: FutureStream[string],
  watch: ptr WakeWatch,
  wakeFd: cint,
  onEvent: StreamCallback,
  handle: proc (data: JsonNode): SseAction {.closure.}
): Future[SseDrive] {.async.} =
  var buf = ""
  while true:
    let readFut = bodyStream.read()
    if not await awaitWithWakeAsync(readFut, watch, wakeFd, onEvent):
      return sdCancelled
    let (more, chunk) = await readFut
    if more: buf.add chunk
    elif buf.len > 0: buf.add '\n'
    while true:
      let (ok, line) = popLine(buf)
      if not ok: break
      if line.len == 0 or not line.startsWith("data:"): continue
      let payload = line[5 .. ^1].strip
      if payload == "[DONE]": return sdEnded
      var data: JsonNode
      try: data = parseJson(payload)
      except CatchableError: continue
      case handle(data)
      of sseStop: return sdEnded
      of sseCancel: return sdCancelled
      of sseContinue: discard
    if not more: return sdClosed

proc assembleStream*(acc: StreamAcc, response: var ProviderResponse) =
  if acc.parsedFinal: return
  if acc.think.len > 0 or acc.details.len > 0:
    response.content.add ContentBlock(kind: ckThinking, thinking: acc.think,
      signature: if acc.details.len > 0: $acc.details else: "")
  if acc.text.len > 0:
    response.content.add text(acc.text)
  for t in acc.tools:
    if t.name.len == 0: continue
    let id = if t.id.len > 0: t.id else: "call_" & t.name
    response.content.add toolUseFromArgs(id, t.name, t.args)
    if response.finishReason == frUnknown:
      response.finishReason = frToolUse
