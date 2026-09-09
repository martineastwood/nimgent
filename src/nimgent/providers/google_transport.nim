## Native Gemini generateContent transport, including provider-executed tools.
import std/[asyncdispatch, httpclient, json, net, strutils, tables, uri]
import nimgent/providers/[provider, stream, http_metadata]

const defaultGoogleEndpoint* = "https://generativelanguage.googleapis.com/v1beta"

type GoogleProvider* = ref object of Provider
  apiKey: string
  endpoint*: string
  timeoutSeconds: int

proc google*(apiKey: string, endpoint = defaultGoogleEndpoint,
             timeoutSeconds = 300): GoogleProvider =
  GoogleProvider(name: "google", apiKey: apiKey,
    endpoint: endpoint.strip(trailing = true, chars = {'/'}),
    timeoutSeconds: timeoutSeconds,
    capabilities: {pcStreaming, pcTools, pcStructuredOutput, pcImages, pcFiles,
      pcHostedTools, pcEmbeddings})

method nativeObjectOptions*(p: GoogleProvider, name, description: string,
                           schema: JsonNode): JsonNode =
  %*{"generationConfig": {"responseMimeType": "application/json",
    "responseJsonSchema": schema}}

proc buildGoogleBody*(request: ProviderRequest): JsonNode =
  validateToolChoice(request.toolChoice, request.tools)
  result = %*{"contents": []}
  var names = initTable[string, string]()
  var ids = initTable[string, string]()
  for message in request.messages:
    var parts = newJArray()
    for part in message.content:
      if part.kind == ckToolUse and part.hosted.len == 0:
        names[part.id] = part.name
        let id = part.googlePart{"functionCall", "id"}.getStr
        if id.len > 0: ids[part.id] = id
      if not part.googlePart.isNil:
        parts.add copy(part.googlePart)
        continue
      case part.kind
      of ckText: parts.add %*{"text": part.text}
      of ckImage:
        parts.add %*{"inlineData": {"mimeType": part.mimeType, "data": part.data}}
      of ckFile:
        parts.add %*{"inlineData": {"mimeType": part.file.mimeType, "data": part.file.data}}
      of ckToolUse:
        if part.hosted.len > 0: continue
        var call = %*{"functionCall": {"name": part.name, "args": part.input}}
        if part.thoughtSignature.len > 0:
          call["thoughtSignature"] = %part.thoughtSignature
        parts.add call
      of ckToolResult:
        if part.hosted.len > 0: continue
        if part.toolUseId notin names:
          raiseProviderError("Google tool result has no matching function call")
        parts.add %*{"functionResponse": {"name": names[part.toolUseId],
          "response": {"output": part.output, "isError": part.isError}}}
        if part.toolUseId in ids:
          parts[parts.len - 1]["functionResponse"]["id"] = %ids[part.toolUseId]
        for img in part.images:
          parts.add %*{"inlineData": {"mimeType": img.mimeType, "data": img.data}}
      of ckThinking, ckSource: discard
    if parts.len > 0:
      result["contents"].add %*{
        "role": (if message.role == roleAssistant: "model" else: "user"),
        "parts": parts}
  if request.system.len > 0:
    result["systemInstruction"] = %*{"parts": [{"text": request.system.join("\n\n")}]}
  var declarations = newJArray()
  var hosted = newJArray()
  for tool in request.tools:
    if tool.hosted.len == 0:
      declarations.add %*{"name": tool.name, "description": tool.description,
        "parametersJsonSchema": tool.inputSchema}
    else:
      var key: string
      case tool.hosted
        of "web_search": key = "googleSearch"
        of "url_context": key = "urlContext"
        else: raiseProviderError("Unsupported Google hosted tool: " & tool.hosted)
      var entry = newJObject()
      entry[key] = if tool.hostedOptions.isNil: newJObject() else: copy(tool.hostedOptions)
      hosted.add entry
  if declarations.len > 0 and request.toolChoice.kind != tckNone:
    hosted.add %*{"functionDeclarations": declarations}
  if hosted.len > 0 and request.toolChoice.kind != tckNone:
    result["tools"] = hosted
  if not request.options.isNil: mergeRequestOptions(result, copy(request.options))
  case request.toolChoice.kind
  of tckAuto:
    discard
  of tckRequired:
    result["toolConfig"] = %*{"functionCallingConfig": {"mode": "ANY"}}
  of tckNone:
    result["toolConfig"] = %*{"functionCallingConfig": {"mode": "NONE"}}
  of tckSpecific:
    result["toolConfig"] = %*{"functionCallingConfig": {"mode": "ANY",
      "allowedFunctionNames": [request.toolChoice.name]}}
  if not result.hasKey("generationConfig"): result["generationConfig"] = newJObject()
  let config = result["generationConfig"]
  if config.kind != JObject: raiseProviderError("generationConfig must be an object")
  if request.maxTokens > 0: config["maxOutputTokens"] = %request.maxTokens
  if result.hasKey("reasoning_effort"):
    let effort = result["reasoning_effort"].getStr
    if request.model.startsWith("gemini-2.5"):
      config["thinkingConfig"] = %*{"thinkingBudget":
        (case effort
          of "none": 0
          of "minimal", "low": 1024
          of "medium": 8192
          of "high": 24576
          else: -1)}
    else:
      config["thinkingConfig"] = %*{"thinkingLevel": effort.toUpperAscii}
    result.delete("reasoning_effort")
  if result.hasKey("user"):
    raiseProviderError("Google does not support the user option")

proc parseGoogleOutput*(data: JsonNode): ProviderResponse =
  if data.isNil or data.kind != JObject:
    raiseProviderError("Google returned an invalid response")
  if data.hasKey("error"):
    raiseProviderError("Google API error: " & apiErrorMessage($data),
      status = data{"error", "code"}.getInt)
  result.model = data{"modelVersion"}.getStr
  let usage = data{"usageMetadata"}
  result.usage.inputTokens = usage{"promptTokenCount"}.getInt
  result.usage.outputTokens = usage{"candidatesTokenCount"}.getInt + usage{"thoughtsTokenCount"}.getInt
  result.usage.cacheReadTokens = usage{"cachedContentTokenCount"}.getInt
  result.usage.cacheReported = not usage.isNil and usage.hasKey("cachedContentTokenCount")
  let candidates = data{"candidates"}
  if candidates.isNil or candidates.len == 0:
    if not data{"promptFeedback", "blockReason"}.isNil:
      raiseProviderError("Google blocked prompt: " & data{"promptFeedback", "blockReason"}.getStr)
    return
  let candidate = candidates[0]
  let parts = candidate{"content", "parts"}
  if not parts.isNil:
    for i, part in parts.elems:
      var blockValue: ContentBlock
      if part.hasKey("functionCall"):
        let call = part["functionCall"]
        blockValue = toolUse(call{"id"}.getStr("google-call-" & $i),
          call{"name"}.getStr, call{"args"})
        blockValue.thoughtSignature = part{"thoughtSignature"}.getStr
      elif part.hasKey("text"):
        blockValue = if part{"thought"}.getBool:
          ContentBlock(kind: ckThinking, thinking: part{"text"}.getStr,
            signature: part{"thoughtSignature"}.getStr)
          else: text(part{"text"}.getStr)
      elif part.hasKey("toolCall"):
        let call = part["toolCall"]
        blockValue = toolUse(call{"id"}.getStr, call{"toolType"}.getStr,
          copy(call), hosted = call{"toolType"}.getStr("google_tool"))
      elif part.hasKey("toolResponse"):
        let response = part["toolResponse"]
        blockValue = toolResult(response{"id"}.getStr, $response,
          hosted = response{"toolType"}.getStr("google_tool"))
      elif part.hasKey("thoughtSignature"):
        blockValue = ContentBlock(kind: ckThinking, signature: part{"thoughtSignature"}.getStr)
      else: continue
      blockValue.googlePart = copy(part)
      result.content.add blockValue
  let grounding = candidate{"groundingMetadata"}
  if not grounding.isNil:
    let chunks = grounding{"groundingChunks"}
    if not chunks.isNil:
      for chunk in chunks:
        let web = chunk{"web"}
        if not web.isNil:
          result.content.add source(web{"uri"}.getStr, web{"title"}.getStr, raw = copy(chunk))
    # Preserve supports, queries and Search Suggestions HTML, including when no
    # source chunks are returned. This metadata is not a model conversation part.
    result.content.add toolResult("google-search", $grounding, hosted = "web_search")
  let urls = candidate{"urlContextMetadata"}
  if not urls.isNil:
    let entries = urls{"urlMetadata"}
    if not entries.isNil:
      for entry in entries:
        let url = entry{"retrievedUrl"}.getStr
        if url.len > 0 and entry{"urlRetrievalStatus"}.getStr == "URL_RETRIEVAL_STATUS_SUCCESS":
          result.content.add source(url, raw = copy(entry))
    result.content.add toolResult("google-url-context", $urls, hosted = "url_context")
  let reason = candidate{"finishReason"}.getStr
  case reason
    of "STOP": result.finishReason = (if result.toolCalls.len > 0: frToolUse else: frEndTurn)
    of "MAX_TOKENS": result.finishReason = frMaxTokens
    of "", "FINISH_REASON_UNSPECIFIED": result.finishReason = frUnknown
    else: raiseProviderError("Google stopped generation: " & reason)

proc handleGoogleEvent*(response: var ProviderResponse, data: JsonNode,
                              onEvent: StreamCallback): SseAction =
  let chunk = parseGoogleOutput(data)
  if chunk.model.len > 0: response.model = chunk.model
  if data.hasKey("usageMetadata"): response.usage = chunk.usage
  for part in chunk.content:
    var part = part
    if part.kind == ckToolUse and part.hosted.len == 0 and
        part.googlePart{"functionCall", "id"}.isNil:
      part.id = "google-call-" & $response.content.len
    if part.kind in {ckText, ckThinking} and response.content.len > 0 and
        response.content[^1].kind == part.kind and
        response.content[^1].googlePart{"thoughtSignature"}.getStr.len == 0:
      if part.kind == ckText:
        response.content[^1].text.add part.text
        response.content[^1].googlePart["text"] = %response.content[^1].text
      else:
        response.content[^1].thinking.add part.thinking
        response.content[^1].googlePart["text"] = %response.content[^1].thinking
        response.content[^1].signature = part.signature
      if part.googlePart.hasKey("thoughtSignature"):
        response.content[^1].googlePart["thoughtSignature"] = copy(part.googlePart["thoughtSignature"])
    else:
      response.content.add part
    let keep = case part.kind
      of ckText: onEvent(StreamEvent(kind: seTextDelta, text: part.text))
      of ckThinking: onEvent(StreamEvent(kind: seThinkingDelta, text: part.thinking))
      of ckToolUse: onEvent(StreamEvent(kind: seToolCallDelta,
        toolCallId: part.id, toolName: part.name, toolArgs: $part.input))
      else: true
    if not keep: return sseCancel
  if chunk.finishReason != frUnknown:
    response.finishReason = if response.toolCalls.len > 0 and chunk.finishReason == frEndTurn:
      frToolUse else: chunk.finishReason
  # Metadata/usage can arrive after finishReason; consume through EOF.
  sseContinue

proc requestNative(p: GoogleProvider, request: ProviderRequest,
                   onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  if p.apiKey.len == 0: raiseProviderError("GOOGLE API key is not configured")
  let streaming = not onEvent.isNil
  let body = buildGoogleBody(request)
  let client = newAsyncHttpClient(sslContext = newContext(verifyMode = CVerifyPeer),
    headers = newHttpHeaders({"x-goog-api-key": p.apiKey, "content-type": "application/json"}))
  client.timeout = p.timeoutSeconds * 1000
  var watch = WakeWatch()
  defer:
    client.close()
    watch.unregister()
  var model = request.model
  model.removePrefix("models/")
  let url = p.endpoint & "/models/" & encodeUrl(model, usePlus = false) &
    (if streaming: ":streamGenerateContent?alt=sse" else: ":generateContent")
  try:
    let pending = client.request(url, HttpPost, $body)
    if streaming and not await awaitWithWakeAsync(pending, addr watch, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    let response = await pending
    if response.code.int >= 400:
      let detail = apiErrorMessage(await drainBodyStreamAsync(response.bodyStream))
      raiseProviderError("Google API error (" & $response.code.int & "): " & detail,
        status = response.code.int,
        overflow = response.code.int == 400 and isContextOverflow(detail),
        retryAfterMs = parseRetryAfter(response.headers.getOrDefault("Retry-After")),
        requestId = requestIdFromHeaders(response.headers))
    if not streaming:
      result = parseGoogleOutput(parseJson(await drainBodyStreamAsync(response.bodyStream)))
      result.requestId = requestIdFromHeaders(response.headers)
      if result.finishReason == frUnknown: raiseProviderError("Google returned no completed candidate")
      return
    var accumulated: ProviderResponse
    let requestId = requestIdFromHeaders(response.headers)
    let drive = await forEachSseAsync(response.bodyStream, addr watch, request.wakeFd,
      onEvent, proc (data: JsonNode): SseAction =
        handleGoogleEvent(accumulated, data, onEvent))
    if drive == sdCancelled:
      result.finishReason = frStop
      return
    if accumulated.finishReason == frUnknown:
      raiseProviderError("Google stream closed mid-response", retryable = true)
    result = accumulated
    result.requestId = requestId
    discard onEvent(StreamEvent(kind: seFinished))
  except ProviderError: raise
  except CatchableError as e:
    raiseProviderError("Google request failed: " & e.msg, retryable = true)

method generateAsync*(p: GoogleProvider,
                      request: ProviderRequest): Future[ProviderResponse] =
  requestNative(p, request, nil)

method generateStreamAsync*(p: GoogleProvider, request: ProviderRequest,
                           onEvent: StreamCallback): Future[ProviderResponse] =
  requestNative(p, request, onEvent)

method embedAsync*(p: GoogleProvider,
                   request: EmbeddingRequest): Future[EmbeddingResponse] {.async.} =
  if p.apiKey.len == 0: raiseProviderError("GOOGLE API key is not configured")
  var model = request.model
  model.removePrefix("models/")
  let modelPath = "models/" & model
  var requests = newJArray()
  for value in request.values:
    var item = %*{"model": modelPath, "content": {"parts": [{"text": value}]}}
    if not request.options.isNil:
      mergeRequestOptions(item, copy(request.options))
    requests.add item
  let client = newAsyncHttpClient(sslContext = newContext(verifyMode = CVerifyPeer),
    headers = newHttpHeaders({"x-goog-api-key": p.apiKey,
      "content-type": "application/json"}))
  client.timeout = p.timeoutSeconds * 1000
  defer: client.close()
  let url = p.endpoint & "/" & modelPath & ":batchEmbedContents"
  try:
    let response = await client.request(url, HttpPost, $(%*{"requests": requests}))
    let raw = await drainBodyStreamAsync(response.bodyStream)
    if response.code.int >= 400:
      raiseProviderError("Google API error (" & $response.code.int & "): " &
        apiErrorMessage(raw), status = response.code.int,
        retryAfterMs = parseRetryAfter(response.headers.getOrDefault("Retry-After")),
        requestId = requestIdFromHeaders(response.headers))
    let data = parseJson(raw)
    let embeddings = data{"embeddings"}
    if embeddings.isNil or embeddings.len != request.values.len:
      raiseProviderError("Google returned an unexpected number of embeddings")
    result.model = request.model
    result.requestId = requestIdFromHeaders(response.headers)
    for embedding in embeddings:
      var values: seq[float]
      for value in embedding{"values"}: values.add value.getFloat
      result.embeddings.add values
  except ProviderError: raise
  except CatchableError as e:
    raiseProviderError("Google embedding request failed: " & e.msg, retryable = true)
