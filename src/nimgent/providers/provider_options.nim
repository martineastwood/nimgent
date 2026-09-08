## Typed request options, scoped to the logical provider name.
import std/[json, options]
import nimgent/providers/[provider, openai, anthropic, openrouter, google]
export OpenAIOptions, AnthropicOptions, AnthropicThinking, OpenRouterOptions,
  OpenRouterRouting, GoogleOptions

type ProviderOptions* = object
  openai*: OpenAIOptions
  anthropic*: AnthropicOptions
  openrouter*: OpenRouterOptions
  google*: GoogleOptions
  extra*: JsonNode ## Additional provider namespaces, e.g. {"hyper": {...}}.

proc resolveOptions*(options: JsonNode, scoped: ProviderOptions,
                     providerName: string): JsonNode =
  ## Shallow merge: legacy options < namespace extra < typed namespace.
  ## Copy to keep serialization and adapter changes from mutating caller JSON.
  result = newJObject()
  mergeRequestOptions(result, options)
  if not scoped.extra.isNil and scoped.extra.kind != JNull:
    if scoped.extra.kind != JObject:
      raiseProviderError("providerOptions.extra must be a JSON object")
    mergeRequestOptions(result, scoped.extra.getOrDefault(providerName))
  case providerName
  of "openai": mergeRequestOptions(result, scoped.openai.toProviderJson)
  of "anthropic": mergeRequestOptions(result, scoped.anthropic.toProviderJson)
  of "openrouter": mergeRequestOptions(result, scoped.openrouter.toProviderJson)
  of "google": mergeRequestOptions(result, scoped.google.toProviderJson)
  else: discard
  result = result.copy
  # Responses also accepts the native `reasoning` object. Keep an explicit
  # typed effort authoritative when legacy/extra options already contain it.
  if providerName == "openai" and scoped.openai.reasoningEffort.isSome and
      result.hasKey("reasoning") and result["reasoning"].kind == JObject:
    result["reasoning"]["effort"] = %scoped.openai.reasoningEffort.get
