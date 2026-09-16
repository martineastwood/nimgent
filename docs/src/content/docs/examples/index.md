---
title: Examples
description: Runnable examples for common nimgent tasks.
---

These examples show complete programs you can copy, compile, and adapt. They
all live in the repository's [`examples/`](https://github.com/martineastwood/nimgent/tree/main/examples)
directory.

Most examples use OpenAI. Set `OPENAI_API_KEY` before running them, or follow
the provider-specific instructions on the smoke-test pages.

Run an example from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/generate_text.nim
```

The examples cover:

- [Generate text](./generate-text): make a basic model request.
- [Stream text](./stream-text): print text as it arrives.
- [Async generation](./async-generation): run requests concurrently.
- [Tool call](./tool-call): let the model call a typed local function.
- [Agent](./agent): reuse agent configuration across runs.
- [Agent events](./agent-events): observe events and approve tools.
- [Lifecycle callbacks](./lifecycle-callbacks): monitor retries, tools, and steps.
- [Structured output](./structured-output): decode a response into a Nim object.
- [Stream object](./stream-object): receive partial structured output.
- [Conversation](./conversation): continue and serialize a conversation.
- [Embeddings](./embeddings): create vectors and compare similarity.
- [Provider options](./provider-options): configure provider-specific settings.
- [Wrap provider](./wrap-provider): add request and response hooks.
- [Chat with PDF](./chat-with-pdf): send a PDF as file content.
- [MCP client](./mcp-client): discover and call MCP tools.
- [Anthropic smoke test](./anthropic-smoke): try Anthropic streaming and JSON output.
- [Google smoke test](./google-smoke): try Gemini hosted tools and citations.

The PDF example uses the repository's bundled `examples/example.pdf` file. The
smoke tests make live provider requests and need their provider credentials.
