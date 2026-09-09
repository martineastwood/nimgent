import std/[asyncdispatch, atomics, json, options, os, osproc, sets, streams,
  sequtils, strutils, tables, times, unittest]
import nimgent
import nimgent/[agent, session]
import nimgent/providers/[anthropic, openrouter]
import nimgent/testing
import nimgent/providers/stream
from nimgent/providers/openai import openAI, hyper,
  buildResponsesBody, buildChatBody, parseResponsesOutput,
  defaultOpenAiEndpoint, defaultOpenAiChatEndpoint, defaultHyperEndpoint,
  chatObjectOptions, chatForceToolOptions

proc withFixture(script: string, body: proc (port: int)) =
  let fixturePath = getCurrentDir() / "tests" / script
  var fixture = startProcess("python3", args = @[fixturePath],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if fixture.running:
      fixture.terminate()
      discard fixture.waitForExit()
    fixture.close()
  body(parseInt(fixture.outputStream.readLine()))
  check fixture.waitForExit() == 0

suite "Anthropic streaming":
  test "HTTP stream reports truncation and rate-limit metadata":
    for mode in ["cut", "rate"]:
      withFixture("anthropic_stream_fixture.py", proc (port: int) =
        let provider = anthropic("fixture-key", "http://127.0.0.1:" & $port)
        try:
          discard streamText(provider, ProviderRequest(model: mode, maxTokens: 64,
            messages: @[userMessage("hi")]), proc (ev: StreamEvent): bool = true,
            maxRetries = 0)
          check false
        except ProviderError as e:
          check e.retryable
          if mode == "rate":
            check e.status == 429
            check e.retryAfterMs == 2000
            check e.requestId == "req-anthropic-rate"
        )

  test "cancelling HTTP tool arguments returns no executable partial call":
    withFixture("anthropic_stream_fixture.py", proc (port: int) =
      let response = waitFor anthropic("fixture-key", "http://127.0.0.1:" & $port).generateStreamAsync(
        ProviderRequest(model: "cancel", maxTokens: 64, messages: @[userMessage("hi")]),
        proc (ev: StreamEvent): bool = ev.kind != seToolCallDelta)
      check response.finishReason == frStop
      check response.content.len == 0)

  test "streaming surfaces cancellation as CancelledError":
    withFixture("anthropic_stream_fixture.py", proc (port: int) =
      expect CancelledError:
        discard streamText(anthropic("fixture-key", "http://127.0.0.1:" & $port),
          ProviderRequest(model: "cancel", maxTokens: 64, messages: @[userMessage("hi")]),
          proc (ev: StreamEvent): bool = ev.kind != seToolCallDelta, maxRetries = 0))

  test "hosted search and citations replay through HTTP":
    let previous = parseAnthropicOutput(%*{"content": [
      {"type": "server_tool_use", "id": "search1", "name": "web_search", "input": {"query": "Nim"}},
      {"type": "web_search_tool_result", "tool_use_id": "search1", "content": [
        {"type": "web_search_result", "url": "https://example.com", "encrypted_content": "opaque"}]},
      {"type": "text", "text": "Found it", "citations": [{"type": "web_search_result_location",
        "url": "https://example.com", "encrypted_index": "index", "cited_text": "Nim"}]}]})
    withFixture("anthropic_stream_fixture.py", proc (port: int) =
      let response = streamText(anthropic("fixture-key", "http://127.0.0.1:" & $port),
        ProviderRequest(model: "search", maxTokens: 64,
          messages: @[Message(role: roleAssistant, content: previous.content), userMessage("continue")]),
        proc (ev: StreamEvent): bool = true, maxRetries = 0)
      check response.finishReason == frEndTurn
      check response.usage.outputTokens == 2
      check response.requestId == "req-anthropic")

  test "foreign thinking metadata is omitted without changing signed native thinking":
    let req = ProviderRequest(model: "claude-sonnet-4-6", maxTokens: 64,
      messages: @[Message(role: roleAssistant, content: @[
        ContentBlock(kind: ckThinking, thinking: "foreign", signature: "[{\"type\":\"reasoning\"}]"),
        ContentBlock(kind: ckThinking, thinking: "unsigned"),
        ContentBlock(kind: ckThinking, thinking: "native", signature: "opaque-signature"), text("answer")])])
    let body = buildAnthropicBody(req)
    check body["messages"][0]["content"].len == 2
    check body["messages"][0]["content"][0]["signature"].getStr == "opaque-signature"

  test "reassembles text, signed thinking, tools, citations and cumulative usage":
    var message = newJObject()
    var args: seq[string]
    var events: seq[StreamEvent]
    let cb: StreamCallback = proc (event: StreamEvent): bool =
      events.add event
      true
    let frames = @[
      %*{"type": "message_start", "message": {"model": "claude-sonnet-4-6", "content": [], "usage": {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 20}}},
      %*{"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}},
      %*{"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Consider"}},
      %*{"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "signed"}},
      %*{"type": "content_block_stop", "index": 0},
      %*{"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}},
      %*{"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Hello"}},
      %*{"type": "content_block_delta", "index": 1, "delta": {"type": "citations_delta", "citation": {"url": "https://example.com", "title": "Example"}}},
      %*{"type": "content_block_stop", "index": 1},
      %*{"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "call1", "name": "lookup", "input": {}}},
      %*{"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "{\"q\":"}},
      %*{"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "\"Nim\"}"}},
      %*{"type": "content_block_stop", "index": 2},
      %*{"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 30}}]
    for frame in frames:
      check handleAnthropicEvent(message, args, frame, cb) == sseContinue
    check handleAnthropicEvent(message, args, %*{"type": "message_stop"}, cb) == sseStop
    let response = parseAnthropicOutput(message)
    check response.content[0].signature == "signed"
    check response.content[1].text == "Hello"
    check response.content[2].kind == ckSource
    check response.content[3].input["q"].getStr == "Nim"
    check response.usage.inputTokens == 10
    check response.usage.outputTokens == 30
    check response.usage.cacheReadTokens == 20
    check response.finishReason == frToolUse
    check events.len == 4
    check anthropic("key").supports(pcStreaming)

  test "stream errors propagate and callbacks cancel":
    var message = %*{"content": [{"type": "text", "text": ""}]}
    var args = @[""]
    let stop: StreamCallback = proc (event: StreamEvent): bool = false
    check handleAnthropicEvent(message, args, %*{"type": "content_block_delta", "index": 0,
      "delta": {"type": "text_delta", "text": "hi"}}, stop) == sseCancel
    expect ProviderError:
      discard handleAnthropicEvent(message, args,
        %*{"type": "error", "error": {"type": "overloaded_error", "message": "Busy"}}, stop)

  test "thinking budget leaves room for the requested answer":
    let body = buildAnthropicBody(ProviderRequest(model: "claude-sonnet-4-6",
      maxTokens: 4096, options: thinkingOptions("anthropic", "high")))
    check body["max_tokens"].getInt == 20096

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

  test "api error body prefers error.message":
    check apiErrorMessage("""{"error":{"message":"nope"}}""") == "nope"
    check apiErrorMessage("not-json") == "not-json"

  test "api error body handles Google's top-level array form":
    check apiErrorMessage(
      """[{"error":{"code":403,"message":"Gemini API disabled","status":"PERMISSION_DENIED"}}]""") ==
      "Gemini API disabled"

  test "cache hit percent does not double-count inclusive prompt tokens":
    let openrouter = Usage(inputTokens: 10000, outputTokens: 1,
      cacheReadTokens: 9680, cacheReported: true)
    check "CH96.8%" in formatUsageLabels(openrouter)
    let anthropic = Usage(inputTokens: 100, outputTokens: 1,
      cacheReadTokens: 900, cacheReported: true)
    check "CH90.0%" in formatUsageLabels(anthropic)

suite "embeddings":
  test "OpenAI embeds batches in input order and forwards options":
    withFixture("openai_embeddings_fixture.py") do (port: int):
      let provider = openAI("fixture-key",
        "http://127.0.0.1:" & $port & "/v1/responses", timeoutSeconds = 5)
      check provider.supports(pcEmbeddings)
      let model = provider.embeddingModel("text-embedding-3-small")
      let batch = embedMany(model, @["alpha", "beta"],
        options = %*{"dimensions": 2})
      check batch.values == @["alpha", "beta"]
      check batch.embeddings == @[@[1.0, 0.0], @[0.0, 1.0]]
      check batch.usage.tokens == 3
      let one = embed(model, "single")
      check one.value == "single"
      check one.embedding == @[0.5, 0.5]
      check one.usage.tokens == 1

  test "cosine similarity validates and compares vectors":
    check cosineSimilarity(@[1.0, 0.0], @[1.0, 0.0]) == 1.0
    check cosineSimilarity(@[1.0, 0.0], @[0.0, 1.0]) == 0.0
    expect ValueError:
      discard cosineSimilarity(@[1.0], @[1.0, 2.0])

suite "OpenRouter provider":
  test "stream line buffer splits on newlines":
    var buf = "data: one\ndata: two\npartial"
    check popLine(buf) == (true, "data: one")
    check popLine(buf) == (true, "data: two")
    check not popLine(buf).ok
    check buf == "partial"

  test "generateStream emits deltas before the response finishes":
    withFixture("openrouter_stream_fixture.py") do (port: int):
      let provider = openRouter("fixture-key",
        "http://127.0.0.1:" & $port, timeoutSeconds = 5)
      var stamps: seq[float] = @[]
      var pieces: seq[string] = @[]
      let response = waitFor provider.generateStreamAsync(
        ProviderRequest(model: "test", messages: @[userMessage("hi")],
          maxTokens: 20),
        proc (ev: StreamEvent): bool =
          if ev.kind == seTextDelta:
            stamps.add epochTime()
            pieces.add ev.text
          true)
      check pieces == @["Hello", " world"]
      check response.text == "Hello world"
      check response.content[0].kind == ckThinking
      check response.content[0].thinking == "planAplanB"
      check "sig_s" in response.content[0].signature
      check "planAplanB" in response.content[0].signature
      check stamps.len == 2
      check stamps[1] - stamps[0] >= 0.05

  test "truncated stream is a retryable error":
    withFixture("openrouter_stream_cut_fixture.py") do (port: int):
      let provider = openRouter("fixture-key",
        "http://127.0.0.1:" & $port, timeoutSeconds = 5)
      try:
        discard provider.generateStream(
          ProviderRequest(model: "test", messages: @[userMessage("hi")],
            maxTokens: 20),
          proc (ev: StreamEvent): bool = true)
        fail()
      except ProviderError as e:
        check e.retryable
        check "closed mid-response" in e.msg

  test "missing API key fails before making a request":
    let provider = openRouter("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "translates tool calls and reports response metadata":
    withFixture("openrouter_fixture.py") do (port: int):
      let provider = openRouter("fixture-key",
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
      check second.text == "fixture complete"
      check second.usage.cacheReadTokens == 1000
      check second.usage.cacheReported

  test "generateText and streamText API":
    withFixture("openrouter_stream_fixture.py") do (port: int):
      let provider = openRouter("fixture-key",
        "http://127.0.0.1:" & $port, timeoutSeconds = 5)
      var pieces: seq[string] = @[]
      let streamed = streamText(
        provider.model("test"),
        prompt = "hi",
        maxTokens = 20,
        onEvent = proc (ev: StreamEvent): bool =
          if ev.kind == seTextDelta:
            pieces.add ev.text
          true)
      check pieces == @["Hello", " world"]
      check streamed.text == "Hello world"

type
  ScriptProvider = ref object of Provider
    calls*: int
    failLeft*: int
    toolFirst*: bool
    twoTools*: bool
    last*: ProviderRequest

  BoomProvider = ref object of Provider
    calls*: int

  HostedScript = ref object of Provider
    calls*: int

  BadArgsProvider = ref object of Provider
    calls*: int

  EchoInput = object
    x: int

  EchoOutput = object
    doubled: int

method generateAsync(p: ScriptProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  p.last = request
  result.usage = Usage(inputTokens: p.calls, outputTokens: p.calls * 2)
  if p.failLeft > 0:
    dec p.failLeft
    raiseProviderError("rate limited", status = 429)
  if p.toolFirst and p.calls == 1:
    result.content.add toolUse("call_1", "echo", %*{"x": 1})
    if p.twoTools:
      result.content.add toolUse("call_2", "echo", %*{"x": 2})
    result.finishReason = frToolUse
    return
  result.content.add text("ok")
  result.finishReason = frStop

method generateAsync(p: BoomProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  raiseProviderError("prompt is too long", overflow = true)

method generateAsync(p: HostedScript,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  result.content.add toolUse("s1", "web_search", %*{"query": "x"},
    hosted = "web_search")
  result.content.add text("done")
  result.finishReason = frStop

method generateAsync(p: BadArgsProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  if p.calls == 1:
    result.content.add toolUseFromArgs("call_1", "echo", "{nope")
    result.finishReason = frToolUse
    return
  result.content.add text("recovered")
  result.finishReason = frStop

suite "generateText retries, abort, and tools":
  test "lifecycle callbacks observe retries":
    let p = ScriptProvider(failLeft: 1)
    var retries: seq[string]
    var finished = false
    let onRetry = proc (attempt, delayMs: int, error: ref ProviderError) =
      retries.add $attempt & ":" & $delayMs & ":" & error.msg
    let onFinish = proc (response: ProviderResponse) =
      finished = response.text == "ok"
    let r = generateText(p.model("m"), prompt = "hi", maxRetries = 1,
      callbacks = RunCallbacks(onRetry: onRetry, onFinish: onFinish))
    check retries.len == 1
    check retries[0].startsWith("1:")
    check "rate limited" in retries[0]
    check r.text == "ok"
    check finished

  test "lifecycle callbacks observe tools and completed steps":
    let p = ScriptProvider(toolFirst: true)
    let echoTool = rawTool("echo", "echo", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult = ToolResult(output: "pong"))
    var events: seq[string]
    let onToolStart = proc (step: int, call: ContentBlock) =
      events.add "tool-start:" & $step & ":" & call.name
    let onToolFinish = proc (step: int, call, output: ContentBlock,
                             durationMs: int) =
      check durationMs >= 0
      events.add "tool-finish:" & $step & ":" & output.output
    let onStepFinish = proc (step: int, result: StepResult) =
      events.add "step-finish:" & $step & ":" & $result.toolResults.len
    let onFinish = proc (response: ProviderResponse) =
      events.add "finish:" & $response.steps.len
    let callbacks = RunCallbacks(onToolStart: onToolStart,
      onToolFinish: onToolFinish, onStepFinish: onStepFinish,
      onFinish: onFinish)
    discard generateText(p.model("m"), prompt = "hi", tools = @[echoTool],
      maxSteps = 2, maxRetries = 0, callbacks = callbacks)
    check events == @[
      "tool-start:0:echo",
      "tool-finish:0:pong",
      "step-finish:0:1",
      "step-finish:1:0",
      "finish:2"]

  test "retries retryable errors then succeeds":
    let p = ScriptProvider(failLeft: 1)
    let r = generateText(p.model("m"), prompt = "hi", maxRetries = 2)
    check p.calls == 2
    check r.text == "ok"
    check r.steps.len == 1
    check r.usage.inputTokens == 2
    check r.totalUsage.inputTokens == 2
    check r.totalUsage.outputTokens == 4
    check r.finishReason != frStepLimit
    let p2 = ScriptProvider(failLeft: 1)
    let r2 = generateText(p2, ProviderRequest(model: "m",
      messages: @[userMessage("hi")]), maxRetries = 2)
    check p2.calls == 2
    check r2.text == "ok"

  test "does not retry overflow or non-retryable errors":
    let p = BoomProvider()
    expect ProviderError:
      discard generateText(p.model("m"), prompt = "hi", maxRetries = 2)
    check p.calls == 1

  test "abort before the first attempt raises and does not call the provider":
    let p = ScriptProvider()
    var err: ref ProviderError
    try:
      discard generateText(p.model("m"), prompt = "hi",
        abort = proc (): bool = true)
    except ProviderError as e:
      err = e
    check p.calls == 0
    check not err.isNil
    check err.aborted
    check err of CancelledError

  test "maxSteps runs execute and continues":
    let p = ScriptProvider(toolFirst: true)
    var ran = 0
    let echoTool = rawTool("echo", "echo", %*{"type": "object"},
      proc (_: ToolContext, input: JsonNode): ToolResult =
        inc ran
        check input["x"].getInt == 1
        ToolResult(output: "pong"))
    let r = generateText(p.model("m"), prompt = "hi",
      tools = @[echoTool], maxSteps = 2, maxRetries = 0)
    check ran == 1
    check p.calls == 2
    check r.text == "ok"
    check r.steps.len == 2
    check r.steps[0].toolResults.len == 1
    check r.steps[0].toolResults[0].output == "pong"
    check r.usage.inputTokens == 2
    check r.totalUsage.inputTokens == 3
    check r.totalUsage.outputTokens == 6
    check r.finishReason != frStepLimit
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
    discard streamText(p.model("m"), prompt = "hi",
      onEvent = proc (ev: StreamEvent): bool =
        if ev.kind == seToolCallDelta:
          names.add ev.toolName
        true)
    check names == @["echo"]

  test "maxSteps 1 does not execute tools":
    let p = ScriptProvider(toolFirst: true)
    var ran = 0
    let echoTool = rawTool("echo", "echo", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult =
        inc ran
        ToolResult(output: "pong"))
    let r = generateText(p.model("m"), prompt = "hi",
      tools = @[echoTool], maxSteps = 1, maxRetries = 0)
    check ran == 0
    check p.calls == 1
    check r.toolCalls.len == 1
    check r.steps.len == 1
    check r.finishReason == frStepLimit

  test "stream callback cancellation raises an aborted error":
    let p = ScriptProvider()
    var err: ref ProviderError
    try:
      discard streamText(p.model("m"), prompt = "hi",
        onEvent = proc (_: StreamEvent): bool = false)
    except ProviderError as e:
      err = e
    check not err.isNil
    check err.aborted

  test "message helpers are symmetric and options reject non-objects":
    check assistantMessage("hi").role == roleAssistant
    check assistantMessage(@[text("hi")]).content[0].text == "hi"
    expect ProviderError:
      discard generateText(ScriptProvider().model("m"), prompt = "hi",
        options = %*[1, 2])

  test "bound models, typed tools, and async primitive":
    let p = ScriptProvider()
    let bound = p.model("m")
    let typed = tool("double", "Double a number",
      proc (_: ToolContext, input: EchoInput): EchoOutput =
        EchoOutput(doubled: input.x * 2))
    check typed.inputSchema["properties"]["x"]["type"].getStr == "integer"
    check typed.execute(ToolContext(), %*{"x": 3}).value[
      "doubled"].getInt == 6
    let asyncTyped = tool("double_async", "Double asynchronously",
      proc (_: ToolContext, input: EchoInput): Future[EchoOutput] {.async.} =
        await sleepAsync(1)
        return EchoOutput(doubled: input.x * 2))
    check (waitFor asyncTyped.executeAsync(ToolContext(), %*{"x": 4})).value[
      "doubled"].getInt == 8
    let response = waitFor generateTextAsync(bound, prompt = "hi",
      system = "Be concise")
    check response.text == "ok"
    check p.last.system == @["Be concise"]

  test "context tools retain structured values and invocation context":
    let p = ScriptProvider(toolFirst: true)
    var seen: ToolContext
    let contextual = tool("echo", "echo", proc (context: ToolContext,
        input: EchoInput): EchoOutput =
      seen = context
      EchoOutput(doubled: input.x * 2))
    let metadata = %*{"trace": "abc"}
    let response = generateText(p.model("m"), prompt = "hi",
      tools = @[contextual], maxSteps = 2, maxRetries = 0,
      sessionId = "session-1", turnId = "turn-1", metadata = metadata)
    check seen.callId == "call_1"
    check seen.sessionId == "session-1"
    check seen.turnId == "turn-1"
    check not seen.abort.isNil
    check seen.metadata["trace"].getStr == "abc"
    check response.steps[0].toolResults[0].value["doubled"].getInt == 2
    check response.steps[0].toolResults[0].output == "{\"doubled\":2}"
    check p.last.metadata["trace"].getStr == "abc"
    check p.last.turnId == "turn-1"

  test "structured tool failures survive the model-facing result":
    let p = ScriptProvider(toolFirst: true)
    let failed = rawTool("echo", "echo", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult =
        toolFailure("not_found", "record missing", %*{"id": 7}, true))
    let response = generateText(p.model("m"), prompt = "hi",
      tools = @[failed], maxSteps = 2, maxRetries = 0)
    let result = response.steps[0].toolResults[0]
    check result.isError
    check result.errorCode == "not_found"
    check result.errorMessage == "record missing"
    check result.errorDetails["id"].getInt == 7
    check result.errorRetryable
    check result.output == "record missing"

  test "scripted model records deterministic requests":
    let fake = scriptedModel(@[textResponse("hello")])
    check generateText(fake, prompt = "hi").text == "hello"
    check FakeProvider(fake.provider).requests[0].messages[0].content[0].text == "hi"

  test "invalid tool JSON becomes a tool error and does not execute":
    check parseToolArguments("").parseError.len == 0
    check parseToolArguments("{\"x\":1}").input["x"].getInt == 1
    check parseToolArguments("{nope").parseError.startsWith("invalid tool arguments")
    check invalidToolCall(toolUseFromArgs("call_1", "echo", "{nope")).len > 0
    check not rawTool("echo", "echo", %*{"type": "object"}).parallel
    var ran = 0
    let echoTool = rawTool("echo", "echo", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult =
        inc ran
        ToolResult(output: "should not run"),
      parallel = true)
    check echoTool.parallel
    let p = BadArgsProvider()
    let r = generateText(p.model("m"), prompt = "hi",
      tools = @[echoTool], maxSteps = 2, maxRetries = 0)
    check ran == 0
    check p.calls == 2
    check r.text == "recovered"

  test "parallel execute overlaps":
    let p = ScriptProvider(toolFirst: true, twoTools: true)
    var firstStarted, secondStarted, overlap: Atomic[bool]
    proc slow(_: ToolContext, input: JsonNode): ToolResult {.gcsafe.} =
      if input["x"].getInt == 1:
        firstStarted.store(true)
        if secondStarted.load: overlap.store(true)
      else:
        secondStarted.store(true)
        if firstStarted.load: overlap.store(true)
      sleep(120)
      ToolResult(output: "pong")
    let echoTool = rawTool("echo", "echo", %*{"type": "object"}, slow, parallel = true)
    let r = generateText(p.model("m"), prompt = "hi",
      tools = @[echoTool], maxSteps = 2, maxRetries = 0)
    check overlap.load
    check r.text == "ok"
    check p.calls == 2
    var results: seq[string]
    for msg in p.last.messages:
      for part in msg.content:
        if part.kind == ckToolResult:
          results.add part.toolUseId & ":" & part.output
    check results == @["call_1:pong", "call_2:pong"]

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
    check hyper("k").name == "hyper"
    check hyper("k").endpoint == defaultHyperEndpoint
    check not hyper("k").useResponses
    check hyper("k").maxTokensField == "max_tokens"
    check not hyper("k",
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
    let provider = hyper("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "generate accepts usage without token-details":
    withFixture("hyper_fixture.py") do (port: int):
      let provider = hyper("fixture-key",
        "http://127.0.0.1:" & $port, timeoutSeconds = 5)
      let response = provider.generate(ProviderRequest(
        model: "deepseek-v4-flash", messages: @[userMessage("hi")],
        maxTokens: 16))
      check response.text == "pong"
      check response.usage.inputTokens == 10
      check response.usage.outputTokens == 1
      check not response.usage.cacheReported

suite "OpenAI provider":
  test "native body uses Responses fields and omits Chat Completions extras":
    let body = buildResponsesBody(ProviderRequest(
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
    check openAI("k").name == "openai"
    check openAI("k").endpoint == defaultOpenAiEndpoint
    check openAI("k").useResponses
    check not openAI("k", defaultOpenAiChatEndpoint).useResponses

  test "responses body replays reasoning and function calls":
    let sig = $(%*{"id": "rs_1", "encrypted_content": "enc"})
    let body = buildResponsesBody(ProviderRequest(
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
    let provider = openAI("", "http://127.0.0.1:1")
    expect ProviderError:
      discard provider.generate(ProviderRequest(model: "test",
        messages: @[userMessage("hello")], maxTokens: 10))

  test "generate sends OpenAI fields and reports cache reads":
    withFixture("openai_fixture.py") do (port: int):
      let provider = openAI("fixture-key",
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
      check response.text == "hello from openai"
      check response.content[0].kind == ckThinking
      check response.content[0].thinking == "cached plan"
      check "rs_1" in response.content[0].signature
      check response.usage.inputTokens == 20
      check response.usage.cacheReadTokens == 8
      check response.usage.cacheReported
      check response.requestId == "req-fixture"

  test "HTTP errors retain the provider request id":
    withFixture("openai_fixture.py") do (port: int):
      var caught = false
      try:
        discard openAI("fixture-key", "http://127.0.0.1:" & $port,
          timeoutSeconds = 5).generate(ProviderRequest(model: "wrong"))
      except ProviderError as e:
        caught = true
        check e.status == 400
        check e.requestId == "req-fixture"
      check caught

  test "generateStream emits deltas before the response finishes":
    withFixture("openai_responses_stream_fixture.py") do (port: int):
      let provider = openAI("fixture-key",
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
      check response.text == "Hello world"
      check stamps.len == 2
      check stamps[1] - stamps[0] >= 0.05

  test "generateStream emits tool call deltas":
    withFixture("openai_responses_stream_fixture.py") do (port: int):
      let provider = openAI("fixture-key",
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

suite "encoding":
  test "providers encode image blocks and cache breakpoints":
    check anthropicImageBlock("image/png", "QUJD")["source"]["data"].getStr == "QUJD"
    check "data:image/png;base64,QUJD" in $openAiImagePart("image/png", "QUJD")
    let body = openrouter.buildBody(ProviderRequest(
      model: "vision",
      messages: @[userMessage(@[text("see"), image("image/png", "QUJD")])],
      maxTokens: 10), stream = false)
    let content = body["messages"][0]["content"]
    check content.kind == JArray
    check content.len == 2
    check content[1]["type"].getStr == "image_url"
    check "cache_control" in content[1]
    let sysBody = openrouter.buildBody(ProviderRequest(
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

suite "files, sources, hosted tools":
  test "file parts encode on Anthropic, Responses, and Chat":
    let blocks = @[text("see"), file("application/pdf", "QUJD", filename = "spec.pdf")]
    let req = ProviderRequest(model: "m", messages: @[userMessage(blocks)],
      maxTokens: 10)
    let doc = anthropicDocument(blocks[1].file)
    check doc["type"].getStr == "document"
    check doc["source"]["data"].getStr == "QUJD"
    check doc["title"].getStr == "spec.pdf"
    let resp = buildResponsesBody(req, stream = false)
    check resp["input"][0]["content"][1]["type"].getStr == "input_file"
    check resp["input"][0]["content"][1]["filename"].getStr == "spec.pdf"
    let chat = buildChatBody(req, stream = false)
    check chat["messages"][0]["content"][1]["type"].getStr == "file"
    check chat["messages"][0]["content"][1]["file"]["filename"].getStr == "spec.pdf"

  test "hosted web_search encodes and parses on Responses and Anthropic":
    let tools = toDefinitions(@[hostedTool("web_search")])
    let respBody = buildResponsesBody(ProviderRequest(model: "m",
      messages: @[userMessage("hi")], tools: tools, maxTokens: 10), false)
    check respBody["tools"][0]["type"].getStr == "web_search"
    check "name" notin respBody["tools"][0]
    let anthBody = buildAnthropicBody(ProviderRequest(model: "m",
      messages: @[userMessage("hi")], tools: tools, maxTokens: 10))
    check anthBody["tools"][0]["type"].getStr == "web_search_20250305"
    check anthBody["tools"][0]["name"].getStr == "web_search"
    let parsed = parseAnthropicOutput(%*{
      "model": "claude",
      "stop_reason": "end_turn",
      "content": [
        {"type": "server_tool_use", "id": "s1", "name": "web_search",
          "input": {"query": "nim"}},
        {"type": "web_search_tool_result", "tool_use_id": "s1",
          "content": [{"type": "web_search_result", "url": "https://nim-lang.org",
            "title": "Nim", "encrypted_content": "enc"}]},
        {"type": "text", "text": "Nim is a language",
          "citations": [{"type": "web_search_result_location",
            "url": "https://nim-lang.org", "title": "Nim",
            "cited_text": "Nim is", "encrypted_index": "idx"}]}
      ],
      "usage": {"input_tokens": 10, "output_tokens": 4}
    })
    check parsed.toolCalls.len == 0
    check parsed.content[0].hosted == "web_search"
    check parsed.content[0].name == "web_search"
    check parsed.content[1].kind == ckToolResult
    check parsed.content[1].hosted == "web_search"
    check "encrypted_content" in parsed.content[1].output
    check parsed.content[2].kind == ckText
    check parsed.content[3].kind == ckSource
    check parsed.content[3].source.url == "https://nim-lang.org"
    check parsed.content[3].source.raw["encrypted_index"].getStr == "idx"
    let replayed = buildAnthropicBody(ProviderRequest(model: "m",
      messages: @[userMessage("hi"),
        Message(role: roleAssistant, content: parsed.content)],
      maxTokens: 10))
    let asst = replayed["messages"][1]["content"]
    check asst[0]["type"].getStr == "server_tool_use"
    check asst[1]["type"].getStr == "web_search_tool_result"
    check asst[1]["content"][0]["encrypted_content"].getStr == "enc"
    check asst[2]["citations"][0]["encrypted_index"].getStr == "idx"
    let respReplay = buildResponsesBody(ProviderRequest(model: "m", messages: @[
      userMessage("hi"),
      Message(role: roleAssistant, content: @[
        toolUse("ws_1", "web_search", %*{"type": "search", "query": "nim"},
          hosted = "web_search"),
        text("Nim is a language"),
        source("https://nim-lang.org", "Nim", raw = %*{
          "type": "url_citation", "url": "https://nim-lang.org", "title": "Nim"})
      ])
    ], maxTokens: 10), false)
    check respReplay["input"][1]["type"].getStr == "web_search_call"
    check respReplay["input"][1]["id"].getStr == "ws_1"
    check respReplay["input"][2]["content"][0]["annotations"][0]["url"].getStr ==
      "https://nim-lang.org"

  test "Responses parse web_search_call and url citations":
    let parsed = parseResponsesOutput(%*{
      "model": "gpt-5",
      "status": "completed",
      "output": [
        {"type": "web_search_call", "id": "ws_1", "status": "completed",
          "action": {"type": "search", "query": "nim"}},
        {"type": "message", "role": "assistant", "content": [
          {"type": "output_text", "text": "Nim is compiled.",
            "annotations": [{"type": "url_citation",
              "url": "https://nim-lang.org", "title": "Nim"}]}
        ]}
      ]
    }, "OpenAI")
    check parsed.finishReason == frStop
    check parsed.toolCalls.len == 0
    check parsed.content[0].hosted == "web_search"
    check parsed.content[0].input["query"].getStr == "nim"
    check parsed.content[1].text == "Nim is compiled."
    check parsed.content[2].source.url == "https://nim-lang.org"

  test "Chat Completions rejects hosted tools":
    expect ProviderError:
      discard buildChatBody(ProviderRequest(model: "m",
        messages: @[userMessage("hi")],
        tools: toDefinitions(@[hostedTool("web_search"),
          rawTool("read", "d", %*{"type": "object"})]),
        maxTokens: 10), false)

  test "generateText does not execute hosted tool calls":
    var ran = false
    let local = rawTool("web_search", "should not run", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult =
        ran = true
        ToolResult(output: "nope"))
    let p = HostedScript()
    let r = generateText(p.model("m"), prompt = "hi",
      tools = @[local, hostedTool("server_search")], maxSteps = 5)
    check p.calls == 1
    check not ran
    check r.text == "done"

type
  Heat* = enum
    low
    high

  Recipe* = object
    name*: string
    servings*: int
    ingredients*: seq[string]
    vegetarian*: Option[bool]
    heat*: Heat

  AnnotatedRecipe = object
    title {.jsonDescription: "Display title".}: string
    servings {.jsonMinimum: 1.}: int
    notes {.jsonOptional.}: string

  EmptyRecipe = object

  OptionalRecipe = object
    name: string
    notes {.jsonOptional.}: string

  NestedOptionalRecipe = object
    ingredients: Option[seq[string]]
    details: Option[OptionalRecipe]

  OnlyOptionalRecipe = object
    notes {.jsonOptional.}: string

  RecipeBase = object of RootObj
    id*: string

  RecipeChild = object of RecipeBase
    name*: string

  VariantInheritedRecipe = object of RecipeBase
    case kind*: Heat
    of low:
      mild*: string
    else:
      spicy*: bool

  VariantRecipe = object
    case kind*: Heat
    of low:
      mild*: string
    of high:
      spicy*: bool

  VariantCommonRecipe = object
    common: string
    case kind: Heat
    of low:
      mild: string
    else:
      spicy: bool

  ContainerRecipe = object
    flags: set[Heat]
    tags: HashSet[string]
    counts: Table[string, int]

  Box[T] = object
    value: T

  ObjectScript = ref object of Provider
    calls*: int
    last*: ProviderRequest
    replies*: seq[string]
    finishReasons*: seq[FinishReason]
    toolValue*: JsonNode
    toolValues*: seq[JsonNode]
    toolResponse*: seq[ContentBlock]
    usageEach*: Usage

  ChatObjectScript = ref object of ObjectScript
  GoogleObjectScript = ref object of ObjectScript

method generateAsync(p: ObjectScript,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  p.last = request
  result.usage = p.usageEach
  if p.toolValues.len > 0:
    result.content.add toolUse("call_" & $p.calls, "submit",
      copy(p.toolValues[min(p.calls - 1, p.toolValues.high)]))
    result.finishReason = frToolUse
    return
  if p.toolResponse.len > 0 and p.calls == 1:
    result.content = p.toolResponse
    result.finishReason = frToolUse
    return
  if not p.toolValue.isNil and p.calls == 1:
    result.content.add toolUse("call_1", "submit", copy(p.toolValue))
    result.finishReason = frToolUse
    return
  if p.replies.len > 0:
    result.content.add text(p.replies[min(p.calls - 1, p.replies.high)])
  result.finishReason = if p.finishReasons.len > 0:
    p.finishReasons[min(p.calls - 1, p.finishReasons.high)]
  else:
    frStop

method nativeObjectOptions(p: ChatObjectScript, name, description: string,
                           schema: JsonNode): JsonNode =
  chatObjectOptions(name, description, schema)

method nativeObjectSchemaIssues(p: ChatObjectScript,
                                schema: JsonNode): seq[string] =
  validateOpenAiStrictSchema(schema)

method forceToolOptions(p: ChatObjectScript, toolName: string): JsonNode =
  chatForceToolOptions(toolName)

method nativeObjectOptions(p: GoogleObjectScript, name, description: string,
                           schema: JsonNode): JsonNode =
  %*{"generationConfig": {"responseMimeType": "application/json",
    "responseJsonSchema": schema}}

suite "json schema":
  test "extracts raw, fenced, and prose-wrapped JSON":
    check extractJson("""{"a":1}""")["a"].getInt == 1
    check extractJson("```json\n{\"a\": 2}\n```")["a"].getInt == 2
    check extractJson("here you go:\n{\"a\": 3}\nthanks")["a"].getInt == 3
    check extractJson("[1, 2]")[1].getInt == 2
    check extractJson("nope").isNil
    check extractJson("").isNil

  test "validateSchema covers required, types, enum, and extras":
    let schema = %*{
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "n": {"type": "integer", "minimum": 1, "maximum": 10},
        "tags": {"type": "array", "items": {"type": "string"}, "minItems": 1}
      },
      "required": ["name", "n"]
    }
    check validateSchema(%*{"name": "x", "n": 2, "tags": ["a"]}, schema).len == 0
    check validateSchema(%*{"name": "x", "n": 2.0}, schema).len == 0
    check "required" in validateSchema(%*{"n": 2}, schema).join(" ")
    check "unexpected" in validateSchema(%*{"name": "x", "n": 2, "nope": 1},
      schema).join(" ")
    check "integer" in validateSchema(%*{"name": "x", "n": "two"}, schema).join(" ")
    check "minLength" in validateSchema(%*{"name": "", "n": 2}, schema).join(" ")
    let enumerated = %*{"type": "string", "enum": ["low", "high"]}
    check validateSchema(%"low", enumerated).len == 0
    check "one of" in validateSchema(%"medium", enumerated).join(" ")
    check "$ref" in validateSchema(%*{}, %*{"$ref": "#/defs/x"}).join(" ")

  test "parsePartialJson closes incomplete JSON":
    check parsePartialJson("").state == ppUndefined
    check parsePartialJson("{").state == ppRepaired
    check parsePartialJson("{").value.len == 0
    check parsePartialJson("""{"name":"las""").value["name"].getStr == "las"
    check parsePartialJson("""{"ok":tru""").value["ok"].getBool
    check parsePartialJson("[1, 2").value.len == 2
    check parsePartialJson("""{"a":1}""").state == ppSuccess
    check parsePartialJson("```json\n{\"a\":").value.len == 0
    let escapedKey = parsePartialJson("""{"a\"b":1""")
    check escapedKey.state == ppRepaired
    check escapedKey.value["a\"b"].getInt == 1
    check jsonEqual(%*{"a": 1}, %*{"a": 1})
    check not jsonEqual(%*{"a": 1}, %*{"a": 2})

  test "jsonSchema derives objects, seq, Option, and enums":
    let s = jsonSchema(Recipe)
    check s["type"].getStr == "object"
    check s["additionalProperties"].getBool == false
    check s["properties"]["name"]["type"].getStr == "string"
    check s["properties"]["servings"]["type"].getStr == "integer"
    check s["properties"]["ingredients"]["type"].getStr == "array"
    check s["properties"]["ingredients"]["items"]["type"].getStr == "string"
    check s["properties"]["vegetarian"]["type"].kind == JArray
    check s["properties"]["heat"]["enum"][0].getStr == "low"
    var required: seq[string]
    for x in s["required"]:
      required.add x.getStr
    check "name" in required
    check "vegetarian" in required
    check schemaName("Recipe Title") == "Recipe_Title"
    check schemaName("2bad") == "n2bad"
    check schemaName(repeat('x', 80)).len == 64
    let nestedOptions = jsonSchema(NestedOptionalRecipe)
    check nestedOptions["properties"]["ingredients"]["type"] ==
      %*["array", "null"]
    check nestedOptions["properties"]["details"]["type"] ==
      %*["object", "null"]
    let wire = prepareWireSchema(%*{"type": "object", "properties": {
      "x": {"type": "string"}}})
    check wire["additionalProperties"].getBool == false

  test "jsonSchema preserves typed-schema metadata and object shapes":
    let annotated = jsonSchema(AnnotatedRecipe)
    check annotated["properties"]["title"]["description"].getStr == "Display title"
    check annotated["properties"]["servings"]["minimum"].getInt == 1
    var annotatedRequired: seq[string]
    for key in annotated["required"]:
      annotatedRequired.add key.getStr
    check "notes" notin annotatedRequired
    let inherited = jsonSchema(RecipeChild)
    var inheritedRequired: seq[string]
    for key in inherited["required"]:
      inheritedRequired.add key.getStr
    check "id" in inheritedRequired
    check inherited["properties"]["id"]["type"].getStr == "string"
    check inherited["properties"]["name"]["type"].getStr == "string"
    let variant = jsonSchema(VariantRecipe)
    check validateJsonSchema(variant).len == 0
    check variant["properties"]["kind"]["enum"].len == 2
    check variant["properties"]["mild"]["type"].getStr == "string"
    check variant["properties"]["spicy"]["type"].getStr == "boolean"
    check validateSchema(%*{"kind": "low", "mild": "gentle"}, variant).len == 0
    check validateSchema(%*{"kind": "high", "spicy": true}, variant).len == 0
    check validateSchema(%*{"kind": "low"}, variant).len > 0
    let variantCommon = jsonSchema(VariantCommonRecipe)
    check validateJsonSchema(variantCommon).len == 0
    check validateSchema(%*{"common": "shared", "kind": "low", "mild": "gentle"},
      variantCommon).len == 0
    check validateSchema(%*{"common": "shared", "kind": "high", "spicy": true},
      variantCommon).len == 0
    check validateSchema(%*{"common": "shared", "kind": "low", "spicy": true},
      variantCommon).len > 0
    let variantInherited = jsonSchema(VariantInheritedRecipe)
    check validateSchema(%*{"id": "base", "kind": "high", "spicy": true},
      variantInherited).len == 0
    let fixed = jsonSchema(array[3, string])
    check fixed["minItems"].getInt == 3
    check fixed["maxItems"].getInt == 3
    let containers = jsonSchema(ContainerRecipe)
    check containers["properties"]["flags"]["uniqueItems"].getBool
    check containers["properties"]["tags"]["uniqueItems"].getBool
    check containers["properties"]["counts"]["additionalProperties"]["type"].getStr == "integer"
    check jsonSchema(Box[int])["properties"]["value"]["type"].getStr == "integer"

  test "jsonSchema omits an empty required keyword":
    check "required" notin jsonSchema(EmptyRecipe)
    check "required" notin jsonSchema(OnlyOptionalRecipe)
    check validateJsonSchema(jsonSchema(EmptyRecipe)).len == 0
    check validateJsonSchema(jsonSchema(OnlyOptionalRecipe)).len == 0

  test "preflights malformed and unsupported schemas":
    let issues = validateJsonSchema(%*{
      "type": "object",
      "properties": {"name": {"minLength": "one"}},
      "$ref": "other.json"
    })
    check "$.properties.name.minLength" in issues.join(" ")
    check "$ref: external references are not supported" in issues.join(" ")
    check "unresolved reference" in validateJsonSchema(%*{
      "$ref": "#/missing"}).join(" ")
    let cyclic = %*{
      "$defs": {"node": {"$ref": "#/$defs/node"}},
      "$ref": "#/$defs/node"
    }
    check "cyclic reference" in validateJsonSchema(cyclic).join(" ")

    let p = ObjectScript()
    var err: ref ObjectError
    try:
      discard generateObject(p.model("m"), %*{
        "type": "object", "properties": {"name": {"minLength": "one"}}
      }, prompt = "x", maxRetries = 0)
    except ObjectError as e:
      err = e
    check not err.isNil
    check err.issueDetails.len > 0
    check err.issueDetails[0].path == "$.properties.name.minLength"
    check p.calls == 0

  test "supports local refs and common schema constraints":
    let schema = %*{
      "$defs": {
        "tag": {"type": "string", "pattern": "^[a-z]+$", "minLength": 2}
      },
      "type": "object",
      "properties": {
        "tag": {"$ref": "#/$defs/tag"},
        "values": {"type": "array", "uniqueItems": true,
          "items": {"type": "integer"}}
      },
      "required": ["tag", "values"],
      "additionalProperties": false
    }
    check validateJsonSchema(schema).len == 0
    check validateSchema(%*{"tag": "nim", "values": [1, 2]}, schema).len == 0
    check "pattern" in validateSchema(%*{"tag": "Nim", "values": [1, 2]}, schema).join(" ")
    check "duplicate" in validateSchema(%*{"tag": "nim", "values": [1, 1]}, schema).join(" ")
    let numeric = %*{"type": "number", "exclusiveMinimum": 0,
      "exclusiveMaximum": 2, "multipleOf": 0.5}
    check validateJsonSchema(numeric).len == 0
    check validateSchema(%*1.5, numeric).len == 0
    check "exclusiveMaximum" in validateSchema(%*2, numeric).join(" ")
    check "multiple" in validateSchema(%*0.0000000001,
      %*{"type": "number", "multipleOf": 1}).join(" ")

    let p = ObjectScript(replies: @["""{"tag":"nim","values":[1,2]}"""])
    let r = generateObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0)
    check r.value["tag"].getStr == "nim"

suite "generateObject":
  test "parses scalar JSON values":
    let p = ObjectScript(replies: @["42"])
    let r = generateObject[int](p.model("m"), prompt = "number",
      mode = omJson, maxRetries = 0)
    check r.value == 42

  test "typed optional fields decode to their Nim default when omitted":
    let p = ObjectScript(replies: @["""{"name":"soup"}"""])
    let r = generateObject[OptionalRecipe](p.model("m"), prompt = "cook",
      mode = omJson, maxRetries = 0)
    check r.value.name == "soup"
    check r.value.notes == ""

  test "parses JSON text and returns a typed value":
    let p = ObjectScript(replies: @[
      """{"name":"lasagna","servings":4,"ingredients":["pasta"],"vegetarian":true,"heat":"low"}"""
    ])
    let r = generateObject[Recipe](p.model("m"), prompt = "cook",
      mode = omJson, maxRetries = 0)
    check r.value.name == "lasagna"
    check r.value.servings == 4
    check r.value.ingredients == @["pasta"]
    check r.value.vegetarian == some(true)
    check r.value.heat == low
    check r.repairs == 0
    check r.attempts == 1
    check r.source == osText

  test "extracts fenced JSON and sums usage across repairs":
    let p = ObjectScript(
      replies: @["nope", "```json\n{\"ok\":true}\n```"],
      usageEach: Usage(inputTokens: 5, outputTokens: 2))
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0, maxRepairs = 1)
    check r.value["ok"].getBool
    check r.repairs == 1
    check r.attempts == 2
    check r.usage.inputTokens == 10
    check r.usage.outputTokens == 4
    check p.calls == 2
    check "did not match" in p.last.messages[^1].content[0].text

  test "JSON fallback preserves the caller schema semantics":
    let p = ObjectScript(replies: @["""{"ok":true,"extra":1}"""])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0)
    check r.value == %*{"ok": true, "extra": 1}
    check r.value["extra"].getInt == 1
    check r.repairs == 0
    check "additionalProperties" notin p.last.system[0]

  test "omAuto falls back when a schema is incompatible with native strict output":
    let optional = ChatObjectScript(replies: @["""{"name":"soup"}"""])
    let optionalResult = generateObject[OptionalRecipe](optional.model("m"),
      prompt = "cook", maxRetries = 0)
    check optionalResult.value.name == "soup"
    check optionalResult.source == osText
    check "response_format" notin optional.last.options

    let scalar = ChatObjectScript(replies: @["42"])
    check generateObject[int](scalar.model("m"), prompt = "number",
      maxRetries = 0).value == 42
    check "response_format" notin scalar.last.options

    let variant = ChatObjectScript(replies: @[
      """{"kind":"low","mild":"gentle"}"""])
    let variantResult = generateObject(variant.model("m"),
      jsonSchema(VariantRecipe), prompt = "x", maxRetries = 0)
    check variantResult.value == %*{"kind": "low", "mild": "gentle"}
    check variantResult.source == osText
    check "response_format" notin variant.last.options

  test "omNative rejects incompatible strict schemas before calling provider":
    let p = ChatObjectScript()
    expect ObjectError:
      discard generateObject[OptionalRecipe](p.model("m"), prompt = "x",
        mode = omNative, maxRetries = 0)
    check p.calls == 0

  test "tool mode rejects scalar parameter schemas locally":
    let p = ChatObjectScript()
    expect ObjectError:
      discard generateObject[int](p.model("m"), prompt = "x", mode = omTool,
        maxRetries = 0)
    check p.calls == 0

  test "closes truncated JSON without a model repair":
    let p = ObjectScript(replies: @["{\"ok\": tru"])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0)
    check r.value["ok"].getBool
    check r.repairs == 0
    check p.calls == 1
    check r.locallyRepaired

  test "rejects max-token truncation unless explicitly enabled":
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let rejected = ObjectScript(
      replies: @["{\"ok\": tru"], finishReasons: @[frMaxTokens])
    var err: ref ObjectError
    try:
      discard generateObject(rejected.model("m"), schema, prompt = "x",
        mode = omJson, maxRetries = 0)
    except ObjectError as e:
      err = e
    check not err.isNil
    check "response truncated" in err.msg
    check rejected.calls == 1

    let repaired = ObjectScript(
      replies: @["{\"ok\": tru"], finishReasons: @[frMaxTokens])
    let r = generateObject(repaired.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0, truncation = otRepair)
    check r.value["ok"].getBool
    check r.locallyRepaired

  test "reads a forced tool call":
    let p = ChatObjectScript(toolValue: %*{"ok": true})
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x",
      mode = omTool, maxRetries = 0)
    check r.value["ok"].getBool
    check p.last.tools.len == 1
    check p.last.tools[0].name == "submit"
    check p.last.options["tool_choice"]["function"]["name"].getStr == "submit"
    check r.source == osTool

  test "rejects missing, wrong, and multiple submit calls":
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let wrong = ChatObjectScript(toolResponse: @[
      toolUse("call_1", "other", %*{"ok": true})])
    var err: ref ObjectError
    try:
      discard generateObject(wrong.model("m"), schema, prompt = "x", mode = omTool,
        maxRetries = 0)
    except ObjectError as e:
      err = e
    check not err.isNil
    check "expected 'submit'" in err.msg

    let multiple = ChatObjectScript(toolResponse: @[
      toolUse("call_1", "submit", %*{"ok": true}),
      toolUse("call_2", "submit", %*{"ok": false})])
    err = nil
    try:
      discard generateObject(multiple.model("m"), schema, prompt = "x", mode = omTool,
        maxRetries = 0)
    except ObjectError as e:
      err = e
    check not err.isNil
    check "got 2" in err.msg

  test "tool repairs acknowledge every rejected tool call":
    let p = ChatObjectScript(toolValues: @[
      %*{"ok": "wrong"}, %*{"ok": true}])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x", mode = omTool,
      maxRetries = 0, maxRepairs = 1)
    check r.value["ok"].getBool
    check p.last.messages[^1].content[0].kind == ckToolResult
    check p.last.messages[^1].content[0].toolUseId == "call_1"
    check p.last.messages[^1].content[^1].kind == ckText
    let chatBody = buildChatBody(p.last, false)
    check chatBody["messages"][^2]["role"].getStr == "tool"
    check chatBody["messages"][^1]["role"].getStr == "user"
    let responsesBody = buildResponsesBody(p.last, false)
    check responsesBody["input"][^2]["type"].getStr == "function_call_output"
    check responsesBody["input"][^1]["role"].getStr == "user"

  test "rejects negative maxRepairs before calling the provider":
    let p = ObjectScript(replies: @["{}"])
    expect ProviderError:
      discard generateObject(p.model("m"), %*{"type": "object"}, prompt = "x",
        maxRetries = 0, maxRepairs = -1)
    check p.calls == 0

  test "native Google options preserve generation config siblings":
    let p = GoogleObjectScript(replies: @["""{"ok":true}"""])
    discard generateObject(p.model("m"),
      %*{"type": "object", "properties": {"ok": {"type": "boolean"}},
        "required": ["ok"]},
      prompt = "x", options = %*{"generationConfig": {"temperature": 0.2}},
      maxRetries = 0)
    check p.last.options["generationConfig"]["temperature"].getFloat == 0.2
    check p.last.options["generationConfig"]["responseMimeType"].getStr ==
      "application/json"

  test "omAuto attaches native OpenRouter response_format":
    let p = ChatObjectScript(replies: @["{\"ok\":true}"])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = generateObject(p.model("m"), schema, prompt = "x", maxRetries = 0)
    check r.source == osNative
    check p.last.options["response_format"]["type"].getStr == "json_schema"
    check p.last.options["response_format"]["json_schema"]["strict"].getBool
    check p.last.options["response_format"]["json_schema"]["schema"][
      "additionalProperties"].getBool == false

  test "native and tool modes do not duplicate the full schema":
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let native = ChatObjectScript(replies: @["""{"ok":true}"""])
    discard generateObject(native.model("m"), schema, prompt = "x",
      system = "Be concise", maxRetries = 0)
    check native.last.system.len == 1
    check native.last.system[0].startsWith("Be concise\n\n")
    check "properties" notin native.last.system[0]

    let json = ObjectScript(replies: @["""{"ok":true}"""])
    discard generateObject(json.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0)
    check "properties" in json.last.system[0]

    let tool = ChatObjectScript(toolValue: %*{"ok": true})
    discard generateObject(tool.model("m"), schema, prompt = "x",
      mode = omTool, maxRetries = 0)
    check "properties" notin tool.last.system[0]
    check "submit" in tool.last.system[0]

  test "raises ObjectError after repairs are exhausted":
    let schema = %*{"type": "object", "properties": {"a": {"type": "string"}},
      "required": ["a"]}
    let once = ObjectScript(replies: @["not json"])
    expect ObjectError:
      discard generateObject(once.model("m"), schema, prompt = "x",
        mode = omJson, maxRetries = 0)
    check once.calls == 1
    let p = ObjectScript(replies: @["not json"])
    var err: ref ObjectError
    try:
      discard generateObject(p.model("m"), schema, prompt = "x",
        mode = omJson, maxRepairs = 1, maxRetries = 0)
    except ObjectError as e:
      err = e
    check not err.isNil
    check p.calls == 2
    check err.issueDetails.len > 0

  test "omNative fails when the provider has no native format":
    let p = ObjectScript()
    expect ObjectError:
      discard generateObject(p.model("m"),
        schema = %*{"type": "object"}, prompt = "x", mode = omNative)

  test "native option helpers match each wire format":
    let schema = %*{"type": "object", "properties": {"a": {"type": "string"}}}
    check openAI("k").nativeObjectOptions("o", "", schema)[
      "text"]["format"]["type"].getStr == "json_schema"
    check openAI("k", defaultOpenAiChatEndpoint).nativeObjectOptions(
      "o", "", schema)["response_format"]["type"].getStr == "json_schema"
    check hyper("k").nativeObjectOptions("o", "", schema)[
      "response_format"]["json_schema"]["name"].getStr == "o"
    check openRouter("k", "http://x").nativeObjectOptions(
      "o", "d", schema)["response_format"]["json_schema"]["description"].getStr == "d"
    check anthropic("k", "http://x").nativeObjectOptions(
      "o", "", schema)["output_config"]["format"]["type"].getStr == "json_schema"
    check openAI("k").forceToolOptions("submit")["tool_choice"][
      "type"].getStr == "function"
    check openAI("k").forceToolOptions("submit")["tool_choice"][
      "name"].getStr == "submit"
    check anthropic("k", "http://x").forceToolOptions("submit")[
      "tool_choice"]["type"].getStr == "tool"

  test "addUsage sums cache flags":
    var u = Usage(inputTokens: 1, cacheReadTokens: 2, cacheReported: true)
    u.addUsage(Usage(inputTokens: 3, outputTokens: 4, cacheWriteTokens: 5))
    check u.inputTokens == 4
    check u.outputTokens == 4
    check u.cacheReadTokens == 2
    check u.cacheWriteTokens == 5
    check u.cacheReported

type
  ChunkScript = ref object of Provider
    chunks*: seq[string]
    last*: ProviderRequest
    tool*: bool
    interleaveOther*: bool

method generateStreamAsync(p: ChunkScript, request: ProviderRequest,
                           onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  p.last = request
  var acc = ""
  if p.tool:
    if not onEvent(StreamEvent(kind: seToolCallDelta, toolCallId: "call_1",
        toolName: "submit", toolArgs: "")):
      result.finishReason = frStop
      return
    if p.interleaveOther:
      discard onEvent(StreamEvent(kind: seToolCallDelta, toolCallId: "call_other",
        toolName: "other", toolArgs: "{\"bad\":"))
  for c in p.chunks:
    acc.add c
    let ev =
      if p.tool:
        StreamEvent(kind: seToolCallDelta, toolCallId: "call_1",
          toolName: "submit", toolArgs: c)
      else:
        StreamEvent(kind: seTextDelta, text: c)
    if not onEvent(ev):
      result.finishReason = frStop
      if p.tool:
        result.content.add toolUseFromArgs("call_1", "submit", acc)
      else:
        result.content.add text(acc)
      return
  if p.tool:
    result.content.add toolUseFromArgs("call_1", "submit", acc)
    result.finishReason = frToolUse
  else:
    result.content.add text(acc)
    result.finishReason = frStop
  discard onEvent(StreamEvent(kind: seFinished))

method forceToolOptions(p: ChunkScript, toolName: string): JsonNode =
  chatForceToolOptions(toolName)

suite "streamObject":
  test "emits growing partials then a valid value":
    let p = ChunkScript(chunks: @["{\"n", "ame\":\"a", "bc\",\"n\":", "1}"])
    let schema = %*{
      "type": "object",
      "properties": {"name": {"type": "string"}, "n": {"type": "integer"}},
      "required": ["name", "n"]
    }
    var partials: seq[string] = @[]
    var texts: seq[string] = @[]
    let r = streamObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0,
      onPartial = proc (v: JsonNode): bool =
        partials.add $v
        true,
      onEvent = proc (ev: StreamEvent): bool =
        if ev.kind == seTextDelta: texts.add ev.text
        true)
    check r.value["name"].getStr == "abc"
    check r.value["n"].getInt == 1
    check r.repairs == 0
    check texts == @["{\"n", "ame\":\"a", "bc\",\"n\":", "1}"]
    check partials.len >= 2
    check "abc" in partials[^1]

  test "streams tool-call argument fragments":
    let p = ChunkScript(tool: true, chunks: @["{\"ok\":", "true}"])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    var saw: seq[bool] = @[]
    let r = streamObject(p.model("m"), schema, prompt = "x",
      mode = omTool, maxRetries = 0,
      onPartial = proc (v: JsonNode): bool =
        if "ok" in v: saw.add v["ok"].getBool
        true)
    check r.value["ok"].getBool
    check true in saw

  test "isolates submit arguments from interleaved tool deltas":
    let p = ChunkScript(tool: true, interleaveOther: true,
      chunks: @["{\"ok\":", "true}"])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    var partials: seq[string] = @[]
    let r = streamObject(p.model("m"), schema, prompt = "x", mode = omTool,
      maxRetries = 0,
      onPartial = proc (v: JsonNode): bool =
        partials.add $v
        true)
    check r.value["ok"].getBool
    check partials.len > 0
    check "bad" notin partials.join(" ")

  test "typed streamObject and cancel via onPartial":
    let p = ObjectScript(replies: @[
      """{"name":"lasagna","servings":4,"ingredients":["pasta"],"vegetarian":null,"heat":"low"}"""
    ])
    let r = streamObject[Recipe](p.model("m"), prompt = "cook",
      mode = omJson, maxRetries = 0)
    check r.value.name == "lasagna"
    check r.value.vegetarian.isNone
    let c = ChunkScript(chunks: @["{\"a\":", "1}"])
    var err: ref ProviderError
    try:
      discard streamObject(c.model("m"),
        schema = %*{"type": "object", "properties": {"a": {"type": "integer"}},
          "required": ["a"]},
        prompt = "x", mode = omJson, maxRetries = 0,
        onPartial = proc (_: JsonNode): bool = false)
    except ProviderError as e:
      err = e
    check not err.isNil
    check err.aborted

  test "repairs after a streamed miss":
    let p = ObjectScript(replies: @["nope", """{"ok":true}"""])
    let schema = %*{
      "type": "object",
      "properties": {"ok": {"type": "boolean"}},
      "required": ["ok"]
    }
    let r = streamObject(p.model("m"), schema, prompt = "x",
      mode = omJson, maxRetries = 0, maxRepairs = 1)
    check r.value["ok"].getBool
    check r.repairs == 1
    check p.calls == 2

suite "wrapProvider":
  test "forwards capabilities and structured-output methods":
    let inner = openAI("k")
    let w = wrapProvider(inner)
    check w.name == "openai"
    check w.supports(pcStreaming)
    check w.supports(pcHostedTools)
    check w.nativeObjectOptions("o", "", %*{"type": "object"})["text"]["format"][
      "type"].getStr == "json_schema"
    check w.nativeObjectSchemaIssues(%*{"type": "integer"}).len > 0
    check w.forceToolOptions("submit")["tool_choice"]["name"].getStr == "submit"
    check wrapProvider(inner, name = "gate").name == "gate"
    expect ProviderError:
      discard wrapProvider(nil)

  test "mapRequest and mapResponse apply to generate":
    let fake = scriptedModel(@[textResponse("hello")])
    let w = wrapProvider(fake.provider,
      mapRequest = proc (req: ProviderRequest): ProviderRequest =
        var r = req
        r.system.add "wrapped"
        r,
      mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
        resp.content.add text("[seen]"))
    let r = generateText(w, ProviderRequest(model: "m",
      messages: @[userMessage("hi")]))
    check r.text == "hello\n[seen]"
    check FakeProvider(fake.provider).requests[0].system == @["wrapped"]

  test "mapRequest does not mutate the caller's request":
    let fake = scriptedModel(@[textResponse("hello")])
    let w = wrapProvider(fake.provider,
      mapRequest = proc (req: ProviderRequest): ProviderRequest =
        var r = req
        r.system.add "wrapped"
        r)
    var req = ProviderRequest(model: "m", messages: @[userMessage("hi")])
    discard generateText(w, req)
    check req.system.len == 0

  test "streaming passes through live deltas and both hooks":
    let c = ChunkScript(chunks: @["he", "llo"])
    let w = wrapProvider(c,
      mapRequest = proc (req: ProviderRequest): ProviderRequest =
        var r = req
        r.system.add "wrapped"
        r,
      mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
        resp.content.add text("[seen]"))
    var pieces: seq[string] = @[]
    let resp = streamText(w.model("m"), prompt = "hi",
      onEvent = proc (ev: StreamEvent): bool =
        if ev.kind == seTextDelta: pieces.add ev.text
        true)
    check pieces == @["he", "llo"]
    check resp.text == "hello\n[seen]"
    check c.last.system == @["wrapped"]

  test "generateObject keeps native structured output through the wrapper":
    let p = ChatObjectScript(replies: @["{\"ok\":true}"])
    let w = wrapProvider(p)
    let r = generateObject(w.model("m"),
      schema = %*{"type": "object", "properties": {"ok": {"type": "boolean"}},
        "required": ["ok"]},
      prompt = "x", maxRetries = 0)
    check r.value["ok"].getBool
    check p.last.options["response_format"]["type"].getStr == "json_schema"

suite "typed provider options":
  test "unset values, false, zero and namespace isolation":
    check resolveOptions(nil, ProviderOptions(), "openai") == newJObject()
    let scoped = ProviderOptions(
      openai: OpenAIOptions(store: some(false), dimensions: some(0)),
      anthropic: AnthropicOptions(thinking: some(AdaptiveThinking)),
      openrouter: OpenRouterOptions(routing: some(OpenRouterRouting(
        allowFallbacks: some(false), only: some(newSeq[string]())))))
    check resolveOptions(nil, scoped, "openai") == %*{"store": false, "dimensions": 0}
    check resolveOptions(nil, scoped, "anthropic") == %*{"thinking": {"type": "adaptive"}}
    check resolveOptions(nil, scoped, "openrouter") ==
      %*{"provider": {"allow_fallbacks": false, "only": []}}
    check resolveOptions(nil, scoped, "hyper") == newJObject()

  test "shallow precedence and caller JSON ownership":
    let requestOptions = %*{"store": true, "metadata": {"old": "value"}}
    let extra = %*{"store": true, "metadata": {"new": "value"}}
    let scoped = ProviderOptions(openai: OpenAIOptions(store: some(false), extra: extra),
      extra: %*{"openai": {"user": "test"}, "hyper": {"temperature": 0}})
    let resolved = resolveOptions(requestOptions, scoped, "openai")
    check resolved == %*{"store": false, "metadata": {"new": "value"}, "user": "test"}
    resolved["metadata"]["new"] = %"changed"
    check extra["metadata"]["new"].getStr == "value"
    check requestOptions["store"].getBool
    check resolveOptions(nil, scoped, "hyper") == %*{"temperature": 0}
    expect ProviderError:
      discard resolveOptions(nil, ProviderOptions(openai: OpenAIOptions(extra: %*[1])), "openai")
    expect ProviderError:
      discard resolveOptions(nil, ProviderOptions(extra: %*[1]), "openai")
    expect ProviderError:
      discard resolveOptions(nil, ProviderOptions(extra: %*{"openai": 1}), "openai")

  test "reasoning serializes for both OpenAI APIs":
    let opts = resolveOptions(nil, ProviderOptions(openai: OpenAIOptions(
      reasoningEffort: some("high"), parallelToolCalls: some(false))), "openai")
    let req = ProviderRequest(model: "test", messages: @[userMessage("hello")], options: opts)
    let responses = buildResponsesBody(req, false)
    check responses["reasoning"]["effort"].getStr == "high"
    check "reasoning_effort" notin responses
    check not responses["parallel_tool_calls"].getBool
    let chat = buildChatBody(req, false)
    check chat["reasoning_effort"].getStr == "high"

  test "Anthropic thinking validates and budgets once":
    let opts = resolveOptions(nil, ProviderOptions(anthropic: AnthropicOptions(
      thinking: some(EnabledThinking), budgetTokens: some(2048))), "anthropic")
    let req = ProviderRequest(model: "test", maxTokens: 100, options: opts)
    check buildAnthropicBody(req)["max_tokens"].getInt == 2148
    check buildAnthropicBody(req)["max_tokens"].getInt == 2148
    for value in [AnthropicOptions(thinking: some(EnabledThinking)),
                  AnthropicOptions(budgetTokens: some(2048)),
                  AnthropicOptions(thinking: some(AdaptiveThinking), budgetTokens: some(2048))]:
      expect ProviderError:
        discard value.toProviderJson

  test "sync, async, streaming and ready-made request forwarding":
    let model = scriptedModel(@[textResponse("ok")])
    model.provider.name = "openai"
    let p = FakeProvider(model.provider)
    let scoped = ProviderOptions(openai: OpenAIOptions(store: some(false)))
    let onEvent: StreamCallback = proc (ev: StreamEvent): bool = true
    discard generateText(model, prompt = "hi", providerOptions = scoped)
    discard waitFor generateTextAsync(model, prompt = "hi", providerOptions = scoped)
    discard streamText(model, onEvent, prompt = "hi", providerOptions = scoped)
    discard waitFor streamTextAsync(model, onEvent, prompt = "hi", providerOptions = scoped)
    let req = ProviderRequest(model: "test", messages: @[userMessage("hi")])
    discard generateText(p, req, providerOptions = scoped)
    discard streamText(p, req, onEvent, providerOptions = scoped)
    check p.requests.len == 6
    for request in p.requests: check request.options == %*{"store": false}

  test "embedding API forwards typed options":
    withFixture("openai_embeddings_fixture.py", proc (port: int) =
      let model = openAI("test", endpoint = "http://127.0.0.1:" & $port & "/v1/responses").embeddingModel("text-embedding-3-small")
      let response = embedMany(model, @["alpha", "beta"],
        providerOptions = ProviderOptions(openai: OpenAIOptions(dimensions: some(2))))
      check response.embeddings == @[@[1.0, 0.0], @[0.0, 1.0]]
      check embed(model, "single", providerOptions = ProviderOptions()).embedding == @[0.5, 0.5])

  test "typed effort overrides native Responses effort without mutation":
    let requestOptions = %*{"reasoning": {"effort": "low", "summary": "auto"}}
    let opts = resolveOptions(requestOptions, ProviderOptions(openai: OpenAIOptions(
      reasoningEffort: some("high"))), "openai")
    let body = buildResponsesBody(ProviderRequest(model: "test", options: opts), false)
    check body["reasoning"] == %*{"effort": "high", "summary": "auto"}
    check requestOptions["reasoning"]["effort"].getStr == "low"

  test "structured output wins over provider extras across object modes":
    type Answer = object
      ok: bool
    let p = ChatObjectScript(name: "openai", replies: @["{\"ok\":true}"])
    let model = p.model("test")
    let schema = jsonSchema(Answer)
    let scoped = ProviderOptions(openai: OpenAIOptions(store: some(false),
      extra: %*{"response_format": {"type": "text"}, "tool_choice": "none"}))
    discard generateObject(model, schema, prompt = "x", providerOptions = scoped)
    check p.last.options["response_format"]["type"].getStr == "json_schema"
    discard generateObject[Answer](model, prompt = "x", providerOptions = scoped)
    check not p.last.options["store"].getBool
    discard waitFor generateObjectAsync[Answer](model, prompt = "x", providerOptions = scoped)
    check not p.last.options["store"].getBool
    discard streamObject(model, schema, prompt = "x", providerOptions = scoped)
    check p.last.options["response_format"]["type"].getStr == "json_schema"
    discard streamObject[Answer](model, prompt = "x", providerOptions = scoped)
    check not p.last.options["store"].getBool
    discard waitFor streamObjectAsync[Answer](model, prompt = "x", providerOptions = scoped)
    check not p.last.options["store"].getBool
    let toolP = ChatObjectScript(toolValue: %*{"ok": true})
    discard generateObject(toolP.model("test"), schema, prompt = "x",
      mode = omTool, providerOptions = scoped)
    check toolP.last.options["tool_choice"]["function"]["name"].getStr == "submit"

suite "first-class Agent API":
  test "runs a bounded typed-tool agent with configured defaults":
    let p = ScriptProvider(toolFirst: true)
    type EchoInput = object
      x: int
    let echoTool = tool[EchoInput, string]("echo", "echo",
      proc (_: ToolContext, _: EchoInput): string = "pong")
    let agent = newAgent(p.model("m"),
      instructions = "Be concise.", tools = @[echoTool], maxSteps = 2,
      maxRetries = 0)
    let response = agent.run("hi")
    check response.text == "ok"
    check response.steps.len == 2
    check p.calls == 2
    check p.last.system == @["Be concise."]

  test "streams through the same agent configuration":
    let p = ScriptProvider()
    let agent = newAgent(p.model("m"), instructions = "Be concise.",
      maxRetries = 0)
    var deltas: seq[string]
    let response = agent.stream("hi", proc (ev: StreamEvent): bool =
      if ev.kind == seTextDelta: deltas.add ev.text
      true)
    check deltas == @["ok"]
    check response.text == "ok"

  test "rejects invalid agent configuration":
    let p = ScriptProvider()
    expect ProviderError:
      discard newAgent(p.model("m"), maxSteps = 0)

suite "agent sessions":
  test "records lifecycle events and forwards the session id":
    let p = ScriptProvider()
    let conversation = newSession(newAgent(p.model("m"), maxRetries = 0),
      id = "session-1")
    discard conversation.run("hello")
    check p.last.sessionId == "session-1"
    check conversation.events.mapIt(it.kind) == @[
      sekTurnStarted, sekUser, sekAssistant, sekTurnFinished]
    check conversation.events[0].prompt == "hello"
    check conversation.events[^1].response.text == "ok"

  test "round trips the event log and derived state through JSON":
    let p = ScriptProvider(toolFirst: true)
    type EchoInput = object
      x: int
    let echoTool = tool[EchoInput, string]("echo", "echo",
      proc (_: ToolContext, _: EchoInput): string = "pong")
    let conversation = newSession(newAgent(p.model("m"), tools = @[echoTool],
      maxSteps = 2, maxRetries = 0), id = "round-trip")
    discard conversation.run("hello")
    let restored = sessionFromJson(newAgent(p.model("m"), tools = @[echoTool],
      maxSteps = 2, maxRetries = 0), conversation.sessionJson)
    check restored.id == "round-trip"
    check restored.sessionJson == conversation.sessionJson
    check restored.sessionJsonString == conversation.sessionJsonString
    check restored.turns == 1
    check restored.totalUsage == conversation.totalUsage
    check restored.lastResponse.text == "ok"

  test "round trips multimodal and provider-native content metadata":
    var thinking = ContentBlock(kind: ckThinking, thinking: "scratch",
      signature: "signed")
    thinking.googlePart = %*{"thought": true}
    var call = toolUse("call", "lookup", %*{"q": "Nim"})
    call.thoughtSignature = "tool-signature"
    var toolOutput = toolResult("call", "result", images = @[
      ImageContent(mimeType: "image/png", data: "QUJD", path: "tile.png")])
    toolOutput.googlePart = %*{"function_response": true}
    let blocks = @[
      text("hello"), thinking, call, toolOutput,
      image("image/png", "REVG", "photo.png"),
      file("application/pdf", "R0hJ", "spec.pdf", "spec.pdf"),
      source("https://example.com", "Example", "src-1", "quoted",
        %*{"raw": "citation"})]
    let conversation = newSession(newAgent(ScriptProvider().model("m")),
      @[userMessage(blocks)], id = "metadata")
    let restored = sessionFromJson(newAgent(ScriptProvider().model("m")),
      conversation.sessionJson)
    check restored.events[0].message.content.len == blocks.len
    check restored.events[0].message.content[1].googlePart["thought"].getBool
    check restored.events[0].message.content[2].thoughtSignature == "tool-signature"
    check restored.events[0].message.content[3].images[0].path == "tile.png"
    check restored.events[0].message.content[3].googlePart["function_response"].getBool
    check restored.events[0].message.content[4].data == "REVG"
    check restored.events[0].message.content[5].file.data == "R0hJ"
    check restored.events[0].message.content[6].source.raw["raw"].getStr == "citation"

  test "persists failed turns without adding incomplete messages":
    let conversation = newSession(newAgent(BoomProvider().model("m"),
      maxRetries = 0), id = "failed")
    expect ProviderError:
      discard conversation.run("hello")
    check conversation.events.len == 2
    check conversation.events[0].kind == sekTurnStarted
    check conversation.events[1].kind == sekTurnFailed
    check conversation.events[1].error.startsWith("prompt is too long")
    let restored = sessionFromJson(newAgent(BoomProvider().model("m"),
      maxRetries = 0), conversation.sessionJsonString)
    check restored.sessionJson == conversation.sessionJson

  test "retains transcript and accumulates usage across turns":
    let p = ScriptProvider(toolFirst: true)
    type EchoInput = object
      x: int
    let echoTool = tool[EchoInput, string]("echo", "echo",
      proc (_: ToolContext, _: EchoInput): string = "pong")
    let conversation = newSession(newAgent(p.model("m"),
      instructions = "Be concise.", tools = @[echoTool], maxSteps = 2,
      maxRetries = 0))
    let first = conversation.run("first")
    check first.text == "ok"
    check conversation.turns == 1
    check conversation.events.len == 6
    check conversation.events[1].message.role == roleUser
    check conversation.events[2].message.role == roleAssistant
    check conversation.events[2].message.content[0].kind == ckToolUse
    check conversation.events[3].toolResults[0].kind == ckToolResult
    check conversation.events[4].message.content[0].text == "ok"
    let second = conversation.run("second")
    check second.text == "ok"
    check conversation.turns == 2
    check conversation.events.len == 10
    check conversation.totalUsage.inputTokens == 6
    check conversation.totalUsage.outputTokens == 12
    check conversation.lastResponse.text == "ok"

  test "streaming commits only after the turn completes":
    let conversation = newSession(newAgent(ScriptProvider().model("m"),
      maxRetries = 0))
    var deltas: seq[string]
    let response = conversation.stream("hello", proc (ev: StreamEvent): bool =
      if ev.kind == seTextDelta: deltas.add ev.text
      true)
    check response.text == "ok"
    check deltas == @["ok"]
    check conversation.events.len == 4
    check conversation.events[2].message.content[0].text == "ok"

  test "reset clears state but keeps the agent":
    let conversation = newSession(newAgent(ScriptProvider().model("m"),
      maxRetries = 0))
    discard conversation.run("hello")
    conversation.reset()
    check conversation.turns == 0
    check conversation.totalUsage == Usage()
