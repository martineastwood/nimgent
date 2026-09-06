## Chat with a PDF — pass a PDF path and ask a question about it.
##
##   OPENAI_API_KEY=... nim c -r examples/chat_with_pdf.nim examples/example.pdf

import std/[base64, os]
import nimgent
import nimgent/openai

let provider = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))

let pdfPath = paramStr(1)
let pdfBase64 = encode(readFile(pdfPath))

echo "calling the model..."
let response = generateText(
  provider,
  model = "gpt-4.1-mini",
  messages = @[userMessage(@[
    file("application/pdf", pdfBase64, filename = extractFilename(pdfPath)),
    text("What is the mascot's name?")
  ])])

echo response.textContent
