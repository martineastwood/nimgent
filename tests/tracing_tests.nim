import std/[asyncdispatch, json, strutils, unittest]
import nimgent

type
  TraceProvider = ref object of Provider
    calls: int
    failLeft: int
    toolFirst: bool
    objectResponse: bool

method generateAsync(p: TraceProvider,
                     request: ProviderRequest): Future[ProviderResponse] {.async.} =
  inc p.calls
  if p.failLeft > 0:
    dec p.failLeft
    raiseProviderError("rate limited", status = 429)
  result.model = request.model
  result.usage = Usage(inputTokens: 3, outputTokens: 2)
  if p.toolFirst and p.calls == 1:
    result.content.add toolUse("call-1", "echo", %*{"value": "secret"})
    result.finishReason = frToolUse
  elif p.objectResponse:
    result.content.add text("{\"value\":1}")
    result.finishReason = frStop
  else:
    result.content.add text("done")
    result.finishReason = frStop

method embedAsync(p: TraceProvider,
                  request: EmbeddingRequest): Future[EmbeddingResponse] {.async.} =
  result.model = request.model
  result.requestId = "embedding-1"
  result.usage.tokens = request.values.len
  for _ in request.values:
    result.embeddings.add @[1.0, 2.0]

proc named(spans: seq[TraceSpan], name: string): seq[TraceSpan] =
  for span in spans:
    if span.name == name:
      result.add span

suite "tracing":
  test "traces runs, steps, model calls, and tools without content":
    let provider = TraceProvider(toolFirst: true)
    let echoTool = rawTool("echo", "Echo a value", %*{"type": "object"},
      proc (_: ToolContext, _: JsonNode): ToolResult =
        ToolResult(output: "secret output"))
    var spans: seq[TraceSpan]
    let response = generateText(provider.model("test-model"),
      prompt = "secret prompt", tools = @[echoTool], maxSteps = 2,
      conversationId = "conversation-1",
      callbacks = RunCallbacks(trace: proc (span: TraceSpan) = spans.add span))
    check response.text == "done"
    check named(spans, "nimgent.run").len == 1
    check named(spans, "nimgent.step").len == 2
    check named(spans, "nimgent.model").len == 2
    check named(spans, "nimgent.tool").len == 1
    let run = named(spans, "nimgent.run")[0]
    let steps = named(spans, "nimgent.step")
    let models = named(spans, "nimgent.model")
    let tool = named(spans, "nimgent.tool")[0]
    check run.parentSpanId == ""
    check steps[0].parentSpanId == run.spanId
    check models[0].parentSpanId == steps[0].spanId
    check tool.parentSpanId == steps[0].spanId
    check run.status == ssOk
    check tool.status == ssOk
    check ($run.attributes).find("secret prompt") < 0
    check ($run.attributes).find("secret output") < 0
    check run.attributes["input_tokens"].getInt == 6
    check run.attributes["conversation_id"].getStr == "conversation-1"
    check "session_id" notin run.attributes

  test "traces each retry as a separate model span":
    let provider = TraceProvider(failLeft: 1)
    var spans: seq[TraceSpan]
    discard generateText(provider.model("test-model"), prompt = "hello",
      maxRetries = 1,
      callbacks = RunCallbacks(trace: proc (span: TraceSpan) = spans.add span))
    let models = named(spans, "nimgent.model")
    check models.len == 2
    check models[0].status == ssError
    check models[0].attributes["will_retry"].getBool
    check models[1].status == ssOk

  test "traces streaming and embeddings":
    let provider = TraceProvider()
    var spans: seq[TraceSpan]
    discard streamText(provider.model("test-model"), prompt = "hello",
      onEvent = proc (_: StreamEvent): bool = true,
      callbacks = RunCallbacks(trace: proc (span: TraceSpan) = spans.add span))
    check named(spans, "nimgent.run")[0].attributes["stream"].getBool
    check named(spans, "nimgent.model")[0].attributes["stream"].getBool

    spans.setLen(0)
    let embeddings = embedMany(provider.embeddingModel("embed-model"),
      @["one", "two"], trace = proc (span: TraceSpan) = spans.add span)
    check embeddings.embeddings.len == 2
    check named(spans, "nimgent.embedding").len == 1
    check named(spans, "nimgent.embedding.attempt").len == 1
    check named(spans, "nimgent.embedding")[0].status == ssOk

  test "traces structured-output model calls":
    let provider = TraceProvider(objectResponse: true)
    var spans: seq[TraceSpan]
    let schema = %*{
      "type": "object",
      "properties": {"value": {"type": "integer"}},
      "required": ["value"]
    }
    let response = generateObject(provider.model("test-model"), schema,
      prompt = "secret prompt",
      trace = proc (span: TraceSpan) = spans.add span)
    check response.value["value"].getInt == 1
    check named(spans, "nimgent.run").len == 1
    check named(spans, "nimgent.model").len == 1

    spans.setLen(0)
    let streamed = streamObject(provider.model("test-model"), schema,
      prompt = "secret prompt", onEvent = proc (_: StreamEvent): bool = true,
      trace = proc (span: TraceSpan) = spans.add span)
    check streamed.value["value"].getInt == 1
    check named(spans, "nimgent.run").len == 1
    check named(spans, "nimgent.model").len == 1
