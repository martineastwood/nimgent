## Chat Completions wire format (OpenRouter, Hyper, OpenAI-compat).

import std/json
import nimgent/[provider, stream]

proc openAiImagePart*(mimeType, data: string): JsonNode =
  %*{"type": "image_url", "image_url": {
    "url": "data:" & mimeType & ";base64," & data}}

proc flushUserContent(result: var JsonNode, parts: var seq[JsonNode]) =
  if parts.len == 0: return
  var hasImage = false
  var textOnly = ""
  for p in parts:
    if p["type"].getStr == "image_url":
      hasImage = true
    elif p["type"].getStr == "text":
      if textOnly.len > 0: textOnly.add "\n"
      textOnly.add p["text"].getStr
  if hasImage:
    var arr = newJArray()
    for p in parts: arr.add p
    result.add %*{"role": "user", "content": arr}
  else:
    result.add %*{"role": "user", "content": %textOnly}
  parts.setLen(0)

proc addUserMessages(result: var JsonNode, message: Message) =
  var parts: seq[JsonNode] = @[]
  for part in message.content:
    case part.kind
    of ckText:
      parts.add %*{"type": "text", "text": part.text}
    of ckImage:
      parts.add openAiImagePart(part.mimeType, part.data)
    of ckToolResult:
      flushUserContent(result, parts)
      result.add %*{"role": "tool", "tool_call_id": part.toolUseId,
        "content": part.output}
      if part.images.len > 0:
        var imgParts = newJArray()
        imgParts.add %*{"type": "text", "text": "(image from tool)"}
        for img in part.images:
          imgParts.add openAiImagePart(img.mimeType, img.data)
        result.add %*{"role": "user", "content": imgParts}
    else:
      discard
  if parts.len > 0:
    flushUserContent(result, parts)
  elif message.content.len == 0:
    result.add %*{"role": "user", "content": ""}

proc keepChatReasoningDetail(item: JsonNode): bool =
  ## Unsigned Anthropic text details 400 on replay. Other types/formats are fine.
  if item.isNil or item.kind != JObject: return false
  if item.getOrDefault("type").getStr != "reasoning.text":
    return true
  if item.getOrDefault("format").getStr != "anthropic-claude-v1":
    return true
  let sig = item.getOrDefault("signature")
  not sig.isNil and sig.kind == JString and sig.getStr.len > 0

proc attachChatThinking(encoded: JsonNode, message: Message, hasToolCalls: bool) =
  ## Replay thinking the Chat Completions hosts expect (OpenRouter / compat).
  var think = ""
  var details = newJArray()
  var hadDetails = false
  for part in message.content:
    if part.kind != ckThinking: continue
    if part.thinking.len > 0:
      if think.len > 0: think.add "\n"
      think.add part.thinking
    if part.signature.len == 0: continue
    try:
      let j = parseJson(part.signature)
      if j.kind != JArray: continue
      hadDetails = true
      for item in j:
        if keepChatReasoningDetail(item):
          details.add item
    except CatchableError:
      discard
  if details.len > 0:
    if think.len > 0:
      encoded["reasoning"] = %think
    encoded["reasoning_details"] = details
  elif think.len > 0 and not hadDetails and not hasToolCalls:
    # ponytail: plaintext-only models. Tool turns without details stay omitted —
    # Claude-via-OpenRouter 400s unsigned thinking on tool follow-up.
    encoded["reasoning"] = %think

proc encodeMessage(result: var JsonNode, message: Message) =
  if message.role == roleUser:
    addUserMessages(result, message)
    return

  var encoded = %*{"role": "assistant"}
  let content = textContent(message.content)
  if content.len > 0:
    encoded["content"] = %content
  else:
    encoded["content"] = newJNull()

  var calls = newJArray()
  for part in message.content:
    if part.kind == ckToolUse:
      calls.add %*{
        "id": part.id,
        "type": "function",
        "function": {
          "name": part.name,
          "arguments": part.input.pretty(0)
        }
      }
  if calls.len > 0:
    encoded["tool_calls"] = calls
  attachChatThinking(encoded, message, calls.len > 0)
  result.add encoded

proc buildChatBody*(request: ProviderRequest, stream: bool,
                    includeSessionId = false, applyCache = false,
                    maxTokensField = "max_completion_tokens"): JsonNode =
  result = %*{
    "model": request.model,
    "messages": newJArray()
  }
  if stream:
    result["stream"] = %true
    result["stream_options"] = %*{"include_usage": true}
  if includeSessionId and request.sessionId.len > 0:
    result["session_id"] = %request.sessionId
  var messages = newJArray()
  if request.maxTokens > 0:
    result[maxTokensField] = %request.maxTokens
  if request.system.len > 0:
    var parts = newJArray()
    for s in request.system:
      parts.add %*{"type": "text", "text": s}
    messages.add %*{"role": "system", "content": parts}
  for message in request.messages:
    encodeMessage(messages, message)
  result["messages"] = messages
  if request.tools.len > 0:
    result["tools"] = newJArray()
    for tool in request.tools:
      result["tools"].add %*{
        "type": "function",
        "function": {
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.inputSchema
        }
      }
  mergeRequestOptions(result, request.options)
  if applyCache:
    applyCacheBreakpoints(result)

proc finishFrom(reason: string): FinishReason =
  case reason
  of "tool_calls": frToolUse
  of "stop": frStop
  of "length": frMaxTokens
  else: frUnknown

proc reasoningFrom(node: JsonNode): string =
  if node.isNil or node.kind != JObject: return
  if "reasoning" in node:
    let r = node["reasoning"]
    if r.kind == JString: result = r.getStr
    elif r.kind == JObject: result = r.getOrDefault("content").getStr
  if result.len == 0 and "reasoning_content" in node and
      node["reasoning_content"].kind == JString:
    result = node["reasoning_content"].getStr

proc reasoningTextFromDetails(details: JsonNode): string =
  if details.isNil or details.kind != JArray: return
  for item in details:
    if item.isNil or item.kind != JObject: continue
    let t = item.getOrDefault("text")
    if not t.isNil and t.kind == JString and t.getStr.len > 0:
      result.add t.getStr
    else:
      let s = item.getOrDefault("summary")
      if not s.isNil and s.kind == JString: result.add s.getStr

proc thinkingFromChat(node: JsonNode): ContentBlock =
  result = ContentBlock(kind: ckThinking, thinking: reasoningFrom(node))
  if node.isNil: return
  let d = node.getOrDefault("reasoning_details")
  if not d.isNil and d.kind == JArray and d.len > 0:
    result.signature = $d
    if result.thinking.len == 0:
      result.thinking = reasoningTextFromDetails(d)

proc mergeChatReasoningDetails(acc: JsonNode, incoming: JsonNode) =
  ## Stream fragments with the same type+index concatenate; later metadata wins.
  if acc.isNil or incoming.isNil or incoming.kind != JArray: return
  for item in incoming:
    if item.isNil or item.kind != JObject: continue
    let idxNode = item.getOrDefault("index")
    let typ = item.getOrDefault("type").getStr
    var merged = false
    if not idxNode.isNil and idxNode.kind == JInt:
      for slot in acc:
        let slotIdx = slot.getOrDefault("index")
        if not slotIdx.isNil and slotIdx.kind == JInt and
            slotIdx.getInt == idxNode.getInt and
            slot.getOrDefault("type").getStr == typ:
          for key, val in item:
            if key in ["text", "summary", "data"] and val.kind == JString:
              let prev = slot.getOrDefault(key)
              if not prev.isNil and prev.kind == JString:
                slot[key] = %(prev.getStr & val.getStr)
              else:
                slot[key] = val
            elif key != "index":
              slot[key] = val
          merged = true
          break
    if not merged:
      acc.add copy(item)

proc parseChatOutput*(data: JsonNode, failPrefix: string): ProviderResponse =
  if "choices" notin data or data["choices"].len == 0:
    raiseProviderError(failPrefix & " response contained no choices")
  result.model = data.getOrDefault("model").getStr
  let message = data["choices"][0]["message"]
  let think = thinkingFromChat(message)
  if think.thinking.len > 0 or think.signature.len > 0:
    result.content.add think
  if "content" in message and message["content"].kind == JString:
    result.content.add text(message["content"].getStr)
  if "tool_calls" in message:
    for call in message["tool_calls"]:
      let function = call["function"]
      result.content.add toolUseFromArgs(call["id"].getStr,
        function["name"].getStr, function["arguments"].getStr)
  if "usage" in data:
    parseOpenAiUsage(data["usage"], result.usage)
  result.finishReason = finishFrom(
    data["choices"][0].getOrDefault("finish_reason").getStr)

proc handleChatEvent*(acc: var StreamAcc, response: var ProviderResponse,
                      data: JsonNode, onEvent: StreamCallback): SseAction =
  if response.model.len == 0:
    response.model = data.getOrDefault("model").getStr
  if "usage" in data and data["usage"].kind == JObject:
    parseOpenAiUsage(data["usage"], response.usage)
  if "choices" notin data or data["choices"].len == 0:
    return sseContinue
  let choice = data["choices"][0]
  let fr = choice.getOrDefault("finish_reason")
  if fr.kind == JString and fr.getStr.len > 0:
    response.finishReason = finishFrom(fr.getStr)
  let delta = choice.getOrDefault("delta")
  if delta.kind != JObject:
    return sseContinue
  if "content" in delta and delta["content"].kind == JString:
    let piece = delta["content"].getStr
    if piece.len > 0:
      acc.text.add piece
      if not onEvent(StreamEvent(kind: seTextDelta, text: piece)):
        return sseCancel
  mergeChatReasoningDetails(acc.details, delta.getOrDefault("reasoning_details"))
  var reason = reasoningFrom(delta)
  if reason.len == 0:
    reason = reasoningTextFromDetails(delta.getOrDefault("reasoning_details"))
  if reason.len > 0:
    acc.think.add reason
    if not onEvent(StreamEvent(kind: seThinkingDelta, text: reason)):
      return sseCancel
  if "tool_calls" in delta:
    for tc in delta["tool_calls"]:
      let idx = tc.getOrDefault("index").getInt
      while acc.tools.len <= idx:
        acc.tools.add PendingTool()
      if "id" in tc and tc["id"].kind == JString:
        acc.tools[idx].id = tc["id"].getStr
      let fn = tc.getOrDefault("function")
      var nameNew = false
      var argsPiece = ""
      if fn.kind == JObject:
        if "name" in fn and fn["name"].kind == JString:
          if acc.tools[idx].name.len == 0:
            nameNew = true
          acc.tools[idx].name = fn["name"].getStr
        if "arguments" in fn and fn["arguments"].kind == JString:
          argsPiece = fn["arguments"].getStr
          acc.tools[idx].args.add argsPiece
      if acc.tools[idx].name.len > 0 and (nameNew or argsPiece.len > 0):
        if not onEvent(StreamEvent(kind: seToolCallDelta,
            toolCallId: acc.tools[idx].id, toolName: acc.tools[idx].name,
            toolArgs: argsPiece)):
          return sseCancel
  sseContinue
