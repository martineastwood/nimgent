# nimgent

nimgent is a Nim SDK for building applications with language models and
embeddings. It gives you a typed, provider-neutral API for text generation,
streaming, tools, structured output, agents, conversations, retrieval, and MCP
clients.

You can use the same generation code with OpenAI, Anthropic, Google Gemini,
OpenRouter, Hyper, Mistral, OpenCode, OpenCode Zen, or your own provider. 

## Install

You need Nim 2.0 or later. Install nimgent with Nimble:

```sh
nimble install nimgent
```

The examples below use OpenAI. Set your API key before running them:

```sh
export OPENAI_API_KEY=...
```

## Quickstart

Create `hello.nim` and ask a model for a response:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(
  model,
  system = "You are a concise assistant.",
  prompt = "Explain why the sky is blue in one sentence.")

echo response.text
```

Compile and run it with:

```sh
nim c -r hello.nim
```

`response.text` contains the generated text. The response also includes the
normalized content, usage, finish reason, request ID, and model steps.

## Stream text

Use `streamText` when you want to show output as it arrives:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = streamText(
  model,
  prompt = "Write a short haiku about Nim.",
  onEvent = proc (event: StreamEvent): bool =
    if event.kind == seTextDelta:
      stdout.write event.text
      flushFile(stdout)
    true)

echo "\nFinished: ", response.finishReason
```

Return `false` from the callback to cancel a stream. Use the `Async` variants
in applications that already run Nim's event loop. See the
[streaming guide](https://nimgent.niminal.dev/guides/streaming/)
for text, tool-call, and agent streaming.

## Give the model typed tools

Define a Nim input type and a callback, then pass the tool to
`generateText`:

```nim
import std/os
import nimgent
import nimgent/providers/openai

type WeatherInput = object
  city: string

let weather = tool(
  "get_weather",
  "Get the current weather for a city",
  proc (_: ToolContext, input: WeatherInput): string =
    input.city & ": 16C and cloudy")

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(
  model,
  prompt = "Should I bring an umbrella to Paris?",
  tools = @[weather],
  maxSteps = 5)

echo response.text
```

nimgent derives the tool's input schema from `WeatherInput`, runs the callback
when the model requests it, and sends the result back to the model. Set
`maxSteps` above `1` when a request is allowed to continue through multiple
model and tool turns. See [Tools and agents](https://nimgent.niminal.dev/guides/tools-and-agents/)
for typed results, failures, approvals, and hosted tools.

## Receive structured output

When your application needs data instead of prose, decode the response into a
Nim type:

```nim
import std/[os, strutils]
import nimgent
import nimgent/providers/openai

type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let recipe = generateObject[Recipe](
  model,
  prompt = "Create a recipe for a weeknight lasagna.")

echo recipe.value.name
echo recipe.value.ingredients.join(", ")
```

The type supplies the JSON Schema. nimgent validates the model response and
returns the decoded value in `recipe.value`. Use `streamObject` for partial
structured output, or read the [structured output guide](https://nimgent.niminal.dev/guides/structured-output/)
for schema annotations, native provider modes, and repairs.

## Build agents and conversations

Use an `Agent` to reuse a model, instructions, tools, and step limit. Add a
`Conversation` when follow-up turns should include earlier conversation history:

```nim
import std/os
import nimgent
import nimgent/[agent, conversation]
import nimgent/providers/openai

let assistant = newAgent(
  model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  instructions = "You are a concise research assistant.",
  maxSteps = 5)

let chat = newConversation(assistant)
discard chat.run("My name is Nim.")
echo chat.run("What is my name?").text
```

A long conversation keeps growing. Use `historyLimit` to send only the most
recent messages to the model. It counts messages, not turns, and the conversation
still keeps the full transcript:

```nim
let chat = newConversation(assistant, historyLimit = 20)
```

When the model still needs older context, you summarize it yourself: read the
transcript with `messages` and install a shorter one with `replaceEvents`.

Agent runs have blocking and async forms, plus normalized events for rendering
text, thinking, tool calls, and approvals. Conversations can be serialized and
restored with the same agent configuration. See the [conversations guide](https://nimgent.niminal.dev/guides/conversations/)
and [agent examples](https://nimgent.niminal.dev/examples/agent/).

## Embeddings and retrieval

Create vectors for search, recommendations, or semantic comparison:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).embeddingModel(
  "text-embedding-3-small")
let result = embedMany(model, @[
  "sunny day at the beach",
  "warm afternoon by the ocean"])

echo cosineSimilarity(result.embeddings[0], result.embeddings[1])
```

The optional `nimgent/vector_store` module provides an in-memory vector store
with search, metadata, and JSON save/load. Read [Embeddings & RAG](https://nimgent.niminal.dev/guides/embeddings-rag/)
for a complete retrieval example.

## Providers

In the common case, provider setup is the only part that changes when you
switch model vendors:

```nim
import std/os
import nimgent
import nimgent/providers/anthropic

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Available providers and setup instructions are in the [provider guide](https://nimgent.niminal.dev/guides/providers/).
Use `GenerationOptions` for portable controls such as temperature and stop
sequences. Use typed `ProviderOptions` for provider-specific settings. The
[provider settings guide](https://nimgent.niminal.dev/guides/providers/settings/)
explains both.

## More capabilities

- [Files and images](https://nimgent.niminal.dev/guides/files-and-images/): ask questions about PDFs and images.
- [MCP clients](https://nimgent.niminal.dev/guides/mcp/): discover remote tools, resources, prompts, and tasks.
- [Middleware and routing](https://nimgent.niminal.dev/guides/middleware-and-routing/): wrap providers or choose one from a model ID.
- [Error Handling](https://nimgent.niminal.dev/guides/error-handling/): handle cancellation, rate limits, and context overflow.
- [Observability](https://nimgent.niminal.dev/guides/observability/): observe model runs, tools, retries, and embeddings without recording content.
- [Testing](https://nimgent.niminal.dev/guides/testing/): use deterministic scripted models without an API key or network access.
- [Examples](https://nimgent.niminal.dev/examples/): copyable programs for common tasks.
- [API reference](https://nimgent.niminal.dev/reference/core-api/): core types and the generated procedure reference.

For a guided first project, start with the [Quickstart](https://nimgent.niminal.dev/guides/quickstart/).

## License

MIT. See [LICENSE](LICENSE).
