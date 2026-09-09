## Typed agent lifecycle events, including an interactive tool approval.
##
##   OPENAI_API_KEY=... nim c -r examples/agent_events.nim

import std/[asyncdispatch, json, os]
import nimgent
import nimgent/agent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let deleteTool = rawTool("deleteFile", "Delete a file", %*{
  "type": "object", "properties": {"path": {"type": "string"}},
  "required": ["path"]},
  proc (_: ToolContext, input: JsonNode): ToolResult =
    ToolResult(output: "deleted " & input["path"].getStr))

let researcher = newAgent(model,
  instructions = "Use tools when useful.",
  tools = @[deleteTool],
  approvalPolicy = proc (_: int, call: ContentBlock,
      _: Tool): ToolApproval =
    if call.name == "deleteFile":
      ToolApproval(mode: tamAsk, reason: "This deletes a file.")
    else:
      ToolApproval(mode: tamAllow))

let events = researcher.events("Clean up the workspace.")
while true:
  let item = waitFor events.read()
  if not item[0]: break
  let event = item[1]
  case event.kind
  of aeTextDelta:
    stdout.write event.text
  of aeToolApprovalRequired:
    echo "\nApprove ", event.approval.toolName, "?"
    event.approval.deny()
  of aeError:
    echo "\nagent error: ", event.error.msg
  else:
    discard

discard waitFor events.result
echo ""
