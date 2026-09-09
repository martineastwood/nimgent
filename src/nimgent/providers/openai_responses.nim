## Native OpenAI Responses API wire format.

import std/[json, strutils]
import nimgent/providers/[provider, stream]

proc responsesImagePart(mimeType, data: string): JsonNode =
  %*{"type": "input_image", "image_url": "data:" & mimeType & ";base64," & data}

proc responsesFilePart(f: FileContent): JsonNode =
  %*{"type": "input_file", "filename": fileLabel(f),
    "file_data": fileDataUri(f)}

proc encodeResponsesHostedTool(tool: ToolDefinition): JsonNode =
  result = %*{"type": tool.hosted}
  mergeRequestOptions(result, tool.hostedOptions)

proc addAnnotationSource(blocks: var seq[ContentBlock], a: JsonNode) =
  if a.isNil or a.kind != JObject: return
  case a.getOrDefault("type").getStr
  of "url_citation":
    blocks.add source(a.getOrDefault("url").getStr, a.getOrDefault("title").getStr,
      raw = copy(a))
  of "file_citation":
    blocks.add source("", a.getOrDefault("filename").getStr,
      id = a.getOrDefault("file_id").getStr, raw = copy(a))
  else:
    discard

proc textWithSources(textVal: string, anns: JsonNode): seq[ContentBlock] =
  if textVal.len > 0:
    result.add text(textVal)
  if anns.isNil or anns.kind != JArray: return
  for a in anns:
    addAnnotationSource(result, a)

proc foldOutputText(textVal: string, sources: seq[ContentBlock]): JsonNode =
  result = %*{"type": "output_text", "text": textVal}
  if sources.len == 0: return
  var anns = newJArray()
  for s in sources:
    if not s.source.raw.isNil and s.source.raw.kind == JObject:
      anns.add s.source.raw
    elif s.source.url.len > 0:
      anns.add %*{"type": "url_citation", "url": s.source.url,
        "title": s.source.title}
  if anns.len > 0:
    result["annotations"] = anns

proc reasoningReplay(part: ContentBlock): JsonNode =
  ## Replay a stored Responses reasoning item. Anthropic signatures are ignored.
  if part.signature.len == 0: return nil
  try:
    let j = parseJson(part.signature)
    if j.kind != JObject or "id" notin j: return nil
    result = %*{"type": "reasoning", "id": j["id"]}
    if "encrypted_content" in j:
      result["encrypted_content"] = j["encrypted_content"]
    if part.thinking.len > 0:
      result["summary"] = %*[{"type": "summary_text", "text": part.thinking}]
  except CatchableError:
    result = nil

proc flushResponsesUser(input: var JsonNode, parts: var seq[JsonNode]) =
  if parts.len == 0: return
  var arr = newJArray()
  for p in parts: arr.add p
  input.add %*{"role": "user", "content": arr}
  parts.setLen(0)

proc addResponsesItems(input: var JsonNode, message: Message) =
  if message.role == roleUser:
    var parts: seq[JsonNode] = @[]
    for part in message.content:
      case part.kind
      of ckText:
        parts.add %*{"type": "input_text", "text": part.text}
      of ckImage:
        parts.add responsesImagePart(part.mimeType, part.data)
      of ckFile:
        parts.add responsesFilePart(part.file)
      of ckToolResult:
        if part.hosted.len > 0: continue
        flushResponsesUser(input, parts)
        input.add %*{"type": "function_call_output", "call_id": part.toolUseId,
          "output": part.output}
        if part.images.len > 0:
          var imgParts = newJArray()
          imgParts.add %*{"type": "input_text", "text": "(image from tool)"}
          for img in part.images:
            imgParts.add responsesImagePart(img.mimeType, img.data)
          input.add %*{"role": "user", "content": imgParts}
      else:
        discard
    if parts.len > 0:
      flushResponsesUser(input, parts)
    elif message.content.len == 0:
      input.add %*{"role": "user", "content": [{"type": "input_text", "text": ""}]}
    return

  var i = 0
  while i < message.content.len:
    let part = message.content[i]
    case part.kind
    of ckThinking:
      let item = reasoningReplay(part)
      if not item.isNil: input.add item
    of ckText:
      let sources = takeFollowingSources(message.content, i)
      if part.text.len > 0 or sources.len > 0:
        input.add %*{"role": "assistant",
          "content": [foldOutputText(part.text, sources)]}
    of ckToolUse:
      if part.hosted.len > 0:
        var item = %*{"type": part.hosted & "_call", "id": part.id,
          "status": "completed"}
        if not part.input.isNil:
          item["action"] = part.input
        input.add item
      else:
        let args = if part.input.isNil: "{}" else: part.input.pretty(0)
        input.add %*{"type": "function_call", "call_id": part.id,
          "name": part.name, "arguments": args}
    else:
      discard
    inc i

proc buildResponsesBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Native OpenAI Responses body. Stateless: store=false, full input each turn.
  validateToolChoice(request.toolChoice, request.tools)
  result = %*{
    "model": request.model,
    "input": newJArray(),
    "store": false
  }
  if stream:
    result["stream"] = %true
  if request.maxTokens > 0:
    result["max_output_tokens"] = %request.maxTokens
  if request.system.len > 0:
    result["instructions"] = %request.system.join("\n\n")
  var input = newJArray()
  for message in request.messages:
    addResponsesItems(input, message)
  result["input"] = input
  if request.tools.len > 0 and request.toolChoice.kind != tckNone:
    result["tools"] = newJArray()
    for tool in request.tools:
      if tool.hosted.len > 0:
        result["tools"].add encodeResponsesHostedTool(tool)
      else:
        result["tools"].add %*{
          "type": "function",
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.inputSchema
        }
  mergeRequestOptions(result, request.options)
  case request.toolChoice.kind
  of tckAuto:
    discard
  of tckRequired:
    result["tool_choice"] = %"required"
  of tckNone:
    result["tool_choice"] = %"none"
  of tckSpecific:
    result["tool_choice"] = %*{"type": "function", "name": request.toolChoice.name}
  if "reasoning_effort" in result:
    if "reasoning" notin result:
      result["reasoning"] = %*{"effort": result["reasoning_effort"]}
    delete(result, "reasoning_effort")
  if "reasoning" in result:
    result["include"] = %*["reasoning.encrypted_content"]

proc responsesObjectOptions*(name, description: string, schema: JsonNode): JsonNode =
  var fmt = %*{
    "type": "json_schema",
    "name": name,
    "strict": true,
    "schema": schema
  }
  if description.len > 0:
    fmt["description"] = %description
  %*{"text": {"format": fmt}}

proc outputTextFrom(item: JsonNode): string =
  let c = item.getOrDefault("content")
  if c.kind == JString: return c.getStr
  if c.kind != JArray: return
  for part in c:
    if part.getOrDefault("type").getStr in ["output_text", "text"]:
      if result.len > 0: result.add "\n"
      result.add part.getOrDefault("text").getStr

proc thinkingFromReasoningItem(item: JsonNode): ContentBlock =
  var summary = ""
  let s = item.getOrDefault("summary")
  if s.kind == JArray:
    for part in s:
      if part.getOrDefault("type").getStr == "summary_text":
        if summary.len > 0: summary.add "\n"
        summary.add part.getOrDefault("text").getStr
  var sig = newJObject()
  if "id" in item: sig["id"] = item["id"]
  if "encrypted_content" in item: sig["encrypted_content"] = item["encrypted_content"]
  ContentBlock(kind: ckThinking, thinking: summary,
    signature: if sig.len > 0: $sig else: "")

proc parseResponsesOutput*(data: JsonNode, failPrefix: string): ProviderResponse =
  if data.isNil or data.kind != JObject:
    raiseProviderError(failPrefix & " returned an empty response")
  let status = data.getOrDefault("status").getStr
  if status == "failed":
    let err = data.getOrDefault("error")
    let detail = if err.kind == JObject: err.getOrDefault("message").getStr
                 else: $data
    raiseProviderError(failPrefix & " response failed: " & detail, retryable = true)
  result.model = data.getOrDefault("model").getStr
  let output = data.getOrDefault("output")
  var hasTool = false
  if output.kind == JArray:
    for item in output:
      case item.getOrDefault("type").getStr
      of "reasoning":
        result.content.add thinkingFromReasoningItem(item)
      of "message":
        let c = item.getOrDefault("content")
        if c.kind == JArray:
          for part in c:
            if part.getOrDefault("type").getStr in ["output_text", "text"]:
              result.content.add textWithSources(
                part.getOrDefault("text").getStr, part.getOrDefault("annotations"))
        else:
          let t = outputTextFrom(item)
          if t.len > 0: result.content.add text(t)
      of "function_call":
        hasTool = true
        let args = item.getOrDefault("arguments").getStr
        let id = item.getOrDefault("call_id").getStr
        let name = item.getOrDefault("name").getStr
        result.content.add toolUseFromArgs(
          if id.len > 0: id else: "call_" & name, name, args)
      else:
        let typ = item.getOrDefault("type").getStr
        if typ.endsWith("_call") and typ != "function_call":
          let name = typ[0 ..< typ.len - 5]
          var action = item.getOrDefault("action")
          if action.isNil or action.kind == JNull:
            action = newJObject()
          result.content.add toolUse(item.getOrDefault("id").getStr, name,
            action, hosted = name)
  if "usage" in data and data["usage"].kind == JObject:
    parseOpenAiUsage(data["usage"], result.usage)
  if hasTool:
    result.finishReason = frToolUse
  elif status == "incomplete":
    let reason = data.getOrDefault("incomplete_details").getOrDefault("reason").getStr
    result.finishReason = if reason == "max_output_tokens": frMaxTokens else: frUnknown
  elif status == "completed" or status.len == 0:
    result.finishReason = frStop
  else:
    result.finishReason = frUnknown

proc eventDelta(data: JsonNode): string =
  let d = data.getOrDefault("delta")
  if d.kind == JString: return d.getStr
  data.getOrDefault("text").getStr

proc toolSlot(tools: var seq[PendingTool], data: JsonNode): int =
  let itemId = data.getOrDefault("item_id").getStr
  if itemId.len > 0:
    for i, t in tools:
      if t.itemId == itemId: return i
  result = data.getOrDefault("output_index").getInt
  while tools.len <= result:
    tools.add PendingTool()
  if itemId.len > 0:
    tools[result].itemId = itemId

proc handleResponsesEvent*(acc: var StreamAcc, response: var ProviderResponse,
                           data: JsonNode, onEvent: StreamCallback,
                           failPrefix: string): SseAction =
  let typ = data.getOrDefault("type").getStr
  case typ
  of "response.failed", "error":
    let err = data.getOrDefault("error")
    let detail = if err.kind == JObject: err.getOrDefault("message").getStr
                 else: $data
    raiseProviderError(failPrefix & " stream failed: " & detail, retryable = true)
  of "response.output_text.delta", "response.text.delta":
    let piece = eventDelta(data)
    if piece.len > 0:
      acc.text.add piece
      if not onEvent(StreamEvent(kind: seTextDelta, text: piece)):
        return sseCancel
  of "response.reasoning_summary_text.delta":
    let piece = eventDelta(data)
    if piece.len > 0:
      acc.think.add piece
      if not onEvent(StreamEvent(kind: seThinkingDelta, text: piece)):
        return sseCancel
  of "response.output_item.added", "response.output_item.done":
    let item = data.getOrDefault("item")
    if item.getOrDefault("type").getStr == "function_call":
      let idx = toolSlot(acc.tools, data)
      if "id" in item: acc.tools[idx].itemId = item["id"].getStr
      if "call_id" in item: acc.tools[idx].id = item["call_id"].getStr
      var nameNew = false
      if "name" in item and item["name"].kind == JString:
        if acc.tools[idx].name.len == 0: nameNew = true
        acc.tools[idx].name = item["name"].getStr
      if typ == "response.output_item.done":
        let args = item.getOrDefault("arguments").getStr
        if args.len > 0: acc.tools[idx].args = args
      if acc.tools[idx].name.len > 0 and nameNew:
        if not onEvent(StreamEvent(kind: seToolCallDelta,
            toolCallId: acc.tools[idx].id, toolName: acc.tools[idx].name,
            toolArgs: "")):
          return sseCancel
  of "response.function_call_arguments.delta":
    let idx = toolSlot(acc.tools, data)
    let piece = eventDelta(data)
    if piece.len > 0:
      acc.tools[idx].args.add piece
      if acc.tools[idx].name.len > 0:
        if not onEvent(StreamEvent(kind: seToolCallDelta,
            toolCallId: acc.tools[idx].id, toolName: acc.tools[idx].name,
            toolArgs: piece)):
          return sseCancel
  of "response.completed", "response.incomplete":
    let resp = data.getOrDefault("response")
    if resp.kind == JObject:
      response = parseResponsesOutput(resp, failPrefix)
      acc.parsedFinal = true
    return sseStop
  else:
    if response.model.len == 0:
      let resp = data.getOrDefault("response")
      if resp.kind == JObject:
        response.model = resp.getOrDefault("model").getStr
    if "usage" in data and data["usage"].kind == JObject:
      parseOpenAiUsage(data["usage"], response.usage)
  sseContinue
