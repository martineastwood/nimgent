## JSON Schema derivation, extraction, and a small validator.
##
## ponytail: draft-07 subset used by generateObject — type, properties, required,
## items, enum, const, min/max, minLength/maxLength, minItems/maxItems,
## additionalProperties, anyOf/oneOf/allOf. No $ref; say so if one appears.

import std/[json, macros, math, strutils]

proc skipJsonString(s: string, i: var int) =
  inc i
  while i < s.len:
    if s[i] == '\\':
      inc i, 2
    elif s[i] == '"':
      inc i
      return
    else:
      inc i

proc sliceJsonValue(s: string): string =
  var start = -1
  for i, c in s:
    if c in {'{', '['}:
      start = i
      break
  if start < 0: return ""
  var depth = 0
  var i = start
  while i < s.len:
    let c = s[i]
    if c == '"':
      skipJsonString(s, i)
      continue
    if c in {'{', '['}: inc depth
    elif c in {'}', ']'}:
      dec depth
      if depth == 0:
        return s[start .. i]
    inc i
  ""

proc stripFence(s: string): string =
  result = s.strip
  if not result.startsWith("```"): return
  let nl = result.find('\n')
  if nl < 0: return
  result = result[nl + 1 .. ^1]
  if result.endsWith("```"):
    result = result[0 .. ^4].strip

proc extractJson*(s: string): JsonNode =
  ## First JSON object or array in `s`. Understands ``` fences and leading prose.
  let fenced = stripFence(s)
  if fenced.len == 0: return nil
  try:
    let n = parseJson(fenced)
    if n.kind in {JObject, JArray}: return n
  except CatchableError:
    discard
  let slice = sliceJsonValue(fenced)
  if slice.len == 0: return nil
  try:
    let n = parseJson(slice)
    if n.kind in {JObject, JArray}: return n
  except CatchableError:
    discard
  result = nil

type
  PartialParse* = enum
    ppUndefined
    ppSuccess
    ppRepaired
    ppFailed

  FixState = enum
    fsRoot
    fsFinish
    fsString
    fsStringEscape
    fsStringUnicode
    fsLiteral
    fsNumber
    fsObjectStart
    fsObjectKey
    fsObjectAfterKey
    fsObjectBeforeValue
    fsObjectAfterValue
    fsObjectAfterComma
    fsArrayStart
    fsArrayAfterValue
    fsArrayAfterComma

proc fixJson*(input: string): string =
  ## Close a prefix of JSON so `parseJson` can read it. Port of AI SDK `fixJson`.
  var stack: seq[FixState] = @[fsRoot]
  var lastValid = -1
  var literalStart = -1
  var unicodeDigits = 0

  proc afterObject(c: char, i: int) =
    case c
    of ',':
      discard stack.pop()
      stack.add fsObjectAfterComma
    of '}':
      lastValid = i
      discard stack.pop()
    else: discard

  proc afterArray(c: char, i: int) =
    case c
    of ',':
      discard stack.pop()
      stack.add fsArrayAfterComma
    of ']':
      lastValid = i
      discard stack.pop()
    else: discard

  proc valueStart(c: char, i: int, swap: FixState) =
    case c
    of '"':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsString
    of 'f', 't', 'n':
      lastValid = i
      literalStart = i
      discard stack.pop()
      stack.add swap
      stack.add fsLiteral
    of '-':
      discard stack.pop()
      stack.add swap
      stack.add fsNumber
    of '0'..'9':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsNumber
    of '{':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsObjectStart
    of '[':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsArrayStart
    else: discard

  for i, c in input:
    case stack[^1]
    of fsRoot:
      valueStart(c, i, fsFinish)
    of fsObjectStart:
      case c
      of '"':
        discard stack.pop()
        stack.add fsObjectKey
      of '}':
        lastValid = i
        discard stack.pop()
      else: discard
    of fsObjectAfterComma:
      if c == '"':
        discard stack.pop()
        stack.add fsObjectKey
    of fsObjectKey:
      if c == '"':
        discard stack.pop()
        stack.add fsObjectAfterKey
    of fsObjectAfterKey:
      if c == ':':
        discard stack.pop()
        stack.add fsObjectBeforeValue
    of fsObjectBeforeValue:
      valueStart(c, i, fsObjectAfterValue)
    of fsObjectAfterValue:
      afterObject(c, i)
    of fsString:
      case c
      of '"':
        discard stack.pop()
        lastValid = i
      of '\\':
        stack.add fsStringEscape
      else:
        lastValid = i
    of fsArrayStart:
      if c == ']':
        lastValid = i
        discard stack.pop()
      else:
        lastValid = i
        valueStart(c, i, fsArrayAfterValue)
    of fsArrayAfterValue:
      case c
      of ',':
        discard stack.pop()
        stack.add fsArrayAfterComma
      of ']':
        lastValid = i
        discard stack.pop()
      else:
        lastValid = i
    of fsArrayAfterComma:
      valueStart(c, i, fsArrayAfterValue)
    of fsStringEscape:
      discard stack.pop()
      if c == 'u':
        unicodeDigits = 0
        stack.add fsStringUnicode
      else:
        lastValid = i
    of fsStringUnicode:
      if c in HexDigits:
        inc unicodeDigits
        if unicodeDigits == 4:
          discard stack.pop()
          lastValid = i
    of fsNumber:
      case c
      of '0'..'9':
        lastValid = i
      of 'e', 'E', '-', '.':
        discard
      of ',':
        discard stack.pop()
        if stack[^1] == fsArrayAfterValue: afterArray(c, i)
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
      of '}':
        discard stack.pop()
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
      of ']':
        discard stack.pop()
        if stack[^1] == fsArrayAfterValue: afterArray(c, i)
      else:
        discard stack.pop()
    of fsLiteral:
      let partial = input[literalStart .. i]
      if not "false".startsWith(partial) and not "true".startsWith(partial) and
          not "null".startsWith(partial):
        discard stack.pop()
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
        elif stack[^1] == fsArrayAfterValue: afterArray(c, i)
      else:
        lastValid = i
    of fsFinish:
      discard

  result = if lastValid >= 0: input[0 .. lastValid] else: ""
  for i in countdown(stack.high, 0):
    case stack[i]
    of fsString:
      result.add '"'
    of fsObjectKey, fsObjectAfterKey, fsObjectAfterComma, fsObjectStart,
        fsObjectBeforeValue, fsObjectAfterValue:
      result.add '}'
    of fsArrayStart, fsArrayAfterComma, fsArrayAfterValue:
      result.add ']'
    of fsLiteral:
      let partial = input[literalStart .. ^1]
      if "true".startsWith(partial):
        result.add "true"[partial.len .. ^1]
      elif "false".startsWith(partial):
        result.add "false"[partial.len .. ^1]
      elif "null".startsWith(partial):
        result.add "null"[partial.len .. ^1]
    else: discard

proc jsonLead(s: string): string =
  ## From the first `{` or `[` so fences and prose do not break `fixJson`.
  for i, c in s:
    if c in {'{', '['}: return s[i .. ^1]
  ""

proc parsePartialJson*(s: string): tuple[value: JsonNode, state: PartialParse] =
  ## Parse complete JSON, or a repaired prefix (AI SDK `parsePartialJson`).
  if s.len == 0:
    return (nil, ppUndefined)
  let src = jsonLead(stripFence(s))
  if src.len == 0:
    return (nil, ppUndefined)
  try:
    return (parseJson(src), ppSuccess)
  except CatchableError:
    discard
  try:
    return (parseJson(fixJson(src)), ppRepaired)
  except CatchableError:
    discard
  (nil, ppFailed)

proc pathField(path, key: string): string =
  path & "." & key

proc pathIndex(path: string, i: int): string =
  path & "[" & $i & "]"

proc typeNames(schema: JsonNode): seq[string] =
  if schema.isNil or schema.kind != JObject or "type" notin schema:
    return
  let t = schema["type"]
  if t.kind == JString:
    result.add t.getStr
  elif t.kind == JArray:
    for x in t:
      if x.kind == JString: result.add x.getStr

proc jsonKindName(n: JsonNode): string =
  case n.kind
  of JNull: "null"
  of JBool: "boolean"
  of JInt: "integer"
  of JFloat: "number"
  of JString: "string"
  of JObject: "object"
  of JArray: "array"

proc isWholeFloat(n: JsonNode): bool =
  n.kind == JFloat and n.getFloat == n.getFloat.trunc and
    n.getFloat >= int64.low.float and n.getFloat <= int64.high.float

proc matchesType(value: JsonNode, names: openArray[string]): bool =
  if names.len == 0: return true
  let got = jsonKindName(value)
  for n in names:
    if n == got: return true
    if n == "number" and value.kind == JInt: return true
    if n == "integer" and isWholeFloat(value): return true
  false

proc jsonEqual*(a, b: JsonNode): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.kind != b.kind:
    if a.kind == JInt and isWholeFloat(b): return a.getInt.float == b.getFloat
    if b.kind == JInt and isWholeFloat(a): return b.getInt.float == a.getFloat
    return false
  case a.kind
  of JNull: true
  of JBool: a.getBool == b.getBool
  of JInt: a.getInt == b.getInt
  of JFloat: a.getFloat == b.getFloat
  of JString: a.getStr == b.getStr
  of JArray:
    if a.len != b.len: return false
    for i in 0 ..< a.len:
      if not jsonEqual(a[i], b[i]): return false
    true
  of JObject:
    if a.len != b.len: return false
    for k, v in a:
      if k notin b or not jsonEqual(v, b[k]): return false
    true

proc validateSchema*(value, schema: JsonNode, path = "$"): seq[string] =
  ## Empty means `value` satisfies `schema`.
  if schema.isNil or schema.kind != JObject:
    return
  if "$ref" in schema:
    return @[path & ": $ref is not supported"]
  if value.isNil:
    return @[path & ": missing value"]
  if "const" in schema and not jsonEqual(value, schema["const"]):
    result.add path & ": expected " & $schema["const"]
  if "enum" in schema and schema["enum"].kind == JArray:
    var found = false
    for item in schema["enum"]:
      if jsonEqual(value, item):
        found = true
        break
    if not found:
      result.add path & ": expected one of " & $schema["enum"]
  let types = typeNames(schema)
  if types.len > 0 and not matchesType(value, types):
    result.add path & ": expected " & types.join("|") & ", got " & jsonKindName(value)
    return
  if "allOf" in schema:
    for sub in schema["allOf"]:
      result.add validateSchema(value, sub, path)
  if "anyOf" in schema and schema["anyOf"].kind == JArray:
    var ok = false
    for sub in schema["anyOf"]:
      if validateSchema(value, sub, path).len == 0:
        ok = true
        break
    if not ok:
      result.add path & ": matched none of anyOf"
  if "oneOf" in schema and schema["oneOf"].kind == JArray:
    var hits = 0
    for sub in schema["oneOf"]:
      if validateSchema(value, sub, path).len == 0: inc hits
    if hits != 1:
      result.add path & ": expected exactly one of oneOf, got " & $hits
  if value.kind == JString:
    let n = value.getStr.len
    if "minLength" in schema and n < schema["minLength"].getInt:
      result.add path & ": shorter than minLength " & $schema["minLength"].getInt
    if "maxLength" in schema and n > schema["maxLength"].getInt:
      result.add path & ": longer than maxLength " & $schema["maxLength"].getInt
  if value.kind in {JInt, JFloat}:
    let x = if value.kind == JInt: value.getInt.float else: value.getFloat
    if "minimum" in schema and x < schema["minimum"].getFloat:
      result.add path & ": below minimum " & $schema["minimum"]
    if "maximum" in schema and x > schema["maximum"].getFloat:
      result.add path & ": above maximum " & $schema["maximum"]
  if value.kind == JArray:
    if "minItems" in schema and value.len < schema["minItems"].getInt:
      result.add path & ": fewer than minItems " & $schema["minItems"].getInt
    if "maxItems" in schema and value.len > schema["maxItems"].getInt:
      result.add path & ": more than maxItems " & $schema["maxItems"].getInt
    if "items" in schema:
      for i in 0 ..< value.len:
        result.add validateSchema(value[i], schema["items"], pathIndex(path, i))
  if value.kind == JObject:
    var props: JsonNode = nil
    if "properties" in schema: props = schema["properties"]
    if "required" in schema:
      for req in schema["required"]:
        if req.kind == JString and req.getStr notin value:
          result.add pathField(path, req.getStr) & ": required"
    if not props.isNil and props.kind == JObject:
      for k, v in value:
        if k in props:
          result.add validateSchema(v, props[k], pathField(path, k))
        elif "additionalProperties" in schema:
          let extra = schema["additionalProperties"]
          if extra.kind == JBool and not extra.getBool:
            result.add pathField(path, k) & ": unexpected property"
          elif extra.kind == JObject:
            result.add validateSchema(v, extra, pathField(path, k))

proc prepareWireSchema*(schema: JsonNode): JsonNode =
  ## Copy. Objects without additionalProperties get false (OpenAI/Anthropic strict).
  proc walk(n: JsonNode) =
    if n.isNil or n.kind != JObject: return
    if n.getOrDefault("type").getStr == "object" or "properties" in n:
      if "additionalProperties" notin n:
        n["additionalProperties"] = %false
    if "properties" in n and n["properties"].kind == JObject:
      for _, v in n["properties"]: walk(v)
    if "items" in n: walk(n["items"])
    for key in ["anyOf", "oneOf", "allOf"]:
      if key in n and n[key].kind == JArray:
        for v in n[key]: walk(v)
  result = copy(schema)
  walk(result)

proc schemaName*(s: string): string =
  ## OpenAI structured-output names: `[a-zA-Z0-9_-]+`.
  if s.len == 0: return "object"
  for c in s:
    if c.isAlphaNumeric or c in {'_', '-'}: result.add c
    else: result.add '_'
  if result[0] notin {'A'..'Z', 'a'..'z'}:
    result = "n" & result

proc typeLeafName(n: NimNode): string =
  case n.kind
  of nnkDotExpr: $n[^1]
  of nnkSym, nnkIdent: n.strVal
  else: $n

proc schemaFromType(t: NimNode): JsonNode

proc unwrapType(t: NimNode): NimNode =
  result = t
  var impl = getTypeImpl(result)
  if impl.kind == nnkRefTy:
    result = impl[0]
    impl = getTypeImpl(result)
  if impl.kind == nnkDistinctTy:
    result = impl[0]

proc schemaFromType(t: NimNode): JsonNode =
  let inst = getTypeInst(t)
  if inst.kind == nnkBracketExpr:
    let ctor = typeLeafName(inst[0])
    if ctor in ["seq", "openArray"]:
      return %*{"type": "array", "items": schemaFromType(inst[1])}
    if ctor == "Option":
      result = schemaFromType(inst[1])
      var types = newJArray()
      if "type" in result and result["type"].kind == JString:
        types.add result["type"]
        types.add %"null"
        result["type"] = types
      return
  let core = unwrapType(t)
  let impl = getTypeImpl(core)
  case impl.kind
  of nnkObjectTy:
    result = %*{
      "type": "object",
      "additionalProperties": false,
      "properties": newJObject(),
      "required": newJArray()
    }
    var rec = impl[2]
    if rec.kind == nnkEmpty: return
    if rec.kind == nnkRecList:
      for identDef in rec:
        let ftype = identDef[^2]
        for i in 0 ..< identDef.len - 2:
          var fname = identDef[i]
          if fname.kind == nnkPragmaExpr: fname = fname[0]
          if fname.kind == nnkPostfix: fname = fname[1]
          let key = $fname
          result["properties"][key] = schemaFromType(ftype)
          result["required"].add %key
  of nnkEnumTy:
    var vals = newJArray()
    for i in 1 ..< impl.len:
      let f = impl[i]
      case f.kind
      of nnkEnumFieldDef:
        if f[1].kind in {nnkStrLit, nnkRStrLit}:
          vals.add %f[1].strVal
        else:
          vals.add %($f[0])
      of nnkSym: vals.add %($f)
      else: discard
    result = %*{"type": "string", "enum": vals}
  else:
    let name = typeLeafName(getTypeInst(core))
    case name
    of "string", "cstring": result = %*{"type": "string"}
    of "bool": result = %*{"type": "boolean"}
    of "int", "int8", "int16", "int32", "int64",
       "uint", "uint8", "uint16", "uint32", "uint64", "byte", "BiggestInt":
      result = %*{"type": "integer"}
    of "float", "float32", "float64", "BiggestFloat":
      result = %*{"type": "number"}
    else:
      error("jsonSchema: unsupported type " & name, t)

macro jsonSchema*(T: typedesc): JsonNode =
  ## JSON Schema for a Nim type (objects, seq, Option, enums, primitives).
  ## Option fields stay in `required` as `[T, null]` (OpenAI strict).
  let impl = T.getType
  let t = if impl.kind == nnkBracketExpr and impl.len >= 2: impl[1] else: T
  let s = $schemaFromType(t)
  result = newCall(bindSym"parseJson", newLit(s))
