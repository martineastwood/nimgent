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

  let adapted = await client.asToolsAsync(prefix = "echo_")
  echo "nimgent tools: ", adapted.mapIt(it.name).join(", ")

waitFor main()
