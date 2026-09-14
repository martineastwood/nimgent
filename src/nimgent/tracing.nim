## Provider-neutral tracing primitives.

import std/[json]

type
  SpanKind* = enum
    skRun
    skStep
    skModel
    skTool
    skEmbedding

  SpanStatus* = enum
    ssOk
    ssError
    ssCancelled

  TraceSpan* = ref object
    ## Completed span emitted to a TraceSink. Content is never included unless
    ## an application explicitly adds it to attributes.
    traceId*: string
    spanId*: string
    parentSpanId*: string
    name*: string
    kind*: SpanKind
    startNs*: int64
    endNs*: int64
    status*: SpanStatus
    attributes*: JsonNode
    error*: string

  TraceSink* = proc (span: TraceSpan) {.closure.}

proc durationMs*(span: TraceSpan): int =
  if span.isNil or span.endNs <= span.startNs: return 0
  int((span.endNs - span.startNs) div 1_000_000)
