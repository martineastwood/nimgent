## Provider-neutral tracing primitives.

import std/[json]

type
  SpanKind* = enum
    ## Operation category recorded in a trace span.
    skRun
    skStep
    skModel
    skTool
    skEmbedding

  SpanStatus* = enum
    ## Completion status recorded in a trace span.
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
    ## Callback that receives each completed span.

proc durationMs*(span: TraceSpan): int =
  ## Return a completed span's duration in milliseconds.
  if span.isNil or span.endNs <= span.startNs: return 0
  int((span.endNs - span.startNs) div 1_000_000)
