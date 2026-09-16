---
title: Files and images
description: Ask a model to read a document or inspect an image.
---

You can attach a local document or image to a message, then ask the model about it. This is useful for summarizing PDFs, extracting details from reports, or describing a chart or screenshot.

## Ask about a PDF

This example sends a PDF from the command line and prints the answer.

```nim title="pdf_question.nim"
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
let pdfPath = paramStr(1)

let response = generateText(
  model,
  messages = @[userMessage(@[
    fileFromPath(pdfPath, "application/pdf"),
    text("What are the main risks described in this document?")
  ])]
)

echo response.text
```

Run it with a path to your PDF:

```sh
OPENAI_API_KEY=... nim c -r pdf_question.nim report.pdf
```

`fileFromPath` reads the file and attaches it to the message. Pass the file's MIME type so the provider knows how to handle it. Its filename is inferred from the path unless you provide one.

The text in the same message gives the model a clear task. Be specific about what you want to find, summarize, compare, or extract.

## Ask about an image

Use `imageFromPath` for images. The rest of the request works the same way.

```nim
let response = generateText(
  model,
  messages = @[userMessage(@[
    imageFromPath("chart.png", "image/png"),
    text("What trend does this chart show?")
  ])]
)

echo response.text
```

Common image MIME types include `image/png`, `image/jpeg`, and `image/webp`.

## Attach data you already have

If your application already has base64-encoded content, use `file` or `image` instead of writing it to disk first.

```nim
let response = generateText(
  model,
  messages = @[userMessage(@[
    file("application/pdf", encodedPdf, filename = "report.pdf"),
    image("image/png", encodedChart),
    text("Compare the report with the chart.")
  ])]
)
```

`encodedPdf` and `encodedChart` should contain base64 data without a data URL prefix.

## Show citations when they are available

Some providers include sources with their answers. You can read them from the response content and show links alongside the model's text.

```nim
for part in response.content:
  if part.kind == ckSource:
    echo part.source.title
    echo part.source.url
```

Citations are provider and model dependent. An answer without `ckSource` parts is still a valid response.

## Continue without images

If you switch a conversation to a model that does not accept images, remove image attachments before sending its history.

```nim
let response = generateText(
  model,
  messages = dropImages(history),
  prompt = "Continue the conversation."
)
```

`dropImages` replaces each image with a short note. It only removes images, not files.

## Troubleshooting

- **The provider rejects the attachment:** Check that the MIME type matches the file and that the selected model accepts that kind of attachment.
- **Large files fail or give incomplete answers:** Attachments use part of the request size and model context. Try a smaller file, fewer pages, or a more focused question.
- **The model ignores the attachment:** Put a clear instruction in the same message, such as "List the action items in this PDF."

## Next steps

Learn how to choose a provider in the [Providers](/guides/providers/) guide, or keep a multi-turn conversation with attachments in the [Conversations](/guides/conversations/) guide.
