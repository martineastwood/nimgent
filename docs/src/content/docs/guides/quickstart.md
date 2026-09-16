---
title: Quickstart
description: Build and run your first nimgent agent.
---

This guide takes you from an empty Nim file to a running AI agent. By the end,
you will have a program that sends a question to OpenAI and prints the reply.

## 1. Install nimgent

You need Nim 2.0 or later. Install nimgent with Nimble:

```sh
nimble install nimgent
```

## 2. Set your API key

This example uses OpenAI. Set your key in the environment:

```sh
export OPENAI_API_KEY=...
```

You can use another provider by changing the provider import, constructor, API
key, and model ID. See [Providers](/guides/providers/) for the setup
for each supported provider.

## 3. Build your first agent

Create `agent.nim`:

```nim
import std/os
import nimgent
import nimgent/agent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let assistant = newAgent(
  model,
  instructions = "You are a helpful assistant.")

let response = assistant.run("What is the Nim programming language?")
echo response.text
```

## 4. Run it

Compile and run the program:

```sh
nim c -r agent.nim
```

You should see an answer from the model in your terminal. The exact wording
will vary from one run to the next.

## What just happened

- `openAI(...)` created an OpenAI provider using `OPENAI_API_KEY`.
- `.model("gpt-4o-mini")` selected the model to call.
- `newAgent(...)` combined the model with reusable instructions.
- `assistant.run(...)` sent a prompt and returned a complete response.

The blocking API is a good fit for scripts and command-line programs. Use the
async APIs when your application already runs Nim's event loop.

## Next steps

- [Tools and agents](/guides/tools-and-agents/): let the model call typed Nim functions.
- [Streaming](/guides/streaming/): render text, tool calls, and agent events as they arrive.
- [Structured output](/guides/structured-output/): decode model responses into validated Nim values.
- [Embeddings & RAG](/guides/embeddings-rag/): build RAG applications over your own documents.
- [Conversations](/guides/conversations/): keep conversation history across requests.
- [Providers](/guides/providers/): switch providers and configure provider-specific options.
- [Examples](/examples/): copy complete programs for common tasks.
