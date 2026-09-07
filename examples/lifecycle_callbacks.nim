## Observe retries, local tool execution, completed steps, and final usage.
##
##   OPENAI_API_KEY=... nim c -r examples/lifecycle_callbacks.nim

import std/[json, os]
import nimgent
import nimgent/openai

type WeatherInput = object
  city: string

let model: LanguageModel = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let weather: Tool = tool("get_weather", "Get the current weather for a city",
  proc (input: WeatherInput): string = input.city & ": 16C and cloudy")

proc logRetry(attempt, delayMs: int, error: ref ProviderError) =
  echo "retry ", attempt, " in ", delayMs, "ms: ", error.msg

proc logToolStart(step: int, call: ContentBlock) =
  echo "step ", step, " tool started: ", call.name

proc logToolFinish(step: int, call, output: ContentBlock, durationMs: int) =
  echo "step ", step, " tool finished: ", call.name,
    " (", durationMs, "ms, error=", output.isError, ")"

proc logStepFinish(step: int, result: StepResult) =
  echo "step ", step, " finished: ", result.finishReason,
    " (", result.usage.outputTokens, " output tokens)"

proc logFinish(response: ProviderResponse) =
  echo "run finished: ", response.steps.len, " steps, ",
    response.totalUsage.outputTokens, " output tokens"

let callbacks: RunCallbacks = RunCallbacks(
  onRetry: logRetry,
  onToolStart: logToolStart,
  onToolFinish: logToolFinish,
  onStepFinish: logStepFinish,
  onFinish: logFinish)

let response: ProviderResponse = generateText(
  model,
  prompt = "What's the weather like in Paris?",
  tools = @[weather],
  maxSteps = 5,
  callbacks = callbacks)

echo response.text
