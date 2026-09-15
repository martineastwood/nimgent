---
title: Chat with PDF
description: Send a PDF as file content and ask a question about it.
---

Send a PDF to a model with `fileFromPath` and ask about its contents.

The program reads the PDF path from the first command-line argument, wraps the
file block in a user message, and sends it with `generateText`. The model and
provider must accept the supplied file type.

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")

let pdfPath = paramStr(1)
echo "calling the model..."
let response = generateText(
  model,
  messages = @[userMessage(@[
    fileFromPath(pdfPath, "application/pdf"),
    text("What is the mascot's name?")
  ])])

echo response.text
```

Pass the bundled example PDF as the command-line argument:

```sh
OPENAI_API_KEY=... nim c -r examples/chat_with_pdf.nim examples/example.pdf
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/chat_with_pdf.nim)
