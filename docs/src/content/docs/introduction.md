---
title: Introduction
description: Build LLM applications and agents in Nim with one typed API across model providers.
---

Build Nim applications and agents with one typed API for text generation,
streaming, tools, structured output, conversations, embeddings, retrieval, and
MCP clients. Start with one provider, then switch providers without rewriting
the rest of your application.

## Your first agent

Install nimgent with Nimble and set the API key for the provider you want to
use:

```sh
nimble install nimgent
export OPENAI_API_KEY=...
```

Create `agent.nim`:

```nim
import std/os
import nimgent
import nimgent/agent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let assistant = newAgent(
  model,
  instructions = "You are a concise assistant.",
  maxSteps = 3)

let response = assistant.run("Explain Nim in one sentence.")
echo response.text
```

Run it with:

```sh
nim c -r agent.nim
```

An agent combines a model with instructions, optional tools, and a step limit.
For a regular request, call `generateText` directly. For an application that
needs output as it arrives, use the streaming APIs.

## Why nimgent

- **One API across providers:** connect to OpenAI, Anthropic, Google Gemini,
  OpenRouter, Hyper, Mistral, OpenCode, OpenCode Zen, or your own provider.
- **Nim types at the boundary:** define tool inputs and structured results as
  Nim types instead of parsing untyped JSON by hand.
- **Async and streaming:** use blocking helpers in scripts, or async and
  streaming APIs in servers, applications, and interactive interfaces.
- **Agents and conversations:** reuse model and tool setup, then keep conversation
  history when later requests need earlier context.
- **Useful building blocks:** add embeddings and retrieval, files and images,
  MCP tools, tracing, retries, and deterministic testing as your application
  grows.

## What you get

- **LLM and embedding workflows:** generate complete responses, stream output,
  run calls asynchronously, and create embeddings for search, recommendations,
  and semantic comparison.
- **Provider portability:** use OpenAI, Anthropic, Google Gemini, OpenRouter,
  Hyper, Mistral, OpenCode, OpenCode Zen, or a custom provider without changing
  the rest of your application.
- **Agents and conversations:** combine models with instructions, typed tools,
  bounded steps, approvals, and conversation history.
- **RAG and retrieval:** index embeddings in vector stores, search
  by similarity, persist the store as JSON, and ground model responses in your
  own documents.
- **Structured data extraction:** turn unstructured model responses into
  validated Nim values with generated JSON Schema and optional streaming.
- **MCP and multimodal inputs:** connect remote MCP tools, resources, and
  prompts, or send local files and images to compatible models.
- **Production tooling:** handle typed provider errors, retries, cancellation,
  token usage, tracing, and deterministic offline tests with scripted models.

## What you can build

### Generate text

Use `generateText` for a complete response:

```nim
let response = generateText(model, prompt = "Say hello in one sentence.")
echo response.text
```

Use `generateTextAsync` when the calling code already runs Nim's event loop.

### Stream responses

Use `streamText` to render text as the model produces it. Streams can also
include thinking, tool calls, structured objects, and normalized agent events.
Return `false` from a stream callback when you need to cancel the request.

### Call typed tools

Declare a Nim input type and pass a `tool` to `generateText` or an agent. The
model receives the generated schema, and your handler receives a decoded Nim
value when the tool is called.

### Receive structured output

Use `generateObject[T]` when the response should be a Nim value rather than
free-form text. nimgent derives the schema, validates the response, and
decodes it into `T`.

### Build RAG applications

Use embeddings to index your documents, retrieve the most relevant content for
a question, and include that content in the model prompt. The
[Embeddings & RAG guide](/nimgent/guides/embeddings-rag/)
walks through a complete local RAG flow.

### Keep conversations

Wrap an agent in a `Conversation` when follow-up requests should include earlier
messages and tool results. Conversations can also be inspected, limited, saved, and
restored.

## Why Nim works well for AI applications

An AI application still needs to handle concurrency, data transformation,
local tools, files, network services, and deployment around each model call.
nimgent lets you keep that work in Nim, with:

- native binaries and straightforward OS integration;
- typed application code for tools and structured results;
- async primitives for concurrent model and tool work; and
- no hosted service required by the library.

## Where to go next

- [Quickstart](/nimgent/guides/quickstart/): build a small application step by step.
- [Providers](/nimgent/guides/providers/): connect a provider and choose a model.
- [Streaming](/nimgent/guides/streaming/): render responses and agent events as they arrive.
- [Tools and agents](/nimgent/guides/tools-and-agents/): add typed tools, approvals, and reusable agents.
- [Structured output](/nimgent/guides/structured-output/): turn model responses into validated Nim values.
- [Conversations](/nimgent/guides/conversations/): preserve and manage conversation history.
- [Examples](/nimgent/examples/): copy complete programs for common tasks.
