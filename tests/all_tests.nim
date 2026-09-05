import std/[json, os, osproc, streams, strutils, times, unittest]
import nimgent
import nimgent/[anthropic, openrouter]
from nimgent/openai import makeOpenAIProvider, makeHyperProvider, buildOpenAiBody,
  buildChatBody, defaultOpenAiEndpoint, defaultOpenAiChatEndpoint,
  defaultHyperEndpoint

suite "thinking options":
  test "maps effort, toggle, and max_tokens by provider":
    check thinkingOptions("openrouter", "high")["reasoning"]["effort"].getStr == "high"
    check thinkingOptions("openai", "low")["reasoning"]["effort"].getStr == "low"
    check thinkingOptions("hyper", "high")["reasoning"]["effort"].getStr == "high"
    check thinkingOptions("anthropic", "medium")["thinking"]["budget_tokens"].getInt == 8000
    check thinkingOptions("openai", "none").len == 0
    check thinkingOptions("openrouter", "high", twToggle)["reasoning"]["enabled"].getBool
    check thinkingOptions("openai", "high", twToggle)["reasoning"]["effort"].getStr == "medium"
    check thinkingOptions("openrouter", "low", twMaxTokens)["reasoning"]["max_tokens"].getInt == 2048
    check thinkingBudgetTokens("high") == 16000

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

  test "cache hit percent does not double-count inclusive prompt tokens":
    let openrouter = Usage(inputTokens: 10000, outputTokens: 1,
      cacheReadTokens: 9680, cacheReported: true)
    check "CH96.8%" in formatUsageLabels(openrouter)
    let anthropic = Usage(inputTokens: 100, outputTokens: 1,
      cacheReadTokens: 900, cacheReported: true)
    check "CH90.0%" in formatUsageLabels(anthropic)

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
    check response.content[0].kind == ckThinking
    check response.content[0].thinking == "planAplanB"
    check "sig_s" in response.content[0].signature
    check "planAplanB" in response.content[0].signature
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
    check first.content[0].kind == ckThinking
    check first.content[0].thinking == "should I read?"
    check "sig_fixture" in first.content[0].signature
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

type
  ScriptProvider = ref object of Provider
    calls*: int
    failLeft*: int
    toolFirst*: bool
    last*: ProviderRequest

  BoomProvider = ref object of Provider
    calls*: int

  BadArgsProvider = ref object of Provider
    calls*: int

method generate(p: ScriptProvider, request: ProviderRequest): ProviderResponse =
  inc p.calls
  p.last = request
  if p.failLeft > 0:
    dec p.failLeft
    raiseProviderError("rate limited", retryable = true, status = 429)
  if p.toolFirst and p.calls == 1:
    result.content.add toolUse("call_1", "echo", %*{"x": 1})
    result.finishReason = frToolUse
    return
  result.content.add text("ok")
  result.finishReason = frStop

method generate(p: BoomProvider, request: ProviderRequest): ProviderResponse =
  inc p.calls
  raiseProviderError("prompt is too long", overflow = true)

method generate(p: BadArgsProvider, request: ProviderRequest): ProviderResponse =
  inc p.calls
  if p.calls == 1:
    result.content.add toolUseFromArgs("call_1", "echo", "{nope")
    result.finishReason = frToolUse
    return
  result.content.add text("recovered")
  result.finishReason = frStop

suite "generateText retries, abort, and tools":
  test "retries retryable errors then succeeds":
    let p = ScriptProvider(failLeft: 1)
    let r = generateText(p, model = "m", prompt = "hi", maxRetries = 2)
    check p.calls == 2
    check r.textContent == "ok"
    let p2 = ScriptProvider(failLeft: 1)
    let r2 = generateText(p2, ProviderRequest(model: "m",
      messages: @[userMessage("hi")]), maxRetries = 2)
    check p2.calls == 2
    check r2.textContent == "ok"

  test "does not retry overflow or non-retryable errors":
    let p = BoomProvider()
    expect ProviderError:
      discard generateText(p, model = "m", prompt = "hi", maxRetries = 2)
    check p.calls == 1

  test "abort before the first attempt raises and does not call the provider":
    let p = ScriptProvider()
    var err: ref ProviderError
    try:
      discard generateText(p, model = "m", prompt = "hi",
        abort = proc (): bool = true)
    except ProviderError as e:
      err = e
    check p.calls == 0
    check not err.isNil
    check err.aborted

  test "maxSteps runs execute and continues":
    let p = ScriptProvider(toolFirst: true)
    var ran = 0
    let echoTool = tool("echo", "echo", %*{"type": "object"},
      proc (input: JsonNode): ToolOutput =
        inc ran
        check input["x"].getInt == 1
        ToolOutput(output: "pong"))
    let r = generateText(p, model = "m", prompt = "hi",
      tools = @[echoTool], maxSteps = 2, maxRetries = 0)
    check ran == 1
    check p.calls == 2
    check r.textContent == "ok"
    var sawTool = false
    for msg in p.last.messages:
      for part in msg.content:
        if part.kind == ckToolResult:
          sawTool = true
          check part.output == "pong"
          check part.toolUseId == "call_1"
    check sawTool

  test "default stream emits tool call events":
    let p = ScriptProvider(toolFirst: true)
    var names: seq[string] = @[]
    discard streamText(p, model = "m", prompt = "hi",
      onEvent = proc (ev: StreamEvent): bool =
        if ev.kind == seToolCallDelta:
          names.add ev.toolName
        true)
    check names == @["echo"]

  test "maxSteps 1 does not execute tools":
    let p = ScriptProvider(toolFirst: true)
    var ran = 0
    let echoTool = tool("echo", "echo", %*{"type": "object"},
      proc (input: JsonNode): ToolOutput =
        inc ran
        ToolOutput(output: "pong"))
    let r = generateText(p, model = "m", prompt = "hi",
      tools = @[echoTool], maxSteps = 1, maxRetries = 0)
    check ran == 0
    check p.calls == 1
    check r.toolCalls.len == 1

  test "invalid tool JSON becomes a tool error and does not execute":
    check parseToolArguments("").parseError.len == 0
    check parseToolArguments("{\"x\":1}").input["x"].getInt == 1
    check parseToolArguments("{nope").parseError.startsWith("invalid tool arguments")
    check invalidToolCall(toolUseFromArgs("call_1", "echo", "{nope")).len > 0
    check not tool("echo", "echo", %*{"type": "object"}).parallel
    var ran = 0
    let echoTool = tool("echo", "echo", %*{"type": "object"},
      proc (input: JsonNode): ToolOutput =
        inc ran
        ToolOutput(output: "should not run"),
      parallel = true)
    check echoTool.parallel
    let p = BadArgsProvider()
    let r = generateText(p, model = "m", prompt = "hi",
      tools = @[echoTool], maxSteps = 2, maxRetries = 0)
    check ran == 0
    check p.calls == 2
    check r.textContent == "recovered"

  test "isRetryableStatus matches 429 and 5xx":
    check isRetryableStatus(429)
    check isRetryableStatus(503)
    check not isRetryableStatus(400)
    check not isRetryableStatus(401)

  test "retry delay honors Retry-After and caps wild values":
    check parseRetryAfter("") == 0
    check parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == 0
    check parseRetryAfter("5") == 5_000
    check parseRetryAfter("999") == retryAfterCapMs
    check retryDelayMs(0, 1_500) == 1_500
    check retryDelayMs(0, 99_000) == retryAfterCapMs
    check retryDelayMs(0) <= 250

suite "Hyper provider":
  test "defaults to chat completions":
    check makeHyperProvider("k").name == "hyper"
    check makeHyperProvider("k").endpoint == defaultHyperEndpoint
    check not makeHyperProvider("k").useResponses
    check makeHyperProvider("k").maxTokensField == "max_tokens"
    check not makeHyperProvider("k",
      "https://hyper.charm.land/v1/responses").useResponses

  test "chat body uses max_tokens and skips OpenRouter extras":
    let body = buildChatBody(ProviderRequest(
      model: "deepseek-v4-flash",
      sessionId: "must-not-send",
      messages: @[userMessage("hi")],
      maxTokens: 32), stream = false, maxTokensField = "max_tokens")
    check body["max_tokens"].getInt == 32
    check "max_completion_tokens" notin body
    check "session_id" notin body
    check "cache_control" notin $body

  test "missing API key fails before making a request":
    let provider = makeHyperProvider("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "generate accepts usage without token-details":
    let fixturePath = getCurrentDir() / "tests" / "hyper_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeHyperProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    let response = provider.generate(ProviderRequest(
      model: "deepseek-v4-flash", messages: @[userMessage("hi")],
      maxTokens: 16))
    check response.textContent == "pong"
    check response.usage.inputTokens == 10
    check response.usage.outputTokens == 1
    check not response.usage.cacheReported
    check fixture.waitForExit() == 0

suite "OpenAI provider":
  test "native body uses Responses fields and omits Chat Completions extras":
    let body = buildOpenAiBody(ProviderRequest(
      model: "gpt-5",
      sessionId: "should-omit",
      system: @["stable prefix"],
      messages: @[userMessage("hi")],
      tools: @[ToolDefinition(name: "read", description: "d",
        inputSchema: %*{"type": "object"})],
      maxTokens: 128,
      options: %*{"reasoning_effort": "medium"}), stream = false)
    check body["model"].getStr == "gpt-5"
    check body["max_output_tokens"].getInt == 128
    check body["store"].getBool == false
    check body["instructions"].getStr == "stable prefix"
    check "max_tokens" notin body
    check "max_completion_tokens" notin body
    check "session_id" notin body
    check "messages" notin body
    check "function" notin body["tools"][0]
    check body["tools"][0]["name"].getStr == "read"
    check body["reasoning"]["effort"].getStr == "medium"
    check "reasoning_effort" notin body
    check body["include"][0].getStr == "reasoning.encrypted_content"
    check makeOpenAIProvider("k").name == "openai"
    check makeOpenAIProvider("k").endpoint == defaultOpenAiEndpoint
    check makeOpenAIProvider("k").useResponses
    check not makeOpenAIProvider("k", defaultOpenAiChatEndpoint).useResponses

  test "responses body replays reasoning and function calls":
    let sig = $(%*{"id": "rs_1", "encrypted_content": "enc"})
    let body = buildOpenAiBody(ProviderRequest(
      model: "gpt-5",
      messages: @[
        userMessage("hi"),
        Message(role: roleAssistant, content: @[
          ContentBlock(kind: ckThinking, thinking: "plan", signature: sig),
          text("done"),
          toolUse("call_1", "read", %*{"path": "x"})
        ]),
        userMessage(@[toolResult("call_1", "ok")])
      ],
      maxTokens: 10), stream = false)
    let input = body["input"]
    check input.len == 5
    check input[0]["role"].getStr == "user"
    check input[1]["type"].getStr == "reasoning"
    check input[1]["id"].getStr == "rs_1"
    check input[1]["encrypted_content"].getStr == "enc"
    check input[2]["content"][0]["type"].getStr == "output_text"
    check input[3]["type"].getStr == "function_call"
    check input[3]["call_id"].getStr == "call_1"
    check input[4]["type"].getStr == "function_call_output"
    check input[4]["call_id"].getStr == "call_1"

  test "missing API key fails before making a request":
    let provider = makeOpenAIProvider("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "generate sends OpenAI fields and reports cache reads":
    let fixturePath = getCurrentDir() / "tests" / "openai_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenAIProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    let response = provider.generate(ProviderRequest(
      model: "gpt-5",
      sessionId: "must-not-send",
      system: @["You are a test agent."],
      messages: @[userMessage("hello")],
      tools: @[ToolDefinition(name: "read", description: "Read a file",
        inputSchema: %*{"type": "object"})],
      maxTokens: 32,
      options: %*{"reasoning_effort": "low"}))
    check response.model == "gpt-5"
    check response.textContent == "hello from openai"
    check response.content[0].kind == ckThinking
    check response.content[0].thinking == "cached plan"
    check "rs_1" in response.content[0].signature
    check response.usage.inputTokens == 20
    check response.usage.cacheReadTokens == 8
    check response.usage.cacheReported
    check fixture.waitForExit() == 0

  test "generateStream emits deltas before the response finishes":
    let fixturePath = getCurrentDir() / "tests" / "openai_responses_stream_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenAIProvider("fixture-key",
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

  test "generateStream emits tool call deltas":
    let fixturePath = getCurrentDir() / "tests" / "openai_responses_stream_fixture.py"
    var fixture = startProcess("python3", args = @[fixturePath],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if fixture.running:
        fixture.terminate()
        discard fixture.waitForExit()
      fixture.close()
    let port = parseInt(fixture.outputStream.readLine())
    let provider = makeOpenAIProvider("fixture-key",
      "http://127.0.0.1:" & $port, timeoutSeconds = 5)
    var evs: seq[string] = @[]
    let response = provider.generateStream(
      ProviderRequest(model: "test", messages: @[userMessage("hi")],
        tools: @[ToolDefinition(name: "read", description: "d",
          inputSchema: %*{"type": "object"})],
        maxTokens: 20),
      proc (ev: StreamEvent): bool =
        if ev.kind == seToolCallDelta:
          evs.add ev.toolName & ":" & ev.toolArgs
        true)
    check evs == @["read:", "read:{\"path\":\"x\"}"]
    check response.toolCalls.len == 1
    check response.toolCalls[0].name == "read"
    check response.toolCalls[0].input["path"].getStr == "x"
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

  test "chat completions replays thinking and signed details":
    let details = $(%*[{
      "type": "reasoning.text",
      "text": "plan",
      "signature": "sig",
      "format": "anthropic-claude-v1",
      "index": 0
    }])
    let withDetails = buildChatBody(ProviderRequest(
      model: "m",
      messages: @[
        userMessage("hi"),
        Message(role: roleAssistant, content: @[
          ContentBlock(kind: ckThinking, thinking: "plan", signature: details),
          text("ok"),
          toolUse("call_1", "read", %*{"path": "x"})
        ])
      ],
      maxTokens: 10), stream = false)
    let asst = withDetails["messages"][1]
    check asst["reasoning"].getStr == "plan"
    check asst["reasoning_details"][0]["signature"].getStr == "sig"
    let plain = buildChatBody(ProviderRequest(
      model: "m",
      messages: @[
        userMessage("hi"),
        Message(role: roleAssistant, content: @[
          ContentBlock(kind: ckThinking, thinking: "scratch"),
          text("ok")
        ])
      ],
      maxTokens: 10), stream = false)
    check plain["messages"][1]["reasoning"].getStr == "scratch"
    check "reasoning_details" notin plain["messages"][1]
    let toolNoSig = buildChatBody(ProviderRequest(
      model: "m",
      messages: @[
        userMessage("hi"),
        Message(role: roleAssistant, content: @[
          ContentBlock(kind: ckThinking, thinking: "scratch"),
          toolUse("call_1", "read", %*{"path": "x"})
        ])
      ],
      maxTokens: 10), stream = false)
    check "reasoning" notin toolNoSig["messages"][1]
    let unsigned = $(%*[{
      "type": "reasoning.text",
      "text": "plan",
      "format": "anthropic-claude-v1",
      "index": 0
    }])
    let stripped = buildChatBody(ProviderRequest(
      model: "m",
      messages: @[
        userMessage("hi"),
        Message(role: roleAssistant, content: @[
          ContentBlock(kind: ckThinking, thinking: "plan", signature: unsigned),
          toolUse("call_1", "read", %*{"path": "x"})
        ])
      ],
      maxTokens: 10), stream = false)
    check "reasoning" notin stripped["messages"][1]
    check "reasoning_details" notin stripped["messages"][1]
