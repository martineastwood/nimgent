## OpenAI-family HTTP provider.
##
## Native OpenAI uses the Responses API (`store: false`, reasoning replay).
## OpenRouter, Hyper, and any `*/chat/completions` URL keep Chat Completions.
## Session_id, cache_control, and HTTP-Referer stay optional on this type.

import std/[asyncdispatch, httpclient, json, net, streams, strutils]
import nimgent/[provider, stream, openai_chat, openai_responses]
export popLine, buildChatBody, openAiImagePart, buildResponsesBody,
  parseResponsesOutput, chatObjectOptions, chatForceToolOptions,
  responsesObjectOptions, responsesForceToolOptions

const
  defaultOpenAiEndpoint* = "https://api.openai.com/v1/responses"
  defaultOpenAiChatEndpoint* = "https://api.openai.com/v1/chat/completions"
  defaultHyperEndpoint* = "https://hyper.charm.land/v1/chat/completions"

type
  OpenAIProvider* = ref object of Provider
    apiKey*: string
    endpoint*: string
    timeoutSeconds*: int
    siteUrl*: string
    siteName*: string
    ## OpenRouter continuation hint; omitted for native OpenAI.
    includeSessionId*: bool
    ## Anthropic-style cache breakpoints; OpenAI caches stable prefixes itself.
    applyCache*: bool
    ## "max_tokens" (OpenRouter) or "max_completion_tokens" (Chat Completions).
    maxTokensField*: string
    displayName*: string
    ## True: POST /v1/responses. False: Chat Completions (OpenRouter / compat).
    useResponses*: bool

  OpenRouterProvider* = OpenAIProvider
  HyperProvider* = OpenAIProvider

proc initOpenAIProvider(name, displayName, apiKey, endpoint: string,
                      timeoutSeconds: int, siteUrl = "", siteName = "",
                      includeSessionId = false, applyCache = false,
                      maxTokensField = "max_completion_tokens",
                      useResponses = false): OpenAIProvider =
  OpenAIProvider(name: name, displayName: displayName, apiKey: apiKey,
                 endpoint: endpoint, timeoutSeconds: timeoutSeconds,
                 siteUrl: siteUrl, siteName: siteName,
                 includeSessionId: includeSessionId, applyCache: applyCache,
                 maxTokensField: maxTokensField, useResponses: useResponses)

proc makeOpenAIProvider*(apiKey: string, endpoint = "",
                         timeoutSeconds = 300): OpenAIProvider =
  ## Responses API by default. A `*/chat/completions` URL stays on that wire format.
  let url = if endpoint.len > 0: endpoint else: defaultOpenAiEndpoint
  let responses = "/chat/completions" notin url
  initOpenAIProvider("openai", "OpenAI", apiKey, url, timeoutSeconds,
    maxTokensField = "max_completion_tokens", useResponses = responses)

proc makeOpenRouterProvider*(apiKey, endpoint: string,
                             timeoutSeconds = 300, siteUrl = "",
                             siteName = ""): OpenRouterProvider =
  initOpenAIProvider("openrouter", "OpenRouter", apiKey, endpoint,
    timeoutSeconds, siteUrl, siteName, includeSessionId = true,
    applyCache = true, maxTokensField = "max_tokens")

proc makeHyperProvider*(apiKey: string, endpoint = "",
                        timeoutSeconds = 300): HyperProvider =
  ## Hyper's documented agent API is Chat Completions. Their /v1/responses
  ## pass-through 400s OpenAI input items, so this stays on chat.
  let url = if endpoint.len > 0: endpoint else: defaultHyperEndpoint
  initOpenAIProvider("hyper", "Hyper", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens")

proc label(provider: OpenAIProvider): string =
  if provider.displayName.len > 0: provider.displayName else: provider.name

proc makeHeaders(provider: OpenAIProvider): HttpHeaders =
  result = {
    "Authorization": "Bearer " & provider.apiKey,
    "Content-Type": "application/json"
  }.newHttpHeaders
  if provider.siteUrl.len > 0:
    result["HTTP-Referer"] = provider.siteUrl
  if provider.siteName.len > 0:
    result["X-Title"] = provider.siteName

proc ensureApiKey(provider: OpenAIProvider) =
  if provider.apiKey.len == 0:
    raiseProviderError(provider.label.toUpperAscii & " API key is not configured")

proc newClient(provider: OpenAIProvider): HttpClient =
  newHttpClient(timeout = provider.timeoutSeconds * 1000,
                sslContext = newContext(verifyMode = CVerifyPeer))

proc raiseApiError(provider: OpenAIProvider, code: int, raw: string,
                   headers: HttpHeaders = nil) =
  let detail = apiErrorMessage(raw)
  let ra = if headers.isNil: 0
           else: parseRetryAfter(headers.getOrDefault("Retry-After"))
  raiseProviderError(provider.label & " API error (" & $code & "): " & detail,
    overflow = isContextOverflow(detail), status = code, retryAfterMs = ra)

proc requestBody(provider: OpenAIProvider, request: ProviderRequest,
                 stream: bool): JsonNode =
  if provider.useResponses:
    return buildResponsesBody(request, stream)
  buildChatBody(request, stream,
    includeSessionId = provider.includeSessionId,
    applyCache = provider.applyCache,
    maxTokensField = provider.maxTokensField)

proc postRequest(provider: OpenAIProvider, body: JsonNode,
                 failPrefix: string): tuple[client: HttpClient, response: Response] =
  provider.ensureApiKey()
  result.client = provider.newClient()
  let headers = provider.makeHeaders()
  try:
    result.response = result.client.request(provider.endpoint, HttpPost, $body, headers)
  except CatchableError as e:
    result.client.close()
    raiseProviderError(failPrefix & e.msg, retryable = true)

method nativeObjectOptions*(provider: OpenAIProvider, name, description: string,
                            schema: JsonNode): JsonNode =
  if provider.useResponses:
    responsesObjectOptions(name, description, schema)
  else:
    chatObjectOptions(name, description, schema)

method forceToolOptions*(provider: OpenAIProvider, toolName: string): JsonNode =
  if provider.useResponses:
    responsesForceToolOptions(toolName)
  else:
    chatForceToolOptions(toolName)

method generate*(provider: OpenAIProvider,
                 request: ProviderRequest): ProviderResponse =
  let body = provider.requestBody(request, stream = false)
  let (client, response) = provider.postRequest(body, provider.label & " request failed: ")
  defer: client.close()
  let raw = response.bodyStream.readAll()
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, raw, response.headers)
  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError(provider.label & " returned invalid JSON: " & e.msg)
  if provider.useResponses:
    return parseResponsesOutput(data, provider.label)
  result = parseChatOutput(data, provider.label)

method generateStream*(provider: OpenAIProvider,
                       request: ProviderRequest,
                       onEvent: StreamCallback): ProviderResponse =
  # Sync HttpClient.request() buffers the whole SSE body before returning.
  # AsyncHttpClient starts parseBody without awaiting, so bodyStream.read()
  # yields chunks as they arrive.
  provider.ensureApiKey()
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders())
  client.timeout = provider.timeoutSeconds * 1000
  var watch = WakeWatch()
  defer:
    client.close()
    watch.unregister()
  let body = provider.requestBody(request, stream = true)
  var response: AsyncResponse
  try:
    let reqFut = client.request(provider.endpoint, HttpPost, $body)
    if not awaitWithWake(reqFut, watch, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = waitFor reqFut
  except CatchableError as e:
    raiseProviderError(provider.label & " stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, drainBodyStream(response.bodyStream),
      response.headers)

  var acc = initStreamAcc()
  var resp = ProviderResponse()
  let handle =
    if provider.useResponses:
      proc (data: JsonNode): SseAction =
        handleResponsesEvent(acc, resp, data, onEvent, provider.label)
    else:
      proc (data: JsonNode): SseAction =
        handleChatEvent(acc, resp, data, onEvent)
  let drive = forEachSse(response.bodyStream, watch, request.wakeFd,
    onEvent, handle)
  if drive == sdCancelled:
    assembleStream(acc, resp)
    result = resp
    if result.finishReason == frUnknown:
      result.finishReason = frStop
    return
  if drive == sdClosed and resp.finishReason == frUnknown:
    raiseProviderError(provider.label &
      " stream failed: connection closed mid-response", retryable = true)
  assembleStream(acc, resp)
  result = resp
  discard onEvent(StreamEvent(kind: seFinished))
