---
title: MCP client
description: Discover and use capabilities exposed by an MCP server.
---

Connect to an MCP server over stdio, inspect its tools and resources, call one
directly, and adapt the discovered tools for use in an nimgent agent.

The server executable path is supplied on the command line. After discovery,
the example calls a tool named `echo`, then converts all discovered tools with
`asToolsAsync` so they can be passed to normal nimgent model calls.

```nim
import std/[asyncdispatch, json, os, sequtils, strutils]
import nimgent/mcp

proc main() {.async.} =
  if paramCount() != 1:
    quit("usage: mcp_client <path-to-echo-server>")
  let client = await connectMcpStdioAsync(@[paramStr(1)])
  defer: client.close()

  let tools = await client.listToolsAsync()
  echo "discovered: ", tools.mapIt(it.name).join(", ")

  let result = await client.callToolAsync("echo", %*{"text": "hello from nimgent"})
  echo result.content

  let resources = await client.listResourcesAsync()
  echo "resources: ", resources.len

  let adapted = await client.asToolsAsync(prefix = "echo_")
  echo "nimgent tools: ", adapted.mapIt(it.name).join(", ")

waitFor main()
```

Compile it with the path to an MCP stdio server that exposes an `echo` tool:

```sh
nim c -r examples/mcp_client.nim /path/to/echo-server
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/mcp_client.nim)
