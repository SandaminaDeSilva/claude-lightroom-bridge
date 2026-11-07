-- Minimal JSON encoder/decoder for Lightroom Classic (Lua 5.1).
-- Written for the Claude Editor Bridge plugin.

local json = {}

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local escapeMap = {
  ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    return escapeMap[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return 'null'
  end
  if math.floor(n) == n and math.abs(n) < 1e15 then
    return string.format('%d', n)
  end
  return string.format('%.14g', n)
end

local encodeValue

local function encodeTable(t, seen)
  if seen[t] then error('json: cannot encode circular table') end
  seen[t] = true
  local out = {}
  local arr, n = isArray(t)
  if arr then
    for i = 1, n do out[i] = encodeValue(t[i], seen) end
    seen[t] = nil
    return '[' .. table.concat(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    if v == nil then v = t[tonumber(k)] end
    local vt = type(v)
    if vt ~= 'function' and vt ~= 'userdata' and vt ~= 'thread' then
      out[#out + 1] = encodeString(k) .. ':' .. encodeValue(v, seen)
    end
  end
  seen[t] = nil
  return '{' .. table.concat(out, ',') .. '}'
end

encodeValue = function(v, seen)
  local vt = type(v)
  if v == nil or v == json.null then return 'null'
  elseif vt == 'boolean' then return v and 'true' or 'false'
  elseif vt == 'number' then return encodeNumber(v)
  elseif vt == 'string' then return encodeString(v)
  elseif vt == 'table' then return encodeTable(v, seen)
  else return encodeString(tostring(v)) end
end

function json.encode(v)
  return encodeValue(v, {})
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

json.null = setmetatable({}, { __tostring = function() return 'null' end })

local function decodeError(str, pos, msg)
  error(string.format('json: %s at position %d', msg, pos))
end

local function skipWhitespace(str, pos)
  local _, e = str:find('^[ \n\r\t]*', pos)
  return e + 1
end

local function codepointToUtf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  else
    return string.char(0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
end

local decodeValue

local function decodeString(str, pos)
  -- pos points at opening quote
  local buf = {}
  local i = pos + 1
  while true do
    local c = str:sub(i, i)
    if c == '' then decodeError(str, i, 'unterminated string') end
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == '\\' then
      local e = str:sub(i + 1, i + 1)
      local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
        f = '\f', n = '\n', r = '\r', t = '\t' }
      if simple[e] then
        buf[#buf + 1] = simple[e]
        i = i + 2
      elseif e == 'u' then
        local hex = str:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then decodeError(str, i, 'bad unicode escape') end
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == '\\u' then
          local lo = tonumber(str:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = codepointToUtf8(cp)
      else
        decodeError(str, i, 'bad escape')
      end
    else
      local s, e = str:find('^[^"\\]+', i)
      buf[#buf + 1] = str:sub(s, e)
      i = e + 1
    end
  end
end

local function decodeNumber(str, pos)
  local s, e = str:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
  if not s then decodeError(str, pos, 'bad number') end
  local n = tonumber(str:sub(s, e))
  if not n then decodeError(str, pos, 'bad number') end
  return n, e + 1
end

local function decodeArray(str, pos)
  local arr = {}
  local n = 0
  pos = skipWhitespace(str, pos + 1)
  if str:sub(pos, pos) == ']' then return arr, pos + 1 end
  while true do
    local v
    v, pos = decodeValue(str, pos)
    n = n + 1
    if v ~= json.null then arr[n] = v end
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == ']' then return arr, pos + 1 end
    if c ~= ',' then decodeError(str, pos, "expected ',' or ']'") end
    pos = skipWhitespace(str, pos + 1)
  end
end

local function decodeObject(str, pos)
  local obj = {}
  pos = skipWhitespace(str, pos + 1)
  if str:sub(pos, pos) == '}' then return obj, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decodeError(str, pos, 'expected string key') end
    local key
    key, pos = decodeString(str, pos)
    pos = skipWhitespace(str, pos)
    if str:sub(pos, pos) ~= ':' then decodeError(str, pos, "expected ':'") end
    pos = skipWhitespace(str, pos + 1)
    local v
    v, pos = decodeValue(str, pos)
    if v ~= json.null then obj[key] = v end
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == '}' then return obj, pos + 1 end
    if c ~= ',' then decodeError(str, pos, "expected ',' or '}'") end
    pos = skipWhitespace(str, pos + 1)
  end
end

decodeValue = function(str, pos)
  pos = skipWhitespace(str, pos)
  local c = str:sub(pos, pos)
  if c == '{' then return decodeObject(str, pos)
  elseif c == '[' then return decodeArray(str, pos)
  elseif c == '"' then return decodeString(str, pos)
  elseif c == '-' or c:match('%d') then return decodeNumber(str, pos)
  elseif str:sub(pos, pos + 3) == 'true' then return true, pos + 4
  elseif str:sub(pos, pos + 4) == 'false' then return false, pos + 5
  elseif str:sub(pos, pos + 3) == 'null' then return json.null, pos + 4
  end
  decodeError(str, pos, "unexpected character '" .. c .. "'")
end

function json.decode(str)
  if type(str) ~= 'string' then error('json: expected string') end
  -- strip UTF-8 BOM if present
  if str:sub(1, 3) == '\239\187\191' then str = str:sub(4) end
  local v, pos = decodeValue(str, 1)
  pos = skipWhitespace(str, pos)
  if pos <= #str then decodeError(str, pos, 'trailing garbage') end
  if v == json.null then return nil end
  return v
end

return json
