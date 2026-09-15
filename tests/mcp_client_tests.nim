import std/[asyncdispatch, json, os, osproc, streams, strutils, unittest]
import ../src/nimgent/mcp

proc fixtureCommand(): seq[string] =
  @[
    "python3",
    getCurrentDir() / "tests" / "mcp_client_fixture.py"
  ]

proc withHttpFixture(body: proc (port: int)) =
  let fixturePath = getCurrentDir() / "tests" / "mcp_http_fixture.py"
  let fixture = startProcess("python3", args = @[fixturePath],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if fixture.running:
      fixture.terminate()
      discard fixture.waitForExit()
    fixture.close()
  body(parseInt(fixture.outputStream.readLine()))
  check fixture.waitForExit() == 0

suite "expanded MCP client":
  test "uses Streamable HTTP for stateless requests":
    withHttpFixture(proc (port: int) =
      let client = waitFor connectMcpHttpAsync(
        "http://127.0.0.1:" & $port & "/mcp")
      defer: client.close()
      check client.serverInfo["name"].getStr == "http-fixture"
      check (waitFor client.listToolsAsync())[0].name == "http-echo"
      let call = waitFor client.callToolAsync("http-echo", %*{
        "token": "secret"})
      check call.content[0]["text"].getStr == "ok")

  test "discovers and uses nimwire features over stdio":
    let client = waitFor connectMcpStdioAsync(fixtureCommand())
    defer: client.close()

    check client.serverInfo["name"].getStr == "fixture"
    check (waitFor client.listToolsAsync()).len == 5
    check (waitFor client.listResourcesAsync())[0].uri == "memo://today"
    check (waitFor client.listResourceTemplatesAsync())[0].uriTemplate ==
      "memo://{id}"
    check (waitFor client.listPromptsAsync())[0].arguments[0].name == "code"

    let resource = waitFor client.readResourceAsync("memo://today")
    check resource.contents[0].text == "memo"
    check resource.ttlMs == 10

    let prompt = waitFor client.getPromptAsync("review", %*{"code": "x"})
    check prompt.messages[0].content["text"].getStr == "x"

    let completion = waitFor client.completePromptArgumentAsync("review", "code", "o")
    check completion.values == @["one", "two"]

  test "retries input-required calls and receives progress notifications":
    let client = waitFor connectMcpStdioAsync(fixtureCommand())
    defer: client.close()
    client.setElicitationHandler(proc (request: McpInputRequest): JsonNode =
      %*{"action": "accept", "content": {"answer": "yes"}})
    var progress = ""
    client.setProgressHandler(proc (value, total: float, message: string) =
      progress = message)

    let answer = waitFor client.callToolAsync("ask")
    check answer.content[0]["text"].getStr == "yes"
    discard waitFor client.callToolAsync("progress",
      options = McpRequestOptions(progressToken: newJInt(7)))
    check progress == "done"

  test "opens subscriptions and polls tasks":
    let client = waitFor connectMcpStdioAsync(fixtureCommand())
    defer: client.close()
    let subscription = waitFor client.subscribeAsync(McpSubscriptionFilter(
      toolsListChanged: true))
    discard waitFor client.callToolAsync("change")
    let (more, message) = waitFor subscription.read()
    check more
    check message["method"].getStr == "notifications/tools/list_changed"
    waitFor subscription.closeAsync()
    check not subscription.isActive

    let started = waitFor client.callToolAsync("task")
    check started.resultType == "task"
    check started.task.taskId == "fixture-task"
    let current = client.getTask("fixture-task")
    check current.status == "working"
    waitFor client.cancelTaskAsync("fixture-task")
