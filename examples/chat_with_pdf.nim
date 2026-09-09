## Chat with a PDF — pass a PDF path and ask a question about it.
##
##   OPENAI_API_KEY=... nim c -r examples/chat_with_pdf.nim examples/example.pdf

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
