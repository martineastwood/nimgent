---
title: Files and images
description: Send documents and pictures, and read back the citations that come with them.
---

Prompts do not have to be text. A model that can read a PDF, a screenshot, or a
spreadsheet answers questions that no amount of prose can pin down — "what is
the mascot's name?", "what changed in this chart?", "extract the totals from
this invoice".

Multimodal content is just another content block. You build a message out of
parts, and the adapter encodes each one the way its provider expects.

## Attach a file

Read a local file, hand it to `userMessage` alongside the question:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")

let response = generateText(
  model,
  messages = @[userMessage(@[
    fileFromPath("spec.pdf", "application/pdf"),
    text("Summarize the failure modes in section 3.")])])

echo response.text
```

`fileFromPath(path, mimeType, filename = "")` reads the file, base64-encodes it,
and defaults the filename to the path's basename. The MIME type is yours to
declare — nimgent does not guess it, because a wrong type is a provider-side
error that is harder to read than the one you get for omitting it.

`file(mimeType, data, path = "", filename = "")` is the same thing when you
already hold the bytes, or when they came from somewhere other than the disk.

## Images

Images work the same way, with `imageFromPath` and `image(ImageContent)`:

```nim
let response = generateText(
  model,
  messages = @[userMessage(@[
    imageFromPath("chart.png", "image/png"),
    text("What trend does this chart show?")])])
```

Order matters as much as content: the text part tells the model what to do with
the attachment. An image alone gets a generic description; an image followed by
a specific question gets an answer.

Blocks are values, so you can build them anywhere and pass them around:

```nim
let parts = @[
  image("image/png", base64Data, path = "diagram.png"),
  text("Explain the protocol this diagram shows.")]
```

## Where files are supported

Capabilities advertise what an adapter will accept, and they are worth checking
when your application takes input of any kind:

```nim
if model.provider.supports(pcFiles):
  # safe to attach a document
  discard
```

| Adapter | Images | Files | Encoded as |
| --- | --- | --- | --- |
| OpenAI (Responses) | yes | yes | `input_image`, `input_file` with a data URI |
| OpenAI (Chat Completions) | yes | yes | `image_url` data URI, `{"type": "file"}` payload |
| Anthropic | yes | yes | native `image` and `document` blocks |
| Google Gemini | yes | yes | `inlineData` parts |

Two caveats that are easy to trip over:

- **Capability flags describe nimgent's encoding, not a vendor's promise.** The
  OpenAI-compatible adapters (OpenRouter, Hyper, Mistral, OpenCode) inherit the
  same flags, but whether a given upstream model accepts a document is between
  you and that model. A rejected attachment is a provider error with a status
  code.
- **Base64 is bigger than the file.** Inline attachments inflate the request
  payload by roughly a third, so a large PDF costs latency before it costs
  tokens. Where a provider has a native file upload, that is usually the better
  route — but it is provider-specific and out of nimgent's scope.

## Citations come back as blocks

A model that read a document can tell you *where* it read something. Providers
surface that as citations, and nimgent normalizes them into `ckSource` blocks
alongside the text:

```nim
let response = generateText(
  model,
  messages = @[userMessage(@[
    fileFromPath("spec.pdf", "application/pdf"),
    text("What are the failure modes?")])])

echo response.text                  # the prose only
for part in response.content:
  if part.kind == ckSource:
    echo part.source.url, " — ", part.source.title
    echo part.source.citedText     # when the provider reports it
```

A source block carries `url`, `title`, `id`, `citedText`, and `raw` — the
provider's original citation object, kept verbatim. Note that `response.text`
contains only text blocks: render citations by walking `response.content`, not
by parsing the prose.

Which fields get filled depends on the provider:

| Provider | Citation shape |
| --- | --- |
| OpenAI Responses | `url_citation` and `file_citation` annotations (web and uploaded files) |
| Anthropic | native citations, including quoted `citedText` |
| Google Gemini | web sources from grounding metadata come back as `ckSource` |

## Hosted tools and grounded answers

Google's and Anthropic's server-side search tools are declared like any other
tool, and their findings arrive as citations rather than as content you have to
extract:

```nim
import nimgent/providers/google

let model = google(getEnv("GEMINI_API_KEY")).model("gemini-3.5-flash-lite")

let response = generateText(
  model,
  prompt = "What changed in Nim's latest release? Cite the pages you used.",
  tools = @[hostedTool("web_search"), hostedTool("url_context")])

for part in response.content:
  if part.kind == ckSource:
    echo part.source.url
```

`hostedTool(name, options)` declares a tool the *provider* runs; there is no
local function and no callback. OpenAI Responses, Anthropic, and native Gemini
support them — Chat Completions has no wire format for it, so a hosted tool
there is rejected rather than silently downgraded.

For Gemini, grounding metadata and URL-context statuses are preserved as hosted
tool results — a `web_search` result whose output is the grounding metadata JSON
(citation spans, the queries that were run, and Search Suggestions HTML), and a
`url_context` result carrying each URL's retrieval status. A UI can render
Google's own citation affordances from those instead of reconstructing them.
Only successfully retrieved URLs also appear as `ckSource` blocks.

## Keeping history replayable

Some providers sign their content and reject a conversation whose signatures
were lost in transit. Two fields exist for exactly that, and both are populated
automatically when responses come back:

- `ContentBlock.googlePart` — the original Gemini part, retained so a tool call
  can be replayed with its `thoughtSignature` intact.
- `SourceContent.raw` — the provider's citation object, replayed when a message
  is sent back as history.

If you serialize conversation history yourself, **preserve these fields**.
Dropping them produces a request the provider can reject, and the rejection does
not always point at the missing signature — which is why nimgent keeps them on
the block rather than re-deriving them. Sessions do this for you.

## Dropping attachments

When a provider or a turn cannot take images, `dropImages(messages)` replaces
image blocks with a short text note without touching what a session stores:

```nim
let response = generateText(model, messages = dropImages(history), prompt = "Continue.")
```

That is the intended way to degrade — keep the transcript honest, sanitize at
the boundary. It also composes as a `mapRequest` hook in
[Middleware and routing](/guides/middleware-and-routing/).

Related: [Providers](/guides/providers/) for capability checks and the typed
options that accompany these requests, and [Tools and agents](/guides/tools-and-agents/)
for hosted tools in the agent loop.
