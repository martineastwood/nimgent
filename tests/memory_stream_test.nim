import std/[os, osproc, streams, strutils]
import nimgent
from nimgent/providers/openai import openAI

proc main() =
  let requests = parseInt(getEnv("MEMORY_REQUESTS", "100"))
  let payloadBytes = parseInt(getEnv("MEMORY_PAYLOAD_BYTES", "250000"))
  let fixturePath = getCurrentDir() / "tests" / "repeated_stream_fixture.py"
  var fixture = startProcess("python3", args = @[fixturePath, $requests],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if fixture.running: fixture.terminate()
    fixture.close()

  let provider = openAI("fixture-key", "http://127.0.0.1:" &
    fixture.outputStream.readLine())
  let request = ProviderRequest(model: "test", maxTokens: 8,
    messages: @[userMessage('x'.repeat(payloadBytes))])
  let baseline = getOccupiedMem()
  for _ in 0 ..< requests:
    doAssert provider.generateStream(request,
      proc (_: StreamEvent): bool = true).text == "ok"
  let growth = getOccupiedMem() - baseline
  echo "occupied growth after ", requests, " streams with ", payloadBytes,
    " payload bytes: ", growth, " bytes"
  doAssert growth < max(10_000_000, payloadBytes * 4)

main()
