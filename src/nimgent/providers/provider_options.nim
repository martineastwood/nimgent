## Portable and provider-scoped request options.
import std/[json, options]
import nimgent/providers/[provider, openai, anthropic, openrouter, hyper]
export OpenAIOptions, AnthropicOptions, AnthropicThinking, OpenRouterOptions,
  OpenRouterRouting, HyperOptions

type GenerationOptions* = object
  ## Provider-neutral generation controls. Providers map these canonical
  ## fields to their native request names where supported.
  temperature*: Option[float]
  topP*: Option[float]
  topK*: Option[int]
  presencePenalty*: Option[float]
  frequencyPenalty*: Option[float]
  stopSequences*: Option[seq[string]]
  seed*: Option[int]
  reasoning*: Option[string]

type ProviderOptions* = object
  ## Provider-specific extensions. Use `extra` for a provider without a typed
  ## namespace; its keys are always namespaced by provider name.
  openai*: OpenAIOptions
  anthropic*: AnthropicOptions
  openrouter*: OpenRouterOptions
  hyper*: HyperOptions
  extra*: JsonNode ## Additional native namespaces, e.g. {"google": {...}}.

proc toProviderJson*(value: GenerationOptions, providerName: string): JsonNode =
  ## Serialize common settings using the selected provider's wire names.
  result = newJObject()
  let isGoogle = providerName == "google"
  var generationConfig = newJObject()
  template add(field: untyped, key: string) =
    if field.isSome:
      (if isGoogle: generationConfig[key] = %field.get
       else: result[key] = %field.get)
  add(value.temperature, "temperature")
  add(value.topP, if isGoogle: "topP" else: "top_p")
  add(value.topK, if isGoogle: "topK" else: "top_k")
  add(value.presencePenalty, "presence_penalty")
  add(value.frequencyPenalty, "frequency_penalty")
  if value.stopSequences.isSome:
    if isGoogle:
      generationConfig["stopSequences"] = %value.stopSequences.get
    elif providerName == "anthropic":
      result["stop_sequences"] = %value.stopSequences.get
    else:
      result["stop"] = %value.stopSequences.get
  add(value.seed, "seed")
  if value.reasoning.isSome:
    case providerName
    of "openai":
      result["reasoning_effort"] = %value.reasoning.get
    of "hyper", "openrouter":
      result["reasoning"] = %*{"effort": value.reasoning.get}
    of "anthropic":
      result["output_config"] = %*{"effort": value.reasoning.get}
    of "google", "mistral", "opencode", "opencodezen":
      result["reasoning_effort"] = %value.reasoning.get
    else:
      discard
  if isGoogle and generationConfig.len > 0:
    result["generationConfig"] = generationConfig

proc mergeProviderNamespaces(result: var JsonNode, scoped: ProviderOptions,
                             providerName: string) =
  if not scoped.extra.isNil and scoped.extra.kind != JNull:
    if scoped.extra.kind != JObject:
      raiseProviderError("providerOptions.extra must be a JSON object")
    mergeRequestOptions(result, scoped.extra.getOrDefault(providerName))
  case providerName
  of "openai": mergeRequestOptions(result, scoped.openai.toProviderJson)
  of "anthropic": mergeRequestOptions(result, scoped.anthropic.toProviderJson)
  of "openrouter": mergeRequestOptions(result, scoped.openrouter.toProviderJson)
  of "hyper": mergeRequestOptions(result, scoped.hyper.toProviderJson)
  else: discard

proc resolveGenerationOptions*(options: GenerationOptions,
                               scoped: ProviderOptions,
                               providerName: string): JsonNode =
  result = newJObject()
  mergeProviderNamespaces(result, scoped, providerName)
  result = result.copy
  let common = options.toProviderJson(providerName)
  if providerName == "google" and result.hasKey("generationConfig") and
      result["generationConfig"].kind == JObject and
      common.hasKey("generationConfig") and common["generationConfig"].kind == JObject:
    mergeRequestOptions(result["generationConfig"], common["generationConfig"])
    common.delete("generationConfig")
  mergeRequestOptions(result, common)
  result = result.copy
  if providerName == "openai" and options.reasoning.isSome:
    if not result.hasKey("reasoning") or result["reasoning"].kind != JObject:
      result["reasoning"] = newJObject()
    result["reasoning"]["effort"] = %options.reasoning.get
proc resolveOptions*(options: JsonNode, scoped: ProviderOptions,
                     providerName: string): JsonNode =
  ## Low-level merge: raw request options < namespace extra < typed namespace.
  ## Copy to keep serialization and adapter changes from mutating caller JSON.
  result = newJObject()
  mergeRequestOptions(result, options)
  mergeProviderNamespaces(result, scoped, providerName)
  result = result.copy
