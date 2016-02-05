fs = require("fs")

replaceBlanksWithNulls = (v) ->
  if Array.isArray(v)
    v.map (b) -> replaceBlanksWithNulls(b)
  else if typeof(v) == 'object'
    res = {}
    for a, b of v
      res[a] = replaceBlanksWithNulls(b)
    res
  else if typeof(v) == 'string' && v.trim().length <= 0
    null
  else
    v

getMeta = (hl7version) ->
  JSON.parse(fs.readFileSync(__dirname + "/../meta/v#{hl7version.replace('.', '_')}.json"))

deprefixGroupName = (name) ->
  name.replace(/^..._.\d\d_/, '')

coerce = (value, typeId) ->
  # TODO
  value

_structurize = (meta, struct, message, segIdx) ->
  if struct[0] != 'sequence'
    throw new Error("struct[0] != sequence, don't know what to do :/")

  result = {}
  structIdx = 0

  while true
    # Expected segment name and cardinality
    expSegName = struct[1][structIdx][0]
    [expSegMin, expSegMax] = struct[1][structIdx][1]

    # Trying to collect expSegMax occurences of expected segment
    # within loop above. This loop won't collect multiple segments if
    # expSegMax == 1
    collectedSegments = []
    thisSegName = null

    while true
      thisSegName = message[segIdx][0]

      if collectedSegments.length == expSegMax && expSegMax == 1
        # we wanted just one segment, and we got it
        break

      # check if expected segment is a group
      if meta.GROUPS[expSegName]
        # if it's a group, we go to recursion
        [subResult, newSegIdx] = _structurize(meta, meta.GROUPS[expSegName], message, segIdx)

        if subResult != null
          segIdx = newSegIdx
          collectedSegments.push(subResult)
        else
          break
      else
        # it's not a group, it's a regular segment
        if thisSegName == expSegName
          collectedSegments.push message[segIdx]
          segIdx = segIdx + 1
        else
          # no segments with expected name left,
          # we'll figure out if it's an error or not
          # right after this loop
          break

    # now we have collectedSegments, and we're going to check
    # expected cardinality
    if collectedSegments.length == 0
      # no collected segments at all, check if expected segment
      # is optional
      if expSegMin == 1
        console.log "Expected segment #{expSegName}, got #{thisSegName} at segment index #{segIdx}"
        return [null, segIdx]
    else
      # if max cardinality = -1 then push collectedSegments as array
      if expSegMax == 1
        result[deprefixGroupName(expSegName)] = collectedSegments[0]
      else
        result[deprefixGroupName(expSegName)] = collectedSegments

    structIdx += 1

    # if we reached the end of struct then break
    if structIdx >= struct[1].length
      break

  # if we didn't collected anything, we return null instead of
  # empty object
  if Object.keys(result).length == 0
    return [null, segIdx]
  else
    return [result, segIdx]

structurize = (meta, message, messageType) ->
  [result, foo] = _structurize(meta, meta.MESSAGES[messageType.join("_")], message, 0)

  result

parse = (msg) ->
  if msg.substr(0, 3) != "MSH"
    throw new Error("Message should start with MSH segment")

  if msg.length < 8
    throw new Error("Message is too short (MSH truncated)")

  separators =
    segment: "\r" # TODO: should be \r
    field: msg[3]
    component: msg[4]
    subcomponent: msg[7]
    repetition: msg[5]
    escape: msg[6]

  segments = msg.split(separators.segment).map (s) -> s.trim()
  segments = segments.filter (s) -> s.length > 0
  msh = segments[0].split(separators.field)

  messageType = msh[8].split(separators.component)
  hl7version = msh[11]
  meta = getMeta(hl7version)

  message = parseSegments(segments, meta, separators)
  message = structurize(meta, message, messageType)

  message

parseSegments = (segments, meta, separators) ->
  result = []

  for segment in segments
    rawFields = segment.split(separators.field)
    segmentName = rawFields.shift()

    result.push parseFields(rawFields, segmentName, meta, separators)

  result

parseFields = (fields, segmentName, meta, separators) ->
  segmentMeta = meta.SEGMENTS[segmentName]
  result = {"0": segmentName}

  if segmentMeta[0] != "sequence"
    throw new Error("Bang! Unknown case: #{segmentMeta[0]}")

  for fieldValue, fieldIndex in fields
    fieldMeta = segmentMeta[1][fieldIndex]
    otherFieldMeta = meta.FIELDS[fieldMeta[0]]
    fieldSymbolicName = otherFieldMeta[2]

    if fieldMeta
      fieldId = fieldMeta[0]
      [fieldMin, fieldMax] = fieldMeta[1]

      if fieldMin == 1 && (!fieldValue || fieldValue == '')
        throw new Error("Missing value for required field: #{fieldId}")

      splitRegexp = new RegExp("(?!\\#{separators.escape})#{separators.repetition}")
      fieldValues = fieldValue.split(splitRegexp).map (v) ->
        parseComponents(v, fieldId, meta, separators)

      if fieldMax == 1
        result[fieldIndex + 1] = fieldValues[0]
      else if fieldMax == -1
        result[fieldIndex + 1] = fieldValues
      else
        throw new Error("Bang! Unknown case for fieldMax: #{fieldMax}")
    else
      result[fieldIndex + 1] = fieldValue

    if segmentName == 'MSH'
      result[fieldSymbolicName] = result[fieldIndex]
    else
      result[fieldSymbolicName] = result[fieldIndex + 1]

  replaceBlanksWithNulls(result)

parseComponents = (value, fieldId, meta, separators) ->
  fieldMeta = meta.FIELDS[fieldId]

  if fieldMeta[0] != 'leaf'
    throw new Error("Bang! Unknown case for fieldMeta[0]: #{fieldMeta[0]}")

  fieldType = fieldMeta[1]
  typeMeta = meta.DATATYPES[fieldType]

  if typeMeta
    # it's a complex type
    splitRegexp = new RegExp("(?!\\#{separators.escape})\\#{separators.component}")
    fieldMeta = "^"

    [fieldMeta].concat value.split(splitRegexp).map (c, index) ->
      componentId = typeMeta[1][index][0]
      [componentMin, componentMax] = typeMeta[1][index][1]

      if componentMin == 1 && (!c || c == '')
        throw new Error("Missing value for required component #{componentId}")

      if componentMax == -1
        throw new Error("Bang! Unlimited cardinality for component #{componentId}")

      parseSubComponents(c, componentId, meta, separators)
  else
    coerce(value, fieldType)

parseSubComponents = (v, scId, meta, separators) ->
  scMeta = meta.DATATYPES[scId]

  if scMeta
    if scMeta[0] != 'leaf'
      throw new Error("Bang! Unknown case for scMeta[0]: #{scMeta[0]}")

    coerce(v, scMeta[1])
  else
    v

module.exports =
  grok: parse
