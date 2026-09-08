import std/[json, osproc, streams, strutils, unittest]
import nimgent
import nimgent/google

proc fixture(mode: string, body: proc (p: GoogleProvider)) =
  let child = startProcess("python3", args = @["tests/google_fixture.py", mode],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if child.running:
      child.terminate()
      discard child.waitForExit()
    child.close()
  let port = child.outputStream.readLine()
  body(google("fixture-key", "http://127.0.0.1:" & port))
  check child.waitForExit() == 0

suite "native Gemini":
  test "one Google provider exposes generation, hosted tools, and embeddings":
    let p = google("key")
    check p.endpoint == defaultGoogleEndpoint
    for capability in [pcStreaming, pcTools, pcStructuredOutput, pcImages,
                       pcFiles, pcHostedTools, pcEmbeddings]:
      check p.supports(capability)

  test "native batch embeddings preserve order and options":
    fixture("embed", proc (p: GoogleProvider) =
      let response = embedMany(p.embeddingModel("fixture"), @["one", "two"],
        options = %*{"taskType": "RETRIEVAL_DOCUMENT"}, maxRetries = 0)
      check response.embeddings == @[@[1.0, 0.0], @[0.0, 1.0]])

  test "native generation options are not mutated and URL sources retain retrieval metadata":
    let options = %*{"generationConfig": {"temperature": 0.5}}
    let before = copy(options)
    let body = buildGoogleBody(ProviderRequest(maxTokens: 100, options: options))
    check options == before
    check body{"generationConfig", "temperature"}.getFloat == 0.5
    let metadata = %*{"urlMetadata": [{"retrievedUrl": "https://nim-lang.org",
      "urlRetrievalStatus": "URL_RETRIEVAL_STATUS_SUCCESS"}]}
    let parsed = parseGoogleOutput(%*{"candidates": [{"urlContextMetadata": metadata,
      "finishReason": "STOP"}]})
    check parsed.content[0].source.url == "https://nim-lang.org"
    check parsed.content[0].source.raw == metadata["urlMetadata"][0]
    check parsed.content[1].output.parseJson == metadata

  test "streamed text joins without added newlines and preserves the final signature":
    var response: ProviderResponse
    var deltas = ""
    for part in [%*{"text": "ORCHID-"}, %*{"text": "742", "thoughtSignature": "signed"}]:
      discard handleGoogleEvent(response, %*{"candidates": [{"content": {"parts": [part]}}]},
        proc (ev: StreamEvent): bool =
          if ev.kind == seTextDelta: deltas.add ev.text
          true)
    check response.text == "ORCHID-742"
    check deltas == response.text
    let body = buildGoogleBody(ProviderRequest(messages: @[assistantMessage(response.content)]))
    check body["contents"][0]["parts"][0] == %*{"text": "ORCHID-742", "thoughtSignature": "signed"}

  test "native function IDs and signed hosted parts are replayed":
    let raw = %*{"functionCall": {"id": "native-id", "name": "lookup", "args": {}},
      "thoughtSignature": "signature"}
    let server = %*{"toolCall": {"id": "search-id", "toolType": "GOOGLE_SEARCH"},
      "thoughtSignature": "server-signature"}
    let parsed = parseGoogleOutput(%*{"candidates": [{"content": {"parts": [server, raw]},
      "finishReason": "STOP"}]})
    check parsed.toolCalls.len == 1
    let body = buildGoogleBody(ProviderRequest(messages: @[assistantMessage(parsed.content),
      userMessage(@[toolResult("native-id", "ok")])]))
    check body["contents"][0]["parts"][0] == server
    check body["contents"][1]["parts"][0]{"functionResponse", "id"}.getStr == "native-id"

  test "hosted tools and function declarations use native wire format":
    let body = buildGoogleBody(ProviderRequest(model: "gemini-3.5-flash-lite",
      messages: @[userMessage("hello")], system: @["system"], maxTokens: 128,
      options: %*{"reasoning_effort": "low"},
      tools: @[ToolDefinition(hosted: "web_search"), ToolDefinition(hosted: "url_context"),
        ToolDefinition(name: "lookup", inputSchema: %*{"type": "object"})]))
    check body["tools"][0] == %*{"googleSearch": {}}
    check body["tools"][1] == %*{"urlContext": {}}
    check body["tools"][2]["functionDeclarations"][0]["name"].getStr == "lookup"
    check body{"generationConfig", "maxOutputTokens"}.getInt == 128
    check body{"generationConfig", "thinkingConfig", "thinkingLevel"}.getStr == "LOW"
    check not body.hasKey("reasoning_effort")
    expect ProviderError:
      discard buildGoogleBody(ProviderRequest(tools: @[ToolDefinition(hosted: "unknown")]))

  test "signed parts, grounding supports and tool results survive a round trip":
    let rawPart = %*{"functionCall": {"name": "lookup", "args": {}}, "thoughtSignature": "opaque"}
    let grounding = %*{"webSearchQueries": ["Nim"],
      "searchEntryPoint": {"renderedContent": "<div>Search</div>"},
      "groundingChunks": [{"web": {"uri": "https://nim-lang.org", "title": "Nim"}}],
      "groundingSupports": [{"segment": {"text": "Nim"}, "groundingChunkIndices": [0]}]}
    let parsed = parseGoogleOutput(%*{"candidates": [{"content": {"parts": [rawPart]},
      "finishReason": "STOP", "groundingMetadata": grounding}],
      "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 2,
        "thoughtsTokenCount": 3, "cachedContentTokenCount": 4}})
    check parsed.finishReason == frToolUse
    check parsed.toolCalls.len == 1
    check parsed.usage.outputTokens == 5
    check parsed.usage.cacheReadTokens == 4
    check parsed.content[1].source.url == "https://nim-lang.org"
    check parseJson(parsed.content[2].output) == grounding
    let body = buildGoogleBody(ProviderRequest(messages: @[
      assistantMessage(parsed.content), userMessage(@[toolResult(parsed.toolCalls[0].id, "ok")])]))
    check body["contents"][0]["parts"] == %*[rawPart]
    check body["contents"][1]["parts"][0]{"functionResponse", "name"}.getStr == "lookup"

  test "HTTP generation and SSE preserve metadata arriving after finishReason":
    for mode in ["sync", "stream"]:
      fixture(mode, proc (p: GoogleProvider) =
        var deltas = ""
        let req = ProviderRequest(model: "fixture", messages: @[userMessage("hello")],
          tools: @[ToolDefinition(hosted: "web_search")])
        let response = if mode == "sync": generateText(p, req, maxRetries = 0)
          else: streamText(p, req, proc (ev: StreamEvent): bool =
            if ev.kind == seTextDelta: deltas.add ev.text
            true, maxRetries = 0)
        check response.text == "Nim"
        if mode == "stream": check deltas == "Nim"
        check response.usage.inputTokens == 10
        check response.content[^1].hosted == "web_search"
        check response.content[^2].source.url == "https://nim-lang.org")

  test "truncation and HTTP errors are surfaced":
    for mode in ["cut", "error"]:
      fixture(mode, proc (p: GoogleProvider) =
        try:
          discard streamText(p, ProviderRequest(model: "fixture"),
            proc (ev: StreamEvent): bool = true, maxRetries = 0)
          check false
        except ProviderError as e:
          if mode == "cut": check "mid-response" in e.msg
          else:
            check e.status == 429
            check e.retryable)

  test "stream cancellation returns without executable partial tools":
    fixture("stream", proc (p: GoogleProvider) =
      expect CancelledError:
        discard streamText(p, ProviderRequest(model: "fixture"),
          proc (ev: StreamEvent): bool = ev.kind != seTextDelta, maxRetries = 0))
