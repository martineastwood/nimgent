## Compile-time derivation of JSON Schema from Nim types.

import std/[json, macros, strutils]
import nimgent/jsonschema_validate

## Optional field annotations understood by `jsonSchema`. They are declared
## as pragmas so they can be used directly on object fields without generating
## runtime code.
template jsonDescription*(value: static[string]) {.pragma.}
template jsonMinimum*(value: static[int]) {.pragma.}
template jsonMaximum*(value: static[int]) {.pragma.}
template jsonMinLength*(value: static[int]) {.pragma.}
template jsonMaxLength*(value: static[int]) {.pragma.}
template jsonMinItems*(value: static[int]) {.pragma.}
template jsonMaxItems*(value: static[int]) {.pragma.}
template jsonPattern*(value: static[string]) {.pragma.}
template jsonOptional*() {.pragma.}

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

type FieldMeta = object
  optional: bool
  constraints: JsonNode

type GenericBinding = object
  name: string
  value: NimNode

proc schemaFromType(t: NimNode, bindings: seq[GenericBinding]): JsonNode
proc schemaFromType(t: NimNode): JsonNode = schemaFromType(t, @[])

proc genericParamName(n: NimNode): string =
  var param = n
  if param.kind == nnkIdentDefs and param.len > 0:
    param = param[0]
  if param.kind == nnkPragmaExpr and param.len > 0:
    param = param[0]
  if param.kind == nnkPostfix and param.len > 1:
    param = param[1]
  if param.kind in {nnkSym, nnkIdent}:
    return param.strVal
  typeLeafName(param)

proc genericParamNames(params: NimNode): seq[string] =
  for param in params:
    if param.kind == nnkIdentDefs:
      for i in 0 ..< param.len - 2:
        result.add genericParamName(param[i])
    else:
      result.add genericParamName(param)

proc substituteType(n: NimNode, bindings: seq[GenericBinding]): NimNode =
  if n.isNil: return n
  if n.kind in {nnkSym, nnkIdent}:
    for binding in bindings:
      if n.strVal == binding.name:
        return binding.value
  result = copyNimNode(n)
  for child in n:
    result.add substituteType(child, bindings)

proc pragmaNumber(n: NimNode): JsonNode =
  case n.kind
  of nnkIntLit, nnkUIntLit:
    %n.intVal
  of nnkFloatLit:
    %n.floatVal
  else:
    nil

proc fieldMeta(n: NimNode): FieldMeta =
  result.constraints = newJObject()
  if n.kind != nnkPragmaExpr or n.len < 2: return
  let pragmas = n[1]
  for pragma in pragmas:
    var name = ""
    var arg: NimNode = nil
    if pragma.kind == nnkCall:
      name = typeLeafName(pragma[0])
      if pragma.len > 1: arg = pragma[1]
    else:
      name = typeLeafName(pragma)
    case name
    of "jsonOptional":
      result.optional = true
    of "jsonDescription", "jsonPattern":
      if not arg.isNil and arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        let key = if name == "jsonDescription": "description" else: "pattern"
        result.constraints[key] = %arg.strVal
    of "jsonMinimum", "jsonMaximum", "jsonMinLength", "jsonMaxLength",
       "jsonMinItems", "jsonMaxItems":
      if not arg.isNil:
        let value = pragmaNumber(arg)
        if not value.isNil:
          let key = case name
            of "jsonMinimum": "minimum"
            of "jsonMaximum": "maximum"
            of "jsonMinLength": "minLength"
            of "jsonMaxLength": "maxLength"
            of "jsonMinItems": "minItems"
            else: "maxItems"
          result.constraints[key] = value

proc mergeObjectSchema(dest, base: JsonNode) =
  if base.isNil or base.kind != JObject: return
  if "properties" in base and base["properties"].kind == JObject:
    for key, value in base["properties"]:
      dest["properties"][key] = copy(value)
  if "required" in base and base["required"].kind == JArray:
    for key in base["required"]:
      var present = false
      for existing in dest["required"]:
        if jsonEqual(existing, key):
          present = true
          break
      if not present:
        dest["required"].add copy(key)

proc addRequired(schema: JsonNode, key: string) =
  for existing in schema["required"]:
    if existing.kind == JString and existing.getStr == key:
      return
  schema["required"].add %key

proc addRecordFields(schema: JsonNode, rec: NimNode, requireFields = true,
                     bindings: seq[GenericBinding] = @[])

proc addField(schema: JsonNode, identDef: NimNode, requireField = true,
              bindings: seq[GenericBinding] = @[]) =
  if identDef.kind != nnkIdentDefs or identDef.len < 3: return
  let ftype = identDef[^2]
  for i in 0 ..< identDef.len - 2:
    let original = identDef[i]
    var fname = original
    if fname.kind == nnkPragmaExpr: fname = fname[0]
    if fname.kind == nnkPostfix: fname = fname[1]
    let key = $fname
    var fieldSchema = schemaFromType(substituteType(ftype, bindings))
    let meta = fieldMeta(original)
    for constraint, value in meta.constraints:
      fieldSchema[constraint] = value
    schema["properties"][key] = fieldSchema
    if requireField and not meta.optional:
      addRequired(schema, key)

proc branchLabel(n: NimNode): JsonNode =
  case n.kind
  of nnkIntLit, nnkUIntLit:
    %n.intVal
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    %n.strVal
  else:
    %($n)

proc addRecordFields(schema: JsonNode, rec: NimNode, requireFields = true,
                     bindings: seq[GenericBinding] = @[]) =
  case rec.kind
  of nnkRecList:
    for field in rec:
      if field.kind == nnkIdentDefs:
        addField(schema, field, requireFields, bindings)
      elif field.kind == nnkRecCase:
        addRecordFields(schema, field, requireFields, bindings)
  of nnkRecCase:
    var discriminator = ""
    if rec.len > 0 and rec[0].kind == nnkIdentDefs:
      addField(schema, rec[0], requireFields, bindings)
      if rec[0].len >= 3:
        var discriminatorNode = rec[0][0]
        if discriminatorNode.kind == nnkPragmaExpr:
          discriminatorNode = discriminatorNode[0]
        if discriminatorNode.kind == nnkPostfix:
          discriminatorNode = discriminatorNode[1]
        discriminator = $discriminatorNode
    let sharedProperties = copy(schema["properties"])
    let sharedRequired = copy(schema["required"])
    var explicitLabels = newJArray()
    var variants = newJArray()
    for i in 1 ..< rec.len:
      let branch = rec[i]
      if branch.kind notin {nnkOfBranch, nnkElifBranch, nnkElse} or
          branch.len == 0:
        continue
      let branchRec = branch[^1]
      ## Keep branch fields in the parent property set, but make their
      ## conditional requirement explicit in a oneOf branch.
      addRecordFields(schema, branchRec, false, bindings)
      if discriminator.len == 0:
        continue
      var variant = %*{
        "type": "object",
        "additionalProperties": false,
        "properties": copy(sharedProperties),
        "required": copy(sharedRequired)
      }
      if branch.kind != nnkElse:
        var labels = newJArray()
        for labelIndex in 0 ..< branch.len - 1:
          let label = branchLabel(branch[labelIndex])
          labels.add copy(label)
          explicitLabels.add copy(label)
        if labels.len == 1:
          variant["properties"][discriminator] = %*{"const": labels[0]}
        else:
          variant["properties"][discriminator] = %*{"enum": labels}
        addRequired(variant, discriminator)
      else:
        ## Nim's `else` means every discriminator value not covered by an
        ## earlier branch. Preserve the parent enum while excluding labels
        ## already handled by explicit branches.
        let parentDiscriminator = variant["properties"].getOrDefault(discriminator)
        if not parentDiscriminator.isNil and parentDiscriminator.kind == JObject and
            "enum" in parentDiscriminator and parentDiscriminator["enum"].kind == JArray:
          var remaining = newJArray()
          for candidate in parentDiscriminator["enum"]:
            var explicit = false
            for label in explicitLabels:
              if jsonEqual(candidate, label):
                explicit = true
                break
            if not explicit:
              remaining.add copy(candidate)
          if remaining.len > 0:
            variant["properties"][discriminator] = %*{"enum": remaining}
          else:
            variant["not"] = %*{}
      addRecordFields(variant, branchRec, true, bindings)
      if variant["required"].len == 0:
        variant.delete("required")
      variants.add variant
    if requireFields and variants.len > 0:
      schema["oneOf"] = variants
  of nnkOfBranch, nnkElifBranch, nnkElse:
    if rec.len > 0:
      addRecordFields(schema, rec[^1], requireFields, bindings)
  else:
    discard

proc unwrapType(t: NimNode): NimNode =
  result = t
  var impl = getTypeImpl(result)
  if impl.kind == nnkRefTy:
    result = impl[0]
    impl = getTypeImpl(result)
  if impl.kind == nnkDistinctTy:
    result = impl[0]

proc schemaFromType(t: NimNode, bindings: seq[GenericBinding]): JsonNode =
  var inst = getTypeInst(t)
  if inst.kind == nnkBracketExpr and inst.len >= 2 and
      typeLeafName(inst[0]) == "typeDesc":
    inst = inst[1]
  if inst.kind == nnkBracketExpr:
    let ctor = typeLeafName(inst[0])
    if ctor in ["seq", "openArray"]:
      return %*{"type": "array", "items": schemaFromType(inst[1])}
    if ctor == "array" and inst.len >= 3:
      result = %*{"type": "array", "items": schemaFromType(inst[^1])}
      let bound = inst[1]
      if bound.kind == nnkIntLit:
        result["minItems"] = %bound.intVal
        result["maxItems"] = %bound.intVal
      elif bound.kind == nnkInfix and $bound[0] == ".." and bound.len >= 3 and
          bound[1].kind == nnkIntLit and bound[2].kind == nnkIntLit:
        let count = bound[2].intVal - bound[1].intVal + 1
        result["minItems"] = %count
        result["maxItems"] = %count
      return
    if ctor in ["set", "HashSet", "OrderedSet"] and inst.len >= 2:
      return %*{"type": "array", "items": schemaFromType(inst[1]),
        "uniqueItems": true}
    if ctor in ["Table", "OrderedTable", "CountTable"] and inst.len >= 3:
      return %*{"type": "object", "additionalProperties": schemaFromType(inst[2])}
    if ctor == "Option":
      result = schemaFromType(inst[1])
      var types = newJArray()
      if "type" in result and result["type"].kind == JString:
        types.add result["type"]
        types.add %"null"
        result["type"] = types
      return
  let coreType = if inst.kind == nnkBracketExpr: inst[0] else: inst
  let core = unwrapType(coreType)
  let impl = getTypeImpl(core)
  if impl.kind == nnkBracketExpr and impl.len >= 3:
    let ctor = typeLeafName(impl[0])
    if ctor == "array":
      result = %*{"type": "array", "items": schemaFromType(impl[^1])}
      let bound = impl[1]
      if bound.kind == nnkInfix and $bound[0] == ".." and bound.len >= 3 and
          bound[1].kind == nnkIntLit and bound[2].kind == nnkIntLit:
        let count = bound[2].intVal - bound[1].intVal + 1
        result["minItems"] = %count
        result["maxItems"] = %count
      return
  case impl.kind
  of nnkObjectTy:
    result = %*{
      "type": "object",
      "additionalProperties": false,
      "properties": newJObject(),
      "required": newJArray()
    }
    var source = impl
    var activeBindings = bindings
    if activeBindings.len == 0 and inst.kind == nnkBracketExpr and inst.len > 1:
      try:
        let genericDef = getImpl(inst[0])
        if genericDef.kind == nnkTypeDef and genericDef.len > 1 and
            genericDef[1].kind == nnkGenericParams:
          let params = genericDef[1]
          let names = genericParamNames(params)
          for i in 0 ..< min(names.len, inst.len - 1):
            activeBindings.add GenericBinding(name: names[i], value: inst[i + 1])
      except CatchableError:
        discard
    try:
      let definition = getImpl(core)
      if definition.kind == nnkTypeDef and definition.len > 0:
        source = definition[^1]
    except CatchableError:
      discard
    if source.kind == nnkObjectTy and source.len > 1 and
        source[1].kind == nnkOfInherit and source[1].len > 0:
      let base = source[1][0]
      let baseName = if base.kind == nnkBracketExpr: typeLeafName(base[0])
                     else: typeLeafName(base)
      if baseName notin ["RootObj", "RootRef"]:
        var baseType = base
        var baseBindings: seq[GenericBinding] = activeBindings
        if base.kind == nnkBracketExpr and base.len > 1:
          baseType = base[0]
          try:
            let genericDef = getImpl(base[0])
            if genericDef.kind == nnkTypeDef and genericDef.len > 1 and
                genericDef[1].kind == nnkGenericParams:
              let params = genericDef[1]
              let names = genericParamNames(params)
              baseBindings = @[]
              for i in 0 ..< min(names.len, base.len - 1):
                baseBindings.add GenericBinding(name: names[i],
                  value: substituteType(base[i + 1], activeBindings))
          except CatchableError:
            discard
        mergeObjectSchema(result, schemaFromType(baseType, baseBindings))
    let rec = if source.kind == nnkObjectTy and source.len > 2: source[2] else: impl[2]
    if rec.kind != nnkEmpty:
      addRecordFields(result, rec, true, activeBindings)
    if result["required"].len == 0:
      result.delete("required")
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
  ## JSON Schema for Nim objects, variants, containers, generics, enums, and
  ## primitives. Field pragmas add constraints or make a property optional.
  ## Option fields stay in `required` as `[T, null]` (OpenAI strict).
  let impl = T.getType
  let typeValue = if impl.kind == nnkBracketExpr and impl.len >= 2:
                    impl[1]
                  else:
                    T
  let t = if T.kind == nnkBracketExpr and typeValue.kind in {nnkSym, nnkIdent}:
            T
          else:
            typeValue
  let s = $schemaFromType(t)
  result = newCall(bindSym"parseJson", newLit(s))
