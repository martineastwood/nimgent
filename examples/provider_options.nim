## Typed settings are selected by the model's provider; other namespaces are ignored.
import std/[options, os]
import nimgent
import nimgent/providers/openai

let settings = ProviderOptions(
  openai: OpenAIOptions(reasoningEffort: some("high"), store: some(false)),
  anthropic: AnthropicOptions(thinking: some(AdaptiveThinking)),
  openrouter: OpenRouterOptions(routing: some(OpenRouterRouting(
    sort: some("latency"), allowFallbacks: some(false)))))

let model = openAI(getEnv("OPENAI_API_KEY")).model(getEnv("OPENAI_MODEL", "gpt-5"))
echo generateText(model, prompt = "Why is the sky blue?",
  providerOptions = settings).text
