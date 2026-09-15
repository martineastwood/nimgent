---
title: MCP client
description: Use tools, resources, prompts, and tasks from an MCP server.
---

[MCP](https://modelcontextprotocol.io) is a protocol for handing tools and other
capabilities to an application at runtime rather than at compile time. A server
declares its tools, resources, prompts, and JSON Schemas; the client discovers
them and uses them. nimgent is the client.

That matters because it inverts the usual flow. Instead of writing a Nim
function and persuading a model to call it, you point nimgent at a server
someone else wrote - a file system, a database, an internal service - and its
tools become available to your agent. Capabilities you did not compile in still
reach the model.

## Connect

Everything lives in `nimgent/mcp`. Use stdio when nimgent should spawn a local
server process, or Streamable HTTP for a server that already has an endpoint.

```nim
import std/[asyncdispatch, json, os, sequtils, strutils]
import nimgent/mcp

proc main() {.async.} =
  let client = await connectMcpStdioAsync(
    @["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
  defer: client.close()

  let tools = await client.listToolsAsync()
  echo "discovered: ", tools.mapIt(it.name).join(", ")

waitFor main()
```

For Streamable HTTP, connect to the server endpoint directly. The optional
second argument is a bearer token.

```nim
let client = await connectMcpHttpAsync(
  "https://mcp.example.com/mcp", bearerToken = getEnv("MCP_TOKEN"))
defer: client.close()
```

The first element of the command is the program, the rest are arguments.
`connectMcpStdioAsync` also takes a working directory and an environment table
(`env: StringTableRef`), so a server can be launched with its own config without
mutating your process environment.

`connectMcpStdio` is the blocking twin for scripts. Both complete the handshake
before returning; if it fails, the process is closed and the error propagates
rather than leaving a half-open client behind.

## What the handshake does

The client pins the modern stateless revision, `mcpProtocolVersion`
(`2026-07-28`), and will not drift to whatever else the server would accept.
Connecting means:

1. `server/discover` - the server reports the versions it supports.
2. nimgent checks the pinned version is among them, and fails loudly if not.
3. The server's identity and full discovery document are kept on the client as
   `client.serverInfo` and `client.discovery`.

There is deliberately **no fallback** to the older `initialize`/session
handshake. A server that has removed it is one nimgent cannot talk to, and you
get an `McpClientError` saying so instead of a protocol mismatch halfway
through a run. Every request also carries the protocol version, client name,
and client capabilities in its `_meta`. `requestAsync` accepts complete,
input-required, and task results. High-level calls automatically retry
input-required results when you configure the matching input handler.

## Call a tool directly

You do not need an agent to use MCP. Discovery and invocation are ordinary
calls:

```nim
let result = await client.callToolAsync("read_file", %*{"path": "/tmp/notes.md"})
echo result.content           # the raw MCP content array
echo result.structuredContent # structured output, when the server sends it
echo result.isError
```

`McpCallResult` keeps the server's answer close to the wire: `content` is the
content array as sent, `structuredContent` is the optional structured form, and
`isError` is the server's own error flag. Tool failures come back as results, not
exceptions.

## Hand the tools to an agent

`asToolsAsync` converts the discovered list into ordinary nimgent `Tool` values -
each one carrying the server's schema and description, with execution routed
back over the client:

```nim
let remoteTools = await client.asToolsAsync(prefix = "fs_")

let assistant = newAgent(
  model,
  instructions = "You answer questions about the user's files.",
  tools = remoteTools,
  maxSteps = 5)

echo assistant.run("What is in notes.md?").text
```

Past that call, nothing is special. Remote tools go through the same argument
validation, the same failure handling, and the same traces as local ones. Text
content is joined into the model-facing output; when the server sends only
structured content, that is serialized instead. A call the server reports as an
error becomes a tool failure with code `mcp_tool_error`, which the model can read
and react to.

Use `prefix` when the server's names are generic (`read`, `search`) and could
collide with your own tools. The prefix applies to the local name only - the
server still sees its original name on the wire - and names must stay unique
after prefixing, or `generateText` rejects the run before calling anything.

## Resources, prompts, and completions

Resources and prompts are available as typed client results:

```nim
let resources = await client.listResourcesAsync()
let file = await client.readResourceAsync(resources[0].uri)
echo file.contents[0].text

let prompt = await client.getPromptAsync("review", %*{"code": "echo 1"})
echo prompt.messages[0].content
```

`listResourcesAsync`, `listResourceTemplatesAsync`, and `listPromptsAsync`
follow `nextCursor` until discovery is complete. `readResourceAsync` exposes
text and base64 blob contents, plus the server's cache hints. Use
`completePromptArgumentAsync` or `completeResourceArgumentAsync` for argument
completion.

## Subscriptions, input, and tasks

Subscribe to server-side changes with a filter and read each wire notification
from the returned stream:

```nim
let changes = await client.subscribeAsync(McpSubscriptionFilter(
  toolsListChanged: true))
let (more, event) = await changes.read()
if more: echo event["method"]
await changes.closeAsync()
```

Configure handlers for `elicitation/create`, `sampling/createMessage`, or
`roots/list` to let `callToolAsync`, `getPromptAsync`, and `readResourceAsync`
complete stateless `input_required` retries:

```nim
client.setElicitationHandler(proc (request: McpInputRequest): JsonNode =
  %*{"action": "accept", "content": {"confirmed": true}})
```

Long-running tools return `resultType == "task"`. Read their status with
`getTask`, provide pending answers with `updateTask`, or stop them with
`cancelTask`.

## Manage the connection

A client owns a child process when using stdio, so it is not a short-lived
temporary. HTTP connections are created per request. Two rules cover most
cases:

- **Keep it alive for as long as its tools are in use.** The converted `Tool`
  values close over the client, and closing it fails any in-flight request, so a
  `defer: client.close()` in the scope that owns the tools is the right shape.
- **Close it once.** `close` is idempotent, stops the reader, and fails pending
  requests with `McpClientError` rather than leaving futures unresolved.

If the server dies or closes its stdout, the reader notices and fails every
pending request with that error. You do not get a hang.

## Notes and limits

- **No legacy handshake.** nimgent supports the stateless `2026-07-28` flow and
  does not fall back to the removed initialize/session protocol.
- **Tools are dynamic.** Their schemas come from the server at connect time and
  are not checked at compile time. Validate what you care about, or keep the
  model's instructions narrow.
- **`outputSchema` is parsed, not enforced.** `listToolsAsync` surfaces it on
  `McpToolInfo`, but `asToolsAsync` only forwards the input schema to the
  provider; structured results arrive as text or as `structuredContent`.
- **Server-initiated requests are in-band.** Configure input handlers for
  elicitation, sampling, and roots. The client does not invent a legacy
  server-request channel.
- **Windows is unverified.** The non-blocking pipe setup is POSIX-only; on
  Windows nimgent still launches the process (`poUsePath`) but without that
  setup, so treat stdio MCP on Windows as untested.

Related: [Tools and agents](/nimgent/guides/tools-and-agents/) for the loop these tools
run inside, and [Errors and retries](/nimgent/guides/errors-and-retries/) for how a
failing tool call reaches the model.
