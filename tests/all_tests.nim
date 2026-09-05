import std/[json, os, osproc, streams, strutils, times, unittest]
import nimgent
import nimgent/[anthropic, openrouter]

suite "provider types":
  test "overflow heuristic ignores generic token errors":
    check isContextOverflow("This model's maximum context length is 128000 tokens")
    check isContextOverflow("prompt is too long")
    check isContextOverflow("context_length_exceeded")
    check not isContextOverflow("Invalid API token")
    check not isContextOverflow("rate limit: too many requests")

  test "wakeFd defaults to no wake":
    let req = ProviderRequest(model: "test", messages: @[userMessage("hi")])
    check req.wakeFd == -1

suite "OpenRouter provider":
  test "stream line buffer splits on newlines":
    var buf = "data: one\ndata: two\npartial"
    check popLine(buf) == (true, "data: one")
    check popLine(buf) == (true, "data: two")
    check not popLine(buf).ok
    check buf == "partial"

  test "generateStream emits deltas before the response finishes":
    let fixturePath = getCurrentDir() / "tests" / "openrouter_stream_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenRouterProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    var stamps: seq[float] = @[]
    var pieces: seq[string] = @[]
    let response = provider.generateStream(
      ProviderRequest(model: "test", messages: @[userMessage("hi")],
        maxTokens: 20),
      proc (ev: StreamEvent): bool =
        if ev.kind == seTextDelta:
          stamps.add epochTime()
          pieces.add ev.text
        true)
    check pieces == @["Hello", " world"]
    check response.textContent == "Hello world"
    check stamps.len == 2
    check stamps[1] - stamps[0] >= 0.05
    check fixture.waitForExit() == 0

  test "missing API key fails before making a request":
    let provider = makeOpenRouterProvider("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "translates tool calls and reports response metadata":
    let fixturePath = getCurrentDir() / "tests" / "openrouter_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()

    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenRouterProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    let readDefinition = ToolDefinition(name: "read",
      description: "Read a file", inputSchema: %*{
        "type": "object",
        "properties": {"path": {"type": "string"}}
      })
    let request = ProviderRequest(
      model: "deepseek/deepseek-v4-flash-0731",
      sessionId: "fixture-session",
      system: @["You are a test agent."],
      messages: @[userMessage("hello")],
      tools: @[readDefinition],
      maxTokens: 100)
    let first = provider.generate(request)
    check first.model == "deepseek/deepseek-v4-flash-0731"
    check first.toolCalls.len == 1
    check first.toolCalls[0].name == "read"
    check first.toolCalls[0].input["path"].getStr == "README.md"
    check first.usage.cacheWriteTokens == 1000

    var followup = request
    followup.messages = @[
      userMessage("hello"),
      Message(role: roleAssistant, content: first.content),
      Message(role: roleUser, content: @[
        toolResult(first.toolCalls[0].id, "README contents")
      ])
    ]
    let second = provider.generate(followup)
    check second.textContent == "fixture complete"
    check second.usage.cacheReadTokens == 1000
    check second.usage.cacheReported
    check fixture.waitForExit() == 0

  test "generateText and streamText facade":
    let fixturePath = getCurrentDir() / "tests" / "openrouter_stream_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenRouterProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    var pieces: seq[string] = @[]
    let streamed = streamText(
      provider,
      model = "test",
      prompt = "hi",
      maxTokens = 20,
      onEvent = proc (ev: StreamEvent): bool =
        if ev.kind == seTextDelta:
          pieces.add ev.text
        true)
    check pieces == @["Hello", " world"]
    check streamed.textContent == "Hello world"
    check fixture.waitForExit() == 0

suite "encoding":
  test "providers encode image blocks and cache breakpoints":
    check anthropicImageBlock("image/png", "QUJD")["source"]["data"].getStr == "QUJD"
    check "data:image/png;base64,QUJD" in $openAiImagePart("image/png", "QUJD")
    let body = buildBody(ProviderRequest(
      model: "vision",
      messages: @[userMessage(@[text("see"), image("image/png", "QUJD")])],
      maxTokens: 10), stream = false)
    let content = body["messages"][0]["content"]
    check content.kind == JArray
    check content.len == 2
    check content[1]["type"].getStr == "image_url"
    check "cache_control" in content[1]
    let sysBody = buildBody(ProviderRequest(
      model: "vision",
      system: @["stable prefix", "skills"],
      messages: @[userMessage("hi")],
      tools: @[ToolDefinition(name: "read", description: "d",
        inputSchema: %*{"type": "object"})],
      maxTokens: 10), stream = false)
    check sysBody["messages"][0]["role"].getStr == "system"
    let sysParts = sysBody["messages"][0]["content"]
    check sysParts.kind == JArray
    check sysParts.len == 2
    check "cache_control" in sysParts[1]
    check "cache_control" in sysBody["tools"][0]
