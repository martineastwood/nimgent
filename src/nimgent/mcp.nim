## MCP 2026-07-28 client over stdio.
##
## The client deliberately pins the modern stateless revision. It discovers
## the server first, then adapts remote tools to nimgent's normal Tool type.

import std/[asyncdispatch, asyncfile, json, osproc, sequtils, strtabs,
  strutils, tables]
when not defined(windows):
  import posix
import nimwire
import nimgent/providers/provider
export nimwire

type
  McpClientError* = object of CatchableError
    code*: int
    data*: JsonNode

  McpToolInfo* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    outputSchema*: JsonNode

  McpCallResult* = object
    content*: JsonNode
    structuredContent*: JsonNode
    isError*: bool

  McpClient* = ref object
    process: Process
    input: AsyncFile
    output: AsyncFile
    pending: Table[string, Future[JsonNode]]
    nextId: int
    reader: Future[void]
    closed: bool
    serverInfo*: JsonNode
    discovery*: JsonNode

proc close*(client: McpClient)

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

proc requestKey(id: JsonNode): string =
  if id.isNil: return "null"
  $id

proc optional(node: JsonNode, key: string): JsonNode =
  if not node.isNil and key in node: node[key] else: nil

proc failPending(client: McpClient, error: ref CatchableError) =
  for _, future in client.pending.mpairs:
    if not future.finished:
      future.fail(error)
  client.pending.clear()

proc readResponses(client: McpClient) {.async.} =
  var failure: ref CatchableError
  try:
    while not client.closed:
      let line = await client.output.readLine()
      if line.len == 0:
        failure = clientFailure("MCP server closed stdout")
        break
      let message = parseJson(line)
      if "id" notin message: continue
      let key = requestKey(message["id"])
      if key in client.pending:
        let future = client.pending[key]
        client.pending.del(key)
        if not future.finished:
          future.complete(message)
  except CatchableError as error:
    failure = clientFailure("MCP stdio reader failed: " & error.msg)
  if not client.closed and not failure.isNil:
    client.failPending(failure)

proc requestParams(client: McpClient, params: JsonNode): JsonNode =
  result = if params.isNil: newJObject() else: copy(params)
  if result.kind != JObject:
    raise clientFailure("MCP request params must be an object")
  var meta = if "_meta" in result and result["_meta"].kind == JObject:
    copy(result["_meta"])
  else:
    newJObject()
  meta["io.modelcontextprotocol/protocolVersion"] = %mcpProtocolVersion
  meta["io.modelcontextprotocol/clientInfo"] = %*{
    "name": "nimgent",
    "version": "0.1.0"
  }
  meta["io.modelcontextprotocol/clientCapabilities"] = newJObject()
  result["_meta"] = meta

proc requestAsync*(client: McpClient, methodName: string,
                   params: JsonNode = nil): Future[JsonNode] {.async.} =
  if client.isNil or client.closed:
    raise clientFailure("MCP client is closed")
  if methodName.len == 0:
    raise clientFailure("MCP method must not be empty")
  let id = client.nextId
  inc client.nextId
  let future = newFuture[JsonNode]("mcpRequest")
  let key = $id
  client.pending[key] = future
  var request = %*{"jsonrpc": "2.0", "id": id, "method": methodName}
  request["params"] = client.requestParams(params)
  try:
    await client.input.write($request & "\n")
  except CatchableError as error:
    client.pending.del(key)
    raise clientFailure("MCP stdio write failed: " & error.msg)
  let message = await future
  if "error" in message:
    let errorNode = message["error"]
    let code = errorNode.getOrDefault("code").getInt
    let detail = errorNode.getOrDefault("data")
    raise clientFailure(errorNode.getOrDefault("message").getStr,
      code, if detail.isNil or detail.kind == JNull: nil else: detail)
  if "result" notin message or message["result"].kind != JObject:
    raise clientFailure("MCP response has no result object")
  let resultNode = message["result"]
  let resultType = resultNode.optional("resultType")
  if resultType.isNil or resultType.kind != JString or resultType.getStr != "complete":
    raise clientFailure("MCP result is not complete: " &
      (if resultType.isNil: "missing" else: $resultType))
  resultNode

proc discoverAsync*(client: McpClient): Future[JsonNode] {.async.} =
  let result = await client.requestAsync("server/discover")
  let versions = result.getOrDefault("supportedVersions")
  if versions.isNil or versions.kind != JArray or
      mcpProtocolVersion notin versions.mapIt(it.getStr):
    raise clientFailure("MCP server does not support " & mcpProtocolVersion)
  client.discovery = result
  let meta = result.optional("_meta")
  client.serverInfo = meta.optional("io.modelcontextprotocol/serverInfo")
  result

proc connectMcpStdioAsync*(command: seq[string], workingDir = "",
                           env: StringTableRef = nil): Future[McpClient] {.async.} =
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
  result.pending = initTable[string, Future[JsonNode]]()
  result.nextId = 1
  result.reader = result.readResponses()
  asyncCheck result.reader
  try:
    discard await result.discoverAsync()
  except CatchableError:
    result.close()
    raise

proc connectMcpStdio*(command: seq[string], workingDir = "",
                      env: StringTableRef = nil): McpClient =
  waitFor connectMcpStdioAsync(command, workingDir, env)

proc listToolsAsync*(client: McpClient): Future[seq[McpToolInfo]] {.async.} =
  let response = await client.requestAsync("tools/list")
  let tools = response.getOrDefault("tools")
  if tools.isNil or tools.kind != JArray:
    raise clientFailure("MCP tools/list returned no tools array")
  for node in tools:
    if node.kind != JObject:
      raise clientFailure("MCP tools/list returned a non-object tool")
    let name = node.getOrDefault("name")
    let schema = node.getOrDefault("inputSchema")
    if name.kind != JString or name.getStr.len == 0:
      raise clientFailure("MCP tool has no name")
    if schema.isNil or schema.kind != JObject:
      raise clientFailure("MCP tool " & name.getStr & " has no inputSchema")
    let description = node.optional("description")
    result.add McpToolInfo(
      name: name.getStr,
      description: if description.isNil or description.kind != JString:
        ""
      else:
        description.getStr,
      inputSchema: schema,
      outputSchema: node.optional("outputSchema"))

proc listTools*(client: McpClient): seq[McpToolInfo] =
  waitFor client.listToolsAsync()

proc callToolAsync*(client: McpClient, name: string,
                    arguments: JsonNode = nil): Future[McpCallResult] {.async.} =
  let result = await client.requestAsync("tools/call", %*{
    "name": name,
    "arguments": if arguments.isNil: newJObject() else: arguments
  })
  let isError = result.optional("isError")
  return McpCallResult(
    content: result.optional("content"),
    structuredContent: result.optional("structuredContent"),
    isError: not isError.isNil and isError.kind == JBool and isError.getBool)

proc callTool*(client: McpClient, name: string,
               arguments: JsonNode = nil): McpCallResult =
  waitFor client.callToolAsync(name, arguments)

proc contentText(content: JsonNode): string =
  if content.isNil or content.kind != JArray: return ""
  for item in content:
    if item.kind == JObject and item.getOrDefault("type").getStr == "text":
      if result.len > 0: result.add "\n"
      result.add item.getOrDefault("text").getStr

proc asToolsAsync*(client: McpClient, prefix = ""): Future[seq[Tool]] {.async.} =
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
                       else: ""
        if output.isError:
          return ToolResult(output: rendered, isError: true,
            error: ToolError(code: "mcp_tool_error", message: rendered))
        ToolResult(output: rendered, value: output.structuredContent)
    )

proc asTools*(client: McpClient, prefix = ""): seq[Tool] =
  waitFor client.asToolsAsync(prefix)

proc close*(client: McpClient) =
  if client.isNil or client.closed: return
  client.closed = true
  client.failPending(clientFailure("MCP client closed"))
  try:
    client.process.close()
  except CatchableError:
    discard
