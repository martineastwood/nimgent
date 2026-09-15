## MCP 2026-07-28 client over stdio and Streamable HTTP.
##
## The client deliberately pins the modern stateless revision. It discovers
## tools, resources, prompts, completions, subscriptions, and task handles,
## then adapts remote tools to nimgent's normal Tool type.

import std/[asyncdispatch, asyncfile, asyncstreams, base64, httpclient, json,
  osproc, sequtils, strtabs, strutils, tables]
when not defined(windows):
  import posix
import nimgent/providers/provider

const mcpProtocolVersion* = "2026-07-28" ## MCP revision used by the client.

type
  McpRequestOptions* = object
    ## Optional request metadata sent in the MCP `_meta` object.
    progressToken*: JsonNode
    logLevel*: string
    traceContext*: JsonNode
    metadata*: JsonNode

  McpInputRequest* = object
    ## One input request from an `input_required` result.
    key*: string
    methodName*: string
    params*: JsonNode
    raw*: JsonNode

  McpInputHandler* = proc (request: McpInputRequest): JsonNode {.closure.}
  McpProgressHandler* = proc (progress, total: float,
                              message: string) {.closure.}
  McpNotificationHandler* = proc (methodName: string,
                                  params: JsonNode) {.closure.}

  McpClientError* = object of CatchableError
    ## Error returned by an MCP client operation.
    code*: int
    data*: JsonNode

  McpToolInfo* = object
    ## Discovered MCP tool metadata.
    name*: string
    description*: string
    inputSchema*: JsonNode
    outputSchema*: JsonNode
    title*: string
    icons*: JsonNode
    annotations*: JsonNode

  McpResourceInfo* = object
    ## Discovered MCP resource metadata.
    uri*: string
    uriTemplate*: string
    name*: string
    title*: string
    description*: string
    icons*: JsonNode
    mimeType*: string
    size*: int64
    annotations*: JsonNode

  McpResourceContent* = object
    ## Text or base64-encoded binary resource content.
    uri*: string
    mimeType*: string
    text*: string
    blob*: string
    isBlob*: bool
    raw*: JsonNode

  McpResourceReadResult* = object
    resultType*: string
    contents*: seq[McpResourceContent]
    ttlMs*: int64
    cacheScope*: string
    inputRequests*: JsonNode
    requestState*: string
    raw*: JsonNode

  McpPromptArgumentInfo* = object
    name*: string
    description*: string
    required*: bool

  McpPromptInfo* = object
    ## Discovered MCP prompt metadata.
    name*: string
    title*: string
    description*: string
    icons*: JsonNode
    arguments*: seq[McpPromptArgumentInfo]

  McpPromptMessage* = object
    role*: string
    content*: JsonNode
    raw*: JsonNode

  McpPromptResult* = object
    resultType*: string
    description*: string
    messages*: seq[McpPromptMessage]
    inputRequests*: JsonNode
    requestState*: string
    raw*: JsonNode

  McpCompletionResult* = object
    values*: seq[string]
    total*: int
    hasMore*: bool
    raw*: JsonNode

  McpTaskInfo* = object
    ## Task handle and current state returned by the Tasks extension.
    taskId*: string
    status*: string
    statusMessage*: string
    createdAt*: string
    lastUpdatedAt*: string
    ttlMs*: int64
    pollIntervalMs*: int
    progress*: float
    hasProgress*: bool
    total*: float
    hasTotal*: bool
    inputRequests*: JsonNode
    result*: JsonNode
    error*: JsonNode
    raw*: JsonNode

  McpCallResult* = object
    ## Content and status returned by an MCP tool call.
    content*: JsonNode
    structuredContent*: JsonNode
    isError*: bool
    resultType*: string
    inputRequests*: JsonNode
    requestState*: string
    task*: McpTaskInfo
    raw*: JsonNode

  McpSubscriptionFilter* = object
    ## Change streams requested from `subscriptions/listen`.
    toolsListChanged*: bool
    promptsListChanged*: bool
    resourcesListChanged*: bool
    resourceSubscriptions*: seq[string]

  McpSubscription* = ref object
    ## A live MCP subscription backed by a pull-based event stream.
    id*: int
    filter*: McpSubscriptionFilter
    queue*: FutureStream[JsonNode]
    acknowledged*: Future[JsonNode]
    closed*: Future[void]
    client: McpClient
    handler: McpSubscriptionMessageHandler
    active: bool
    httpClient: AsyncHttpClient
    httpTask: Future[void]

  McpSubscriptionMessageHandler* = proc (message: JsonNode) {.closure.}

  McpClient* = ref object
    ## Client connected to an MCP server over stdio or Streamable HTTP.
    process: Process
    input: AsyncFile
    output: AsyncFile
    pending: Table[string, Future[JsonNode]]
    nextId: int
    reader: Future[void]
    closed: bool
    clientName: string
    clientVersion: string
    clientCapabilities: JsonNode
    httpEndpoint: string
    httpHeaders: HttpHeaders
    inputHandlers: Table[string, McpInputHandler]
    toolInputSchemas: Table[string, JsonNode]
    subscriptions: Table[string, McpSubscription]
    progressHandler*: McpProgressHandler
    notificationHandler*: McpNotificationHandler
    serverInfo*: JsonNode
    discovery*: JsonNode

proc close*(client: McpClient) ## Close the MCP process and pending requests.

when not defined(windows):
  proc makeNonBlocking(handle: FileHandle) =
    let flags = fcntl(handle.cint, F_GETFL, 0)
    discard fcntl(handle.cint, F_SETFL, flags or O_NONBLOCK)

proc clientFailure(message: string, code = 0,
                   data: JsonNode = nil): ref McpClientError =
  let error = newException(McpClientError, message)
  error.code = code
  error.data = data
  error

proc optional(node: JsonNode, key: string): JsonNode =
  if not node.isNil and key in node: node[key] else: nil

proc optionalString(node: JsonNode, key: string): string =
  let value = node.optional(key)
  if not value.isNil and value.kind == JString: result = value.getStr

proc optionalBool(node: JsonNode, key: string): bool =
  let value = node.optional(key)
  not value.isNil and value.kind == JBool and value.getBool

proc requireObject(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise clientFailure(context & " must be an object")
  node

proc requireArray(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JArray:
    raise clientFailure(context & " must be an array")
  node

proc optionalStringChecked(node: JsonNode, key, context: string): string =
  let value = node.optional(key)
  if not value.isNil and value.kind != JString:
    raise clientFailure(context & " '" & key & "' must be a string")
  if not value.isNil: result = value.getStr

proc failPending(client: McpClient, error: ref CatchableError) =
  for _, future in client.pending.mpairs:
    if not future.finished:
      future.fail(error)
  client.pending.clear()

proc finishSubscription(subscription: McpSubscription, message: JsonNode = nil) =
  if subscription.isNil: return
  if not message.isNil:
    discard subscription.queue.write(message)
  if not subscription.acknowledged.finished:
    subscription.acknowledged.complete(
      if message.isNil: newJNull() else: message)
  subscription.active = false
  if not subscription.queue.finished:
    subscription.queue.complete()
  if not subscription.closed.finished:
    subscription.closed.complete()

proc subscriptionId(message: JsonNode): string =
  if message.isNil or message.kind != JObject or "params" notin message:
    return ""
  let params = message["params"]
  if params.kind != JObject or "_meta" notin params or
      params["_meta"].kind != JObject:
    return ""
  let id = params["_meta"].optional("io.modelcontextprotocol/subscriptionId")
  if id.isNil or id.kind notin {JString, JInt}: return ""
  $id

proc deliverSubscription(client: McpClient, message: JsonNode) =
  let key = message.subscriptionId()
  if key.len == 0 or key notin client.subscriptions: return
  let subscription = client.subscriptions[key]
  let methodName = message.optionalString("method")
  if methodName == "notifications/subscriptions/acknowledged":
    if not subscription.acknowledged.finished:
      subscription.acknowledged.complete(message)
    return
  if subscription.active:
    if not subscription.handler.isNil:
      try:
        subscription.handler(message)
      except CatchableError:
        discard
    discard subscription.queue.write(message)

proc deliverNotification(client: McpClient, message: JsonNode) =
  if message.isNil or message.kind != JObject: return
  if message.subscriptionId().len > 0:
    client.deliverSubscription(message)
    return
  let methodName = message.optionalString("method")
  let params = message.optional("params")
  if methodName == "notifications/progress" and not client.progressHandler.isNil:
    if not params.isNil and params.kind == JObject:
      let progress = params.optional("progress")
      let total = params.optional("total")
      try:
        client.progressHandler(
          if progress.isNil: 0.0 else: progress.getFloat,
          if total.isNil: -1.0 else: total.getFloat,
          params.optionalString("message"))
      except CatchableError:
        discard
  if not client.notificationHandler.isNil:
    try:
      client.notificationHandler(methodName, params)
    except CatchableError:
      discard

proc deliverResponse(client: McpClient, message: JsonNode) =
  let id = message.optional("id")
  let key = if id.isNil: "null" else: $id
  if key in client.subscriptions:
    let subscription = client.subscriptions[key]
    if "error" in message and not subscription.acknowledged.finished:
      subscription.acknowledged.complete(message)
    subscription.finishSubscription(message)
    client.subscriptions.del(key)
  elif key in client.pending:
    let future = client.pending[key]
    client.pending.del(key)
    if not future.finished:
      future.complete(message)

proc readResponses(client: McpClient) {.async.} =
  var failure: ref CatchableError
  try:
    while not client.closed:
      let line = await client.output.readLine()
      if line.len == 0:
        failure = clientFailure("MCP server closed stdout")
        break
      let message = parseJson(line)
      if "id" in message: client.deliverResponse(message)
      else: client.deliverNotification(message)
  except CatchableError as error:
    failure = clientFailure("MCP stdio reader failed: " & error.msg)
  if not client.closed and not failure.isNil:
    client.failPending(failure)
    for _, subscription in client.subscriptions.mpairs:
      subscription.finishSubscription()
    client.subscriptions.clear()

proc requestParams(client: McpClient, params: JsonNode,
                   options: McpRequestOptions): JsonNode =
  result = if params.isNil: newJObject() else: copy(params)
  if result.kind != JObject:
    raise clientFailure("MCP request params must be an object")
  var meta = if "_meta" in result and result["_meta"].kind == JObject:
    copy(result["_meta"])
  else:
    newJObject()
  if not options.metadata.isNil:
    let extensionMetadata = requireObject(options.metadata,
      "MCP request metadata")
    for key, value in extensionMetadata.pairs:
      meta[key] = value
  meta["io.modelcontextprotocol/protocolVersion"] = %mcpProtocolVersion
  meta["io.modelcontextprotocol/clientInfo"] = %*{
    "name": client.clientName,
    "version": client.clientVersion
  }
  meta["io.modelcontextprotocol/clientCapabilities"] =
    if client.clientCapabilities.isNil: newJObject() else: client.clientCapabilities
  if not options.progressToken.isNil:
    if options.progressToken.kind notin {JString, JInt}:
      raise clientFailure("MCP progressToken must be a string or integer")
    meta["progressToken"] = options.progressToken
  if options.logLevel.len > 0: meta["io.modelcontextprotocol/logLevel"] = %options.logLevel
  if not options.traceContext.isNil:
    meta["io.modelcontextprotocol/traceContext"] = requireObject(
      options.traceContext, "MCP traceContext")
  result["_meta"] = meta

proc copyHttpHeaders(headers: HttpHeaders): HttpHeaders =
  result = newHttpHeaders()
  if not headers.isNil:
    for name, value in headers.pairs:
      result.add(name, value)

proc httpMessage(body: string): JsonNode =
  try:
    return parseJson(body)
  except CatchableError:
    for line in body.splitLines:
      let value = line.strip
      if value.startsWith("data:") and value.len > 5:
        try: return parseJson(value[5 .. ^1].strip)
        except CatchableError: discard
  raise clientFailure("MCP HTTP response did not contain JSON")

proc parseRpcResponse(message: JsonNode): JsonNode =
  let value = requireObject(message, "MCP response")
  if "error" in value:
    let errorNode = requireObject(value["error"], "MCP error")
    let detail = errorNode.optional("data")
    raise clientFailure(errorNode.optionalStringChecked("message", "MCP error"),
      if errorNode.optional("code").isNil: 0 else: errorNode["code"].getInt,
      if detail.isNil or detail.kind == JNull: nil else: detail)
  if "result" notin value or value["result"].kind != JObject:
    raise clientFailure("MCP response has no result object")
  let resultNode = value["result"]
  let resultType = resultNode.optional("resultType")
  if resultType.isNil or resultType.kind != JString or
      resultType.getStr notin ["complete", "input_required", "task"]:
    raise clientFailure("MCP result has an invalid resultType: " &
      (if resultType.isNil: "missing" else: $resultType))
  resultNode

type McpHeaderBinding = object
  name: string
  path: seq[string]
  valueType: string

proc collectHeaderBindings(node: JsonNode, path: seq[string],
                           bindings: var seq[McpHeaderBinding]) =
  if node.isNil or node.kind != JObject: return
  if "x-mcp-header" in node and path.len > 0 and
      node["x-mcp-header"].kind == JString and "type" in node and
      node["type"].kind == JString:
    bindings.add McpHeaderBinding(name: node["x-mcp-header"].getStr,
      path: path, valueType: node["type"].getStr)
  let properties = node.optional("properties")
  if properties.isNil or properties.kind != JObject: return
  for name, property in properties.pairs:
    collectHeaderBindings(property, path & name, bindings)

proc headerBindings(schema: JsonNode): seq[McpHeaderBinding] =
  collectHeaderBindings(schema, @[], result)

proc valueAtPath(node: JsonNode, path: seq[string]): JsonNode =
  result = node
  for name in path:
    if result.isNil or result.kind != JObject or name notin result: return nil
    result = result[name]

proc safeMcpHeaderValue(value: string): string =
  var safe = value.len > 0 and value[0] notin {' ', '\t'} and
    value[^1] notin {' ', '\t'}
  for character in value:
    let code = character.int
    if code != 9 and (code < 32 or code > 126): safe = false
  if safe and not value.startsWith("=?base64?"): return value
  "=?base64?" & encode(value) & "?="

proc mirroredHeaderValue(value: JsonNode, valueType: string): string =
  if value.isNil or value.kind == JNull: return ""
  case valueType
  of "string":
    if value.kind == JString: result = safeMcpHeaderValue(value.getStr)
  of "integer":
    if value.kind == JInt: result = $value.getInt
  of "boolean":
    if value.kind == JBool:
      result = if value.getBool: "true" else: "false"
  else: discard

proc httpRequestHeaders(client: McpClient, request: JsonNode,
                        methodName: string): HttpHeaders =
  var headers = copyHttpHeaders(client.httpHeaders)
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/json, text/event-stream"
  headers["MCP-Protocol-Version"] = mcpProtocolVersion
  headers["Mcp-Method"] = methodName
  let params = request.optional("params")
  let bodyValues = if params.isNil: newJObject() else: params
  case methodName
  of "tools/call", "resources/read", "prompts/get", "tasks/get",
     "tasks/update", "tasks/cancel":
    let key = if methodName == "tools/call" or methodName == "prompts/get":
      "name" elif methodName == "resources/read": "uri" else: "taskId"
    let value = bodyValues.optional(key)
    if not value.isNil and value.kind == JString:
      headers["Mcp-Name"] = value.getStr
  if methodName == "tools/call" and "name" in bodyValues and
      bodyValues["name"].kind == JString and "arguments" in bodyValues and
      bodyValues["arguments"].kind == JObject:
    let schema = client.toolInputSchemas.getOrDefault(
      bodyValues["name"].getStr)
    for binding in headerBindings(schema):
      let headerValue = mirroredHeaderValue(
        valueAtPath(bodyValues["arguments"], binding.path), binding.valueType)
      if headerValue.len > 0:
        headers["Mcp-Param-" & binding.name] = headerValue
  headers

proc httpRequestAsync(client: McpClient, request: JsonNode,
                      methodName: string): Future[JsonNode] {.async.} =
  let headers = client.httpRequestHeaders(request, methodName)
  let http = newAsyncHttpClient(headers = headers)
  try:
    let response = await http.request(client.httpEndpoint, HttpPost, $request)
    let body = await response.body
    if response.code.int < 200 or response.code.int >= 300:
      try:
        return parseRpcResponse(httpMessage(body))
      except McpClientError as error:
        if error.code != 0: raise
        raise clientFailure("MCP HTTP request failed with status " &
          $response.code.int)
    return parseRpcResponse(httpMessage(body))
  except McpClientError:
    raise
  except CatchableError as error:
    raise clientFailure("MCP HTTP request failed: " & error.msg)
  finally:
    http.close()

proc httpNotifyAsync(client: McpClient, request: JsonNode,
                     methodName: string): Future[void] {.async.} =
  let http = newAsyncHttpClient(headers = client.httpRequestHeaders(
    request, methodName))
  try:
    let response = await http.request(client.httpEndpoint, HttpPost, $request)
    if response.code.int < 200 or response.code.int >= 300:
      raise clientFailure("MCP HTTP notification failed with status " &
        $response.code.int)
    discard await response.body
  except McpClientError:
    raise
  except CatchableError as error:
    raise clientFailure("MCP HTTP notification failed: " & error.msg)
  finally:
    http.close()

proc requestAsync*(client: McpClient, methodName: string,
                   params: JsonNode = nil,
                   options = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## Send a raw MCP request and return its complete result object.
  if client.isNil or client.closed:
    raise clientFailure("MCP client is closed")
  if methodName.len == 0:
    raise clientFailure("MCP method must not be empty")
  let id = client.nextId
  inc client.nextId
  var request = %*{"jsonrpc": "2.0", "id": id, "method": methodName}
  request["params"] = client.requestParams(params, options)
  if client.httpEndpoint.len > 0:
    return await client.httpRequestAsync(request, methodName)
  let future = newFuture[JsonNode]("mcpRequest")
  let key = $id
  client.pending[key] = future
  try:
    await client.input.write($request & "\n")
  except CatchableError as error:
    client.pending.del(key)
    raise clientFailure("MCP stdio write failed: " & error.msg)
  let message = await future
  parseRpcResponse(message)

proc notifyAsync*(client: McpClient, methodName: string,
                  params: JsonNode = nil,
                  options = McpRequestOptions()): Future[void] {.async.} =
  ## Send an MCP notification without waiting for a response.
  if client.isNil or client.closed:
    raise clientFailure("MCP client is closed")
  if methodName.len == 0:
    raise clientFailure("MCP method must not be empty")
  var notification = %*{"jsonrpc": "2.0", "method": methodName}
  notification["params"] = client.requestParams(params, options)
  if client.httpEndpoint.len > 0:
    await client.httpNotifyAsync(notification, methodName)
    return
  try:
    await client.input.write($notification & "\n")
  except CatchableError as error:
    raise clientFailure("MCP stdio write failed: " & error.msg)

proc notify*(client: McpClient, methodName: string,
             params: JsonNode = nil,
             options = McpRequestOptions()) =
  waitFor client.notifyAsync(methodName, params, options)

proc setClientCapabilities*(client: McpClient, capabilities: JsonNode) =
  if client.isNil: raise clientFailure("MCP client must not be nil")
  client.clientCapabilities = requireObject(capabilities,
    "MCP client capabilities")

proc setInputHandler*(client: McpClient, methodName: string,
                      handler: McpInputHandler) =
  if client.isNil: raise clientFailure("MCP client must not be nil")
  if methodName.len == 0 or handler.isNil:
    raise clientFailure("MCP input method and handler must be provided")
  client.inputHandlers[methodName] = handler

proc setElicitationHandler*(client: McpClient, handler: McpInputHandler) =
  client.setInputHandler("elicitation/create", handler)

proc setSamplingHandler*(client: McpClient, handler: McpInputHandler) =
  client.setInputHandler("sampling/createMessage", handler)

proc setRootsHandler*(client: McpClient, handler: McpInputHandler) =
  client.setInputHandler("roots/list", handler)

proc setNotificationHandler*(client: McpClient,
                             handler: McpNotificationHandler) =
  if client.isNil: raise clientFailure("MCP client must not be nil")
  client.notificationHandler = handler

proc setProgressHandler*(client: McpClient, handler: McpProgressHandler) =
  if client.isNil: raise clientFailure("MCP client must not be nil")
  client.progressHandler = handler

proc discoverAsync*(client: McpClient,
                    options = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## Discover and validate the MCP server protocol and metadata.
  let result = await client.requestAsync("server/discover", nil, options)
  let versions = result.getOrDefault("supportedVersions")
  if versions.isNil or versions.kind != JArray or
      mcpProtocolVersion notin versions.mapIt(it.getStr):
    raise clientFailure("MCP server does not support " & mcpProtocolVersion)
  client.discovery = result
  let meta = result.optional("_meta")
  client.serverInfo = meta.optional("io.modelcontextprotocol/serverInfo")
  result

proc pingAsync*(client: McpClient,
                options = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## Check that the connected MCP server is responsive.
  await client.requestAsync("ping", nil, options)

proc ping*(client: McpClient,
           options = McpRequestOptions()): JsonNode =
  waitFor client.pingAsync(options)

proc defaultClientCapabilities(): JsonNode =
  ## Tasks are opt-in on servers, so advertising support is harmless until used.
  %*{"extensions": {"io.modelcontextprotocol/tasks": {}}}

proc initializeClient(client: McpClient, clientName, clientVersion: string,
                      capabilities: JsonNode) =
  if clientName.len == 0 or clientVersion.len == 0:
    raise clientFailure("MCP client name and version must not be empty")
  client.clientName = clientName
  client.clientVersion = clientVersion
  client.clientCapabilities = if capabilities.isNil: defaultClientCapabilities()
    else: requireObject(capabilities, "MCP client capabilities")
  client.nextId = 1
  client.pending = initTable[string, Future[JsonNode]]()
  client.inputHandlers = initTable[string, McpInputHandler]()
  client.toolInputSchemas = initTable[string, JsonNode]()
  client.subscriptions = initTable[string, McpSubscription]()

proc connectMcpHttpAsync*(endpoint: string, bearerToken = "",
                         headers: HttpHeaders = nil,
                         clientName = "nimgent", clientVersion = "0.1.0",
                         clientCapabilities: JsonNode = nil):
                         Future[McpClient] {.async.} =
  ## Connect to a stateless MCP Streamable HTTP endpoint.
  if endpoint.len == 0:
    raise clientFailure("MCP HTTP endpoint must not be empty")
  new(result)
  result.httpEndpoint = endpoint
  result.httpHeaders = copyHttpHeaders(headers)
  if bearerToken.len > 0:
    result.httpHeaders["Authorization"] = "Bearer " & bearerToken
  result.initializeClient(clientName, clientVersion, clientCapabilities)
  try:
    discard await result.discoverAsync()
  except CatchableError:
    result.close()
    raise

proc connectMcpHttp*(endpoint: string, bearerToken = "",
                     headers: HttpHeaders = nil,
                     clientName = "nimgent", clientVersion = "0.1.0",
                     clientCapabilities: JsonNode = nil): McpClient =
  waitFor connectMcpHttpAsync(endpoint, bearerToken, headers, clientName,
    clientVersion, clientCapabilities)

proc connectMcpStreamableHttpAsync*(endpoint: string, bearerToken = "",
                                    headers: HttpHeaders = nil,
                                    clientName = "nimgent", clientVersion = "0.1.0",
                                    clientCapabilities: JsonNode = nil):
                                    Future[McpClient] {.async.} =
  ## Alias with the transport name used by MCP documentation.
  return await connectMcpHttpAsync(endpoint, bearerToken, headers, clientName,
    clientVersion, clientCapabilities)

proc connectMcpStreamableHttp*(endpoint: string, bearerToken = "",
                               headers: HttpHeaders = nil,
                               clientName = "nimgent", clientVersion = "0.1.0",
                               clientCapabilities: JsonNode = nil): McpClient =
  waitFor connectMcpStreamableHttpAsync(endpoint, bearerToken, headers,
    clientName, clientVersion, clientCapabilities)

proc connectMcpStdioAsync*(command: seq[string], workingDir = "",
                           env: StringTableRef = nil,
                           clientName = "nimgent", clientVersion = "0.1.0",
                           clientCapabilities: JsonNode = nil): Future[McpClient] {.async.} =
  ## Start an MCP server process and connect to it over stdio.
  if command.len == 0 or command[0].len == 0:
    raise clientFailure("MCP stdio command must not be empty")
  let args = if command.len > 1: command[1 .. ^1] else: @[]
  var options = {poUsePath}
  when defined(windows):
    options.incl {poDaemon, poInteractive}
  let process = startProcess(command[0], workingDir, args, env, options)
  when not defined(windows):
    makeNonBlocking(process.inputHandle)
    makeNonBlocking(process.outputHandle)
  new(result)
  result.process = process
  result.input = newAsyncFile(AsyncFD(process.inputHandle))
  result.output = newAsyncFile(AsyncFD(process.outputHandle))
  try:
    result.initializeClient(clientName, clientVersion, clientCapabilities)
  except CatchableError:
    result.close()
    raise
  result.nextId = 1
  result.reader = result.readResponses()
  asyncCheck result.reader
  try:
    discard await result.discoverAsync()
  except CatchableError:
    result.close()
    raise

proc connectMcpStdio*(command: seq[string], workingDir = "",
                      env: StringTableRef = nil,
                      clientName = "nimgent", clientVersion = "0.1.0",
                      clientCapabilities: JsonNode = nil): McpClient =
  ## Synchronously start and connect to an MCP server over stdio.
  waitFor connectMcpStdioAsync(command, workingDir, env, clientName,
    clientVersion, clientCapabilities)

proc listPageAsync(client: McpClient, methodName, field, cursor: string,
                   options: McpRequestOptions):
                   Future[(JsonNode, string)] {.async.} =
  var params = newJObject()
  if cursor.len > 0: params["cursor"] = %cursor
  let response = await client.requestAsync(methodName, params, options)
  let items = requireArray(response.optional(field),
    "MCP " & methodName & " '" & field & "'")
  let next = response.optional("nextCursor")
  if not next.isNil and (next.kind != JString or next.getStr.len == 0):
    raise clientFailure("MCP " & methodName & " nextCursor must be a non-empty string")
  (items, if next.isNil: "" else: next.getStr)

proc parseToolInfo(node: JsonNode): McpToolInfo =
  let value = requireObject(node, "MCP tools/list tool")
  let name = value.optional("name")
  let schema = value.optional("inputSchema")
  if name.isNil or name.kind != JString or name.getStr.len == 0:
    raise clientFailure("MCP tool has no name")
  if schema.isNil or schema.kind != JObject:
    raise clientFailure("MCP tool " & name.getStr & " has no inputSchema")
  result = McpToolInfo(name: name.getStr,
    description: value.optionalStringChecked("description", "MCP tool"),
    inputSchema: schema, outputSchema: value.optional("outputSchema"),
    title: value.optionalStringChecked("title", "MCP tool"),
    icons: value.optional("icons"), annotations: value.optional("annotations"))

proc parseResourceInfo(node: JsonNode): McpResourceInfo =
  let value = requireObject(node, "MCP resources/list resource")
  let uri = value.optional("uri")
  let name = value.optional("name")
  if uri.isNil or uri.kind != JString or uri.getStr.len == 0:
    raise clientFailure("MCP resource has no uri")
  if name.isNil or name.kind != JString or name.getStr.len == 0:
    raise clientFailure("MCP resource " & uri.getStr & " has no name")
  let size = value.optional("size")
  if not size.isNil and size.kind != JInt:
    raise clientFailure("MCP resource " & uri.getStr & " size must be an integer")
  result = McpResourceInfo(uri: uri.getStr, name: name.getStr,
    title: value.optionalStringChecked("title", "MCP resource"),
    description: value.optionalStringChecked("description", "MCP resource"),
    icons: value.optional("icons"), mimeType: value.optionalStringChecked(
      "mimeType", "MCP resource"), size: if size.isNil: -1 else: size.getInt,
    annotations: value.optional("annotations"))

proc parseResourceTemplateInfo(node: JsonNode): McpResourceInfo =
  let value = requireObject(node, "MCP resources/templates/list template")
  let uri = value.optional("uriTemplate")
  let name = value.optional("name")
  if uri.isNil or uri.kind != JString or uri.getStr.len == 0:
    raise clientFailure("MCP resource template has no uriTemplate")
  if name.isNil or name.kind != JString or name.getStr.len == 0:
    raise clientFailure("MCP resource template " & uri.getStr & " has no name")
  result = McpResourceInfo(uri: uri.getStr, uriTemplate: uri.getStr,
    name: name.getStr,
    title: value.optionalStringChecked("title", "MCP resource template"),
    description: value.optionalStringChecked("description",
      "MCP resource template"), icons: value.optional("icons"),
    mimeType: value.optionalStringChecked("mimeType", "MCP resource template"),
    size: -1, annotations: value.optional("annotations"))

proc parsePromptInfo(node: JsonNode): McpPromptInfo =
  let value = requireObject(node, "MCP prompts/list prompt")
  let name = value.optional("name")
  if name.isNil or name.kind != JString or name.getStr.len == 0:
    raise clientFailure("MCP prompt has no name")
  result = McpPromptInfo(name: name.getStr,
    title: value.optionalStringChecked("title", "MCP prompt"),
    description: value.optionalStringChecked("description", "MCP prompt"),
    icons: value.optional("icons"))
  let arguments = value.optional("arguments")
  if arguments.isNil: return
  for item in requireArray(arguments, "MCP prompt arguments"):
    let argument = requireObject(item, "MCP prompt argument")
    let argumentName = argument.optional("name")
    if argumentName.isNil or argumentName.kind != JString or
        argumentName.getStr.len == 0:
      raise clientFailure("MCP prompt argument has no name")
    let required = argument.optional("required")
    if not required.isNil and required.kind != JBool:
      raise clientFailure("MCP prompt argument required must be a boolean")
    result.arguments.add McpPromptArgumentInfo(name: argumentName.getStr,
      description: argument.optionalStringChecked("description",
        "MCP prompt argument"), required: if required.isNil: false else:
        required.getBool)

proc listToolsAsync*(client: McpClient,
                     options = McpRequestOptions()): Future[seq[McpToolInfo]] {.async.} =
  ## Discover the tools exposed by the connected MCP server.
  var cursor = ""
  while true:
    let (tools, next) = await client.listPageAsync("tools/list", "tools",
      cursor, options)
    for node in tools:
      let tool = parseToolInfo(node)
      client.toolInputSchemas[tool.name] = tool.inputSchema
      result.add tool
    if next.len == 0: break
    cursor = next

proc listTools*(client: McpClient,
                options = McpRequestOptions()): seq[McpToolInfo] =
  ## Synchronously discover the connected server's tools.
  waitFor client.listToolsAsync(options)

proc listResourcesAsync*(client: McpClient,
                         options = McpRequestOptions()):
                         Future[seq[McpResourceInfo]] {.async.} =
  ## Discover all static MCP resources, following pagination cursors.
  var cursor = ""
  while true:
    let (resources, next) = await client.listPageAsync("resources/list",
      "resources", cursor, options)
    for node in resources: result.add parseResourceInfo(node)
    if next.len == 0: break
    cursor = next

proc listResources*(client: McpClient,
                    options = McpRequestOptions()): seq[McpResourceInfo] =
  waitFor client.listResourcesAsync(options)

proc listResourceTemplatesAsync*(client: McpClient,
                                options = McpRequestOptions()):
                                Future[seq[McpResourceInfo]] {.async.} =
  ## Discover all URI-template resources, following pagination cursors.
  var cursor = ""
  while true:
    let (templates, next) = await client.listPageAsync(
      "resources/templates/list", "resourceTemplates", cursor, options)
    for node in templates: result.add parseResourceTemplateInfo(node)
    if next.len == 0: break
    cursor = next

proc listResourceTemplates*(client: McpClient,
                            options = McpRequestOptions()): seq[McpResourceInfo] =
  waitFor client.listResourceTemplatesAsync(options)

proc listPromptsAsync*(client: McpClient,
                       options = McpRequestOptions()): Future[seq[McpPromptInfo]] {.async.} =
  ## Discover all MCP prompts, following pagination cursors.
  var cursor = ""
  while true:
    let (prompts, next) = await client.listPageAsync("prompts/list", "prompts",
      cursor, options)
    for node in prompts: result.add parsePromptInfo(node)
    if next.len == 0: break
    cursor = next

proc listPrompts*(client: McpClient,
                  options = McpRequestOptions()): seq[McpPromptInfo] =
  waitFor client.listPromptsAsync(options)

proc parseInputRequest(key: string, node: JsonNode): McpInputRequest =
  let value = requireObject(node, "MCP input request")
  let methodName = value.optional("method")
  if methodName.isNil or methodName.kind != JString or methodName.getStr.len == 0:
    raise clientFailure("MCP input request has no method")
  if methodName.getStr notin ["elicitation/create", "sampling/createMessage",
                              "roots/list"]:
    raise clientFailure("MCP input request method is not supported: " &
      methodName.getStr)
  let params = value.optional("params")
  if not params.isNil and params.kind != JObject:
    raise clientFailure("MCP input request params must be an object")
  McpInputRequest(key: key, methodName: methodName.getStr,
    params: if params.isNil: newJObject() else: params, raw: value)

proc parseInputRequests(node: JsonNode): seq[McpInputRequest] =
  if node.isNil: return
  for key, value in requireObject(node, "MCP inputRequests"):
    if key.len == 0: raise clientFailure("MCP input request keys must not be empty")
    result.add parseInputRequest(key, value)

proc parseTaskInfo(node: JsonNode): McpTaskInfo =
  let value = requireObject(node, "MCP task")
  let id = value.optional("taskId")
  let status = value.optional("status")
  if id.isNil or id.kind != JString or id.getStr.len == 0:
    raise clientFailure("MCP task has no taskId")
  if status.isNil or status.kind != JString or status.getStr.len == 0:
    raise clientFailure("MCP task has no status")
  let pollInterval = value.optional("pollIntervalMs")
  if not pollInterval.isNil and pollInterval.kind != JInt:
    raise clientFailure("MCP task pollIntervalMs must be an integer")
  result = McpTaskInfo(taskId: id.getStr, status: status.getStr,
    statusMessage: value.optionalStringChecked("statusMessage", "MCP task"),
    createdAt: value.optionalStringChecked("createdAt", "MCP task"),
    lastUpdatedAt: value.optionalStringChecked("lastUpdatedAt", "MCP task"),
    pollIntervalMs: if pollInterval.isNil: 0 else: pollInterval.getInt,
    inputRequests: value.optional("inputRequests"),
    result: value.optional("result"), error: value.optional("error"), raw: value)
  let ttl = value.optional("ttlMs")
  if not ttl.isNil and ttl.kind != JNull:
    if ttl.kind != JInt: raise clientFailure("MCP task ttlMs must be an integer")
    result.ttlMs = ttl.getInt.int64
  let progress = value.optional("progress")
  if not progress.isNil:
    if progress.kind notin {JInt, JFloat}:
      raise clientFailure("MCP task progress must be a number")
    result.progress = progress.getFloat
    result.hasProgress = true
  let total = value.optional("total")
  if not total.isNil:
    if total.kind notin {JInt, JFloat}:
      raise clientFailure("MCP task total must be a number")
    result.total = total.getFloat
    result.hasTotal = true

proc parseCallResult(node: JsonNode): McpCallResult =
  let value = requireObject(node, "MCP result")
  let resultType = value.optional("resultType")
  if resultType.isNil or resultType.kind != JString:
    raise clientFailure("MCP result has no resultType")
  result.resultType = resultType.getStr
  result.content = value.optional("content")
  result.structuredContent = value.optional("structuredContent")
  let isError = value.optional("isError")
  if not isError.isNil and isError.kind != JBool:
    raise clientFailure("MCP result isError must be a boolean")
  result.isError = not isError.isNil and isError.getBool
  result.inputRequests = value.optional("inputRequests")
  let state = value.optional("requestState")
  if not state.isNil:
    if state.kind != JString: raise clientFailure("MCP requestState must be a string")
    result.requestState = state.getStr
  if result.resultType == "task": result.task = parseTaskInfo(value)
  result.raw = value

proc requestWithInputAsync*(client: McpClient, methodName: string,
                            params: JsonNode = nil,
                            options = McpRequestOptions(),
                            maxInputRounds = 8): Future[JsonNode] {.async.} =
  ## Complete stateless input-required retries with the configured handlers.
  if maxInputRounds < 0:
    raise clientFailure("maxInputRounds must not be negative")
  var values = if params.isNil: newJObject() else: copy(params)
  var round = 0
  while true:
    let response = await client.requestAsync(methodName, values, options)
    if response.optionalString("resultType") != "input_required": return response
    if round >= maxInputRounds:
      raise clientFailure("MCP input round limit exceeded")
    let requests = parseInputRequests(response.optional("inputRequests"))
    if requests.len == 0: return response
    var responses = if "inputResponses" in values and
        values["inputResponses"].kind == JObject:
      copy(values["inputResponses"]) else: newJObject()
    for request in requests:
      if request.methodName notin client.inputHandlers: return response
    for request in requests:
      let responseValue = client.inputHandlers[request.methodName](request)
      if responseValue.isNil or responseValue.kind != JObject:
        raise clientFailure("MCP input handler must return an object")
      responses[request.key] = responseValue
    values["inputResponses"] = responses
    let requestState = response.optionalString("requestState")
    if requestState.len > 0: values["requestState"] = %requestState
    else: values.delete("requestState")
    inc round

proc requestWithInput*(client: McpClient, methodName: string,
                       params: JsonNode = nil,
                       options = McpRequestOptions(),
                       maxInputRounds = 8): JsonNode =
  waitFor client.requestWithInputAsync(methodName, params, options,
    maxInputRounds)

proc resourceContent(node: JsonNode): McpResourceContent =
  let value = requireObject(node, "MCP resource content")
  let uri = value.optional("uri")
  if uri.isNil or uri.kind != JString or uri.getStr.len == 0:
    raise clientFailure("MCP resource content has no uri")
  let text = value.optional("text")
  let blob = value.optional("blob")
  if (text.isNil) == (blob.isNil):
    raise clientFailure("MCP resource content requires text or blob")
  if not text.isNil and text.kind != JString:
    raise clientFailure("MCP resource text must be a string")
  if not blob.isNil and blob.kind != JString:
    raise clientFailure("MCP resource blob must be a string")
  McpResourceContent(uri: uri.getStr,
    mimeType: value.optionalStringChecked("mimeType", "MCP resource content"),
    text: if text.isNil: "" else: text.getStr,
    blob: if blob.isNil: "" else: blob.getStr, isBlob: not blob.isNil, raw: value)

proc readResourceAsync*(client: McpClient, uri: string,
                        options = McpRequestOptions()):
                        Future[McpResourceReadResult] {.async.} =
  ## Read a static resource or URI-template instance.
  let response = await client.requestWithInputAsync("resources/read",
    %*{"uri": uri}, options)
  result.resultType = response.optionalString("resultType")
  result.inputRequests = response.optional("inputRequests")
  result.requestState = response.optionalString("requestState")
  result.raw = response
  if result.resultType != "complete": return
  let contents = requireArray(response.optional("contents"),
    "MCP resources/read contents")
  result.ttlMs = if response.optional("ttlMs").isNil: 0 else:
    response["ttlMs"].getInt.int64
  result.cacheScope = response.optionalStringChecked("cacheScope",
    "MCP resources/read")
  for item in contents: result.contents.add resourceContent(item)

proc readResource*(client: McpClient, uri: string,
                   options = McpRequestOptions()): McpResourceReadResult =
  waitFor client.readResourceAsync(uri, options)

proc readResourceContentsAsync*(client: McpClient, uri: string,
                                options = McpRequestOptions()):
                                Future[seq[McpResourceContent]] {.async.} =
  let value = await client.readResourceAsync(uri, options)
  value.contents

proc readResourceContents*(client: McpClient, uri: string,
                           options = McpRequestOptions()): seq[McpResourceContent] =
  waitFor client.readResourceContentsAsync(uri, options)

proc parsePromptMessage(node: JsonNode): McpPromptMessage =
  let value = requireObject(node, "MCP prompt message")
  let role = value.optional("role")
  if role.isNil or role.kind != JString or role.getStr.len == 0:
    raise clientFailure("MCP prompt message has no role")
  if "content" notin value: raise clientFailure("MCP prompt message has no content")
  result = McpPromptMessage(role: role.getStr, content: value["content"], raw: value)

proc getPromptAsync*(client: McpClient, name: string,
                     arguments: JsonNode = nil,
                     options = McpRequestOptions()): Future[McpPromptResult] {.async.} =
  ## Render a prompt with its string arguments.
  let response = await client.requestWithInputAsync("prompts/get", %*{
    "name": name,
    "arguments": if arguments.isNil: newJObject() else: arguments
  }, options)
  result.resultType = response.optionalString("resultType")
  result.inputRequests = response.optional("inputRequests")
  result.requestState = response.optionalString("requestState")
  result.raw = response
  if result.resultType != "complete": return
  let messages = requireArray(response.optional("messages"),
    "MCP prompts/get messages")
  result.description = response.optionalStringChecked("description",
    "MCP prompts/get")
  for item in messages: result.messages.add parsePromptMessage(item)

proc getPrompt*(client: McpClient, name: string, arguments: JsonNode = nil,
                options = McpRequestOptions()): McpPromptResult =
  waitFor client.getPromptAsync(name, arguments, options)

proc completeAsync*(client: McpClient, reference: JsonNode,
                    argument: string, prefix: string,
                    contextArguments: JsonNode = nil,
                    options = McpRequestOptions()):
                    Future[McpCompletionResult] {.async.} =
  ## Complete a prompt or resource-template argument.
  var params = %*{"ref": reference, "argument": {"name": argument,
    "value": prefix}}
  if not contextArguments.isNil:
    params["context"] = %*{"arguments": contextArguments}
  let response = await client.requestAsync("completion/complete", params,
    options)
  let completion = requireObject(response.optional("completion"),
    "MCP completion")
  let values = requireArray(completion.optional("values"),
    "MCP completion values")
  result.total = if completion.optional("total").isNil: values.len else:
    completion["total"].getInt
  result.hasMore = completion.optionalBool("hasMore")
  result.raw = response
  for value in values:
    if value.kind != JString: raise clientFailure("MCP completion values must be strings")
    result.values.add value.getStr

proc complete*(client: McpClient, reference: JsonNode, argument, prefix: string,
               contextArguments: JsonNode = nil,
               options = McpRequestOptions()): McpCompletionResult =
  waitFor client.completeAsync(reference, argument, prefix, contextArguments,
    options)

proc completePromptArgumentAsync*(client: McpClient, prompt, argument,
                                  prefix: string,
                                  contextArguments: JsonNode = nil,
                                  options = McpRequestOptions()):
                                  Future[McpCompletionResult] {.async.} =
  return await client.completeAsync(%*{"type": "ref/prompt", "name": prompt},
    argument, prefix, contextArguments, options)

proc completeResourceArgumentAsync*(client: McpClient, uriTemplate, argument,
                                   prefix: string,
                                   contextArguments: JsonNode = nil,
                                   options = McpRequestOptions()):
                                   Future[McpCompletionResult] {.async.} =
  return await client.completeAsync(%*{"type": "ref/resource",
    "uri": uriTemplate}, argument, prefix, contextArguments, options)

proc completePromptArgument*(client: McpClient, prompt, argument, prefix: string,
                             contextArguments: JsonNode = nil,
                             options = McpRequestOptions()): McpCompletionResult =
  waitFor client.completePromptArgumentAsync(prompt, argument, prefix,
    contextArguments, options)

proc completeResourceArgument*(client: McpClient, uriTemplate, argument,
                              prefix: string,
                              contextArguments: JsonNode = nil,
                              options = McpRequestOptions()): McpCompletionResult =
  waitFor client.completeResourceArgumentAsync(uriTemplate, argument, prefix,
    contextArguments, options)

proc callToolAsync*(client: McpClient, name: string,
                    arguments: JsonNode = nil,
                    options = McpRequestOptions()): Future[McpCallResult] {.async.} =
  ## Call a remote MCP tool asynchronously.
  let result = await client.requestWithInputAsync("tools/call", %*{
    "name": name,
    "arguments": if arguments.isNil: newJObject() else: arguments
  }, options)
  parseCallResult(result)

proc callTool*(client: McpClient, name: string,
               arguments: JsonNode = nil,
               options = McpRequestOptions()): McpCallResult =
  ## Synchronously call a remote MCP tool.
  waitFor client.callToolAsync(name, arguments, options)

proc getTaskAsync*(client: McpClient, taskId: string,
                   options = McpRequestOptions()): Future[McpTaskInfo] {.async.} =
  ## Read the current state of a task returned by a tool call.
  let response = await client.requestAsync("tasks/get", %*{"taskId": taskId},
    options)
  if response.optionalString("resultType") != "complete":
    raise clientFailure("MCP tasks/get did not return a complete result")
  parseTaskInfo(response)

proc getTask*(client: McpClient, taskId: string,
              options = McpRequestOptions()): McpTaskInfo =
  waitFor client.getTaskAsync(taskId, options)

proc updateTaskAsync*(client: McpClient, taskId: string,
                      inputResponses: JsonNode,
                      requestState = "",
                      options = McpRequestOptions()): Future[void] {.async.} =
  ## Supply responses for pending task input and resume the task.
  let responses = requireObject(inputResponses, "MCP task inputResponses")
  var params = %*{"taskId": taskId, "inputResponses": responses}
  if requestState.len > 0: params["requestState"] = %requestState
  let response = await client.requestAsync("tasks/update", params, options)
  if response.optionalString("resultType") != "complete":
    raise clientFailure("MCP tasks/update did not return a complete result")

proc updateTask*(client: McpClient, taskId: string, inputResponses: JsonNode,
                 requestState = "", options = McpRequestOptions()) =
  waitFor client.updateTaskAsync(taskId, inputResponses, requestState, options)

proc cancelTaskAsync*(client: McpClient, taskId: string,
                      options = McpRequestOptions()): Future[void] {.async.} =
  ## Cancel a running task.
  let response = await client.requestAsync("tasks/cancel", %*{"taskId": taskId},
    options)
  if response.optionalString("resultType") != "complete":
    raise clientFailure("MCP tasks/cancel did not return a complete result")

proc cancelTask*(client: McpClient, taskId: string,
                 options = McpRequestOptions()) =
  waitFor client.cancelTaskAsync(taskId, options)

proc cancelRequestAsync*(client: McpClient, requestId: int,
                         reason = "",
                         options = McpRequestOptions()): Future[void] {.async.} =
  ## Ask the server to cancel an in-flight request or subscription.
  var params = %*{"requestId": requestId}
  if reason.len > 0: params["reason"] = %reason
  await client.notifyAsync("notifications/cancelled", params, options)

proc cancelRequest*(client: McpClient, requestId: int, reason = "",
                    options = McpRequestOptions()) =
  waitFor client.cancelRequestAsync(requestId, reason, options)

proc subscriptionFilterJson(filter: McpSubscriptionFilter): JsonNode =
  result = newJObject()
  if filter.toolsListChanged: result["toolsListChanged"] = %true
  if filter.promptsListChanged: result["promptsListChanged"] = %true
  if filter.resourcesListChanged: result["resourcesListChanged"] = %true
  if filter.resourceSubscriptions.len > 0:
    result["resourceSubscriptions"] = newJArray()
    for uri in filter.resourceSubscriptions:
      result["resourceSubscriptions"].add %uri

proc newMcpSubscription(client: McpClient, id: int,
                        filter: McpSubscriptionFilter,
                        handler: McpSubscriptionMessageHandler): McpSubscription =
  McpSubscription(id: id, filter: filter, queue: newFutureStream[JsonNode](
    "mcpSubscription"), acknowledged: newFuture[JsonNode]("mcpAcknowledged"),
    closed: newFuture[void]("mcpSubscriptionClosed"), client: client,
    handler: handler, active: true)

proc readHttpSubscription(client: McpClient, subscription: McpSubscription,
                          response: AsyncResponse): Future[void] {.async.} =
  var buffer = ""
  try:
    while true:
      let (more, chunk) = await response.bodyStream.read()
      if not more: break
      buffer.add chunk
      while true:
        let newline = buffer.find('\n')
        if newline < 0: break
        let line = buffer[0 ..< newline].strip
        buffer = if newline + 1 < buffer.len: buffer[newline + 1 .. ^1] else: ""
        if line.startsWith("data:") and line.len > 5:
          let message = parseJson(line[5 .. ^1].strip)
          if "id" in message: client.deliverResponse(message)
          else: client.deliverNotification(message)
    let line = buffer.strip
    if line.startsWith("data:") and line.len > 5:
      let message = parseJson(line[5 .. ^1].strip)
      if "id" in message: client.deliverResponse(message)
      else: client.deliverNotification(message)
  except CatchableError:
    discard
  finally:
    let key = $subscription.id
    if key in client.subscriptions:
      subscription.finishSubscription()
      client.subscriptions.del(key)
    if not subscription.httpClient.isNil:
      subscription.httpClient.close()

proc read*(subscription: McpSubscription): Future[(bool, JsonNode)] =
  if subscription.isNil:
    raise clientFailure("MCP subscription must not be nil")
  subscription.queue.read()

proc waitAcknowledged*(subscription: McpSubscription): Future[JsonNode] =
  if subscription.isNil:
    raise clientFailure("MCP subscription must not be nil")
  subscription.acknowledged

proc waitClosed*(subscription: McpSubscription): Future[void] =
  if subscription.isNil:
    raise clientFailure("MCP subscription must not be nil")
  subscription.closed

proc isActive*(subscription: McpSubscription): bool =
  not subscription.isNil and subscription.active

proc subscribeAsync*(client: McpClient, filter: McpSubscriptionFilter,
                     handler: McpSubscriptionMessageHandler = nil):
                     Future[McpSubscription] {.async.} =
  ## Open a live tools, prompts, or resources change stream.
  if client.isNil or client.closed:
    raise clientFailure("MCP client is closed")
  let id = client.nextId
  inc client.nextId
  let subscription = newMcpSubscription(client, id, filter, handler)
  let key = $id
  client.subscriptions[key] = subscription
  try:
    var request = %*{"jsonrpc": "2.0", "id": id,
      "method": "subscriptions/listen"}
    request["params"] = client.requestParams(%*{
      "notifications": subscriptionFilterJson(filter)
    }, McpRequestOptions())
    if client.httpEndpoint.len > 0:
      let http = newAsyncHttpClient(headers = client.httpRequestHeaders(
        request, "subscriptions/listen"))
      subscription.httpClient = http
      let response = await http.request(client.httpEndpoint, HttpPost, $request)
      if response.code.int < 200 or response.code.int >= 300:
        let body = await response.body
        raise clientFailure("MCP HTTP subscription failed with status " &
          $response.code.int & ": " & body)
      subscription.httpTask = client.readHttpSubscription(subscription, response)
      asyncCheck subscription.httpTask
    else:
      await client.input.write($request & "\n")
    let acknowledgment = await subscription.acknowledged
    if acknowledgment.isNil or acknowledgment.kind != JObject:
      raise clientFailure("MCP subscription was closed before acknowledgment")
    if "error" in acknowledgment:
      let errorNode = acknowledgment["error"]
      raise clientFailure(errorNode.getOrDefault("message").getStr,
        errorNode.getOrDefault("code").getInt,
        errorNode.getOrDefault("data"))
    return subscription
  except CatchableError:
    subscription.finishSubscription()
    if key in client.subscriptions: client.subscriptions.del(key)
    raise

proc subscribe*(client: McpClient, filter: McpSubscriptionFilter,
                handler: McpSubscriptionMessageHandler = nil): McpSubscription =
  waitFor client.subscribeAsync(filter, handler)

proc subscribeAsync*(client: McpClient, notifications: JsonNode,
                     handler: McpSubscriptionMessageHandler = nil):
                     Future[McpSubscription] {.async.} =
  let value = requireObject(notifications, "MCP subscription notifications")
  var filter = McpSubscriptionFilter()
  for key, item in value.pairs:
    case key
    of "toolsListChanged":
      if item.kind != JBool: raise clientFailure("MCP subscription flag must be boolean")
      filter.toolsListChanged = item.getBool
    of "promptsListChanged":
      if item.kind != JBool: raise clientFailure("MCP subscription flag must be boolean")
      filter.promptsListChanged = item.getBool
    of "resourcesListChanged":
      if item.kind != JBool: raise clientFailure("MCP subscription flag must be boolean")
      filter.resourcesListChanged = item.getBool
    of "resourceSubscriptions":
      for uri in requireArray(item, "MCP resource subscriptions"):
        if uri.kind != JString or uri.getStr.len == 0:
          raise clientFailure("MCP resource subscription URI must be a string")
        filter.resourceSubscriptions.add uri.getStr
    else: discard
  return await client.subscribeAsync(filter, handler)

proc subscribe*(client: McpClient, notifications: JsonNode,
                handler: McpSubscriptionMessageHandler = nil): McpSubscription =
  waitFor client.subscribeAsync(notifications, handler)

proc contentText(content: JsonNode): string =
  if content.isNil or content.kind != JArray: return ""
  for item in content:
    if item.kind == JObject and item.getOrDefault("type").getStr == "text":
      if result.len > 0: result.add "\n"
      result.add item.getOrDefault("text").getStr

proc asToolsAsync*(client: McpClient, prefix = ""): Future[seq[Tool]] {.async.} =
  ## Adapt discovered MCP tools into executable nimgent tools.
  let infos = await client.listToolsAsync()
  for info in infos:
    let remote = info
    let remoteClient = client
    let localName = prefix & remote.name
    result.add Tool(
      name: localName,
      description: remote.description,
      inputSchema: remote.inputSchema,
      executeAsync: proc (_: ToolContext, input: JsonNode): Future[ToolResult]
          {.async.} =
        let output = await remoteClient.callToolAsync(remote.name, input)
        let text = contentText(output.content)
        let rendered = if text.len > 0: text
                       elif not output.structuredContent.isNil:
                         $output.structuredContent
                       elif output.resultType == "task":
                         $output.task.raw
                       elif output.resultType == "input_required":
                         $output.raw
                       else: ""
        if output.isError:
          return ToolResult(output: rendered, isError: true,
            error: ToolError(code: "mcp_tool_error", message: rendered))
        ToolResult(output: rendered,
          value: if output.resultType == "task": output.task.raw
                 else: output.structuredContent)
    )

proc asTools*(client: McpClient, prefix = ""): seq[Tool] =
  ## Synchronously adapt discovered MCP tools into executable tools.
  waitFor client.asToolsAsync(prefix)

proc closeAsync*(subscription: McpSubscription): Future[void] {.async.} =
  ## Stop a live MCP subscription and release its local event stream.
  if subscription.isNil or not subscription.active: return
  let client = subscription.client
  let key = $subscription.id
  try:
    if not client.isNil and not client.closed:
      await client.cancelRequestAsync(subscription.id)
  finally:
    subscription.finishSubscription()
    if not client.isNil and key in client.subscriptions:
      client.subscriptions.del(key)
    if not subscription.httpClient.isNil:
      subscription.httpClient.close()

proc close*(subscription: McpSubscription) =
  if not subscription.isNil and subscription.active:
    asyncCheck subscription.closeAsync()

proc close*(client: McpClient) =
  ## Close the MCP process and fail any pending requests.
  if client.isNil or client.closed: return
  client.closed = true
  client.failPending(clientFailure("MCP client closed"))
  for _, subscription in client.subscriptions.mpairs:
    subscription.finishSubscription()
  client.subscriptions.clear()
  if client.httpEndpoint.len > 0: return
  try:
    unregister(AsyncFD(client.process.inputHandle))
    unregister(AsyncFD(client.process.outputHandle))
    client.process.close()
  except CatchableError:
    discard
