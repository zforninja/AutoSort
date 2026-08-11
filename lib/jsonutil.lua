--[[
    jsonutil.lua — Self-contained JSON encode/decode for AutoSort.

    Why this exists:
      Windower's bundled `json` library only DECODES (json.parse). It provides
      neither `json.encode` nor `json.decode`, so relying on those silently
      failed every API response ("encode failed") and prevented settings from
      ever loading or saving. This module is a small, dependency-free JSON
      implementation (pure Lua 5.1, which is what Windower runs) used by both
      the HTTP server and the settings store.

    Public API:
      jsonutil.encode(value)  -> string            (never errors on our data)
      jsonutil.decode(str)    -> table | nil, err  (nil + message on bad input)

    Encoding rules relevant to this add-on:
      * nil / functions / userdata           -> null
      * boolean                              -> true / false
      * number (integer)                     -> 12345
      * number (float)                       -> 0.7
      * string                               -> escaped JSON string
      * table with contiguous 1..n keys      -> JSON array   [ ... ]
      * empty table                          -> JSON array   []   (all of our
                                                empty tables are lists: rules,
                                                moves, steps, items, jobs, ...)
      * table with any string key            -> JSON object  { ... }
]]

local jsonutil = {}

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

local function encode_number(n)
    -- Guard against non-finite values that have no JSON representation.
    if n ~= n or n == math.huge or n == -math.huge then
        return '0'
    end
    if math.floor(n) == n and math.abs(n) < 1e15 then
        return string.format('%d', n)
    end
    return string.format('%.14g', n)
end

-- Escape map for the common control characters.
local ESCAPES = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function encode_string(s)
    -- `%c` matches all control chars (incl. NUL and 0x7f) and works on both
    -- Lua 5.1 (Windower) and newer, unlike the 5.1-only `%z`.
    s = s:gsub('[%c\\"]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end

-- Returns (true, n) when t is a contiguous array 1..n (empty counts as array),
-- or false when t has any non-integer key or a hole.
local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k <= 0 or math.floor(k) ~= k then
            return false
        end
        if k > n then n = k end
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local encode_value  -- forward declaration

local function encode_table(t)
    local arr, n = is_array(t)
    local parts = {}
    if arr then
        for i = 1, n do
            parts[i] = encode_value(t[i])
        end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, v in pairs(t) do
        local kt = type(k)
        if kt == 'string' or kt == 'number' then
            parts[#parts + 1] = encode_string(tostring(k)) .. ':' .. encode_value(v)
        end
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

function encode_value(v)
    local t = type(v)
    if v == nil then
        return 'null'
    elseif t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'number' then
        return encode_number(v)
    elseif t == 'string' then
        return encode_string(v)
    elseif t == 'table' then
        return encode_table(v)
    end
    -- functions, threads, userdata are not representable.
    return 'null'
end

function jsonutil.encode(value)
    return encode_value(value)
end

-- ---------------------------------------------------------------------------
-- Decoding (recursive descent)
-- ---------------------------------------------------------------------------

local ESCAPE_CHARS = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

-- Minimal UTF-8 encoder for \uXXXX escapes (BMP only; sufficient for item text).
local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40),
                           0x80 + (code % 0x40))
    else
        return string.char(0xE0 + math.floor(code / 0x1000),
                           0x80 + (math.floor(code / 0x40) % 0x40),
                           0x80 + (code % 0x40))
    end
end

local function decode_impl(str)
    local pos = 1
    local len = #str

    local parse_value  -- forward declaration

    local function fail(msg)
        error(('JSON decode error at position %d: %s'):format(pos, msg), 0)
    end

    local function skip_ws()
        while pos <= len do
            local c = string.byte(str, pos)
            if c == 32 or c == 9 or c == 10 or c == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local buf = {}
        while true do
            if pos > len then fail('unterminated string') end
            local c = string.sub(str, pos, pos)
            if c == '"' then
                pos = pos + 1
                break
            elseif c == '\\' then
                local nxt = string.sub(str, pos + 1, pos + 1)
                if nxt == 'u' then
                    local hex = string.sub(str, pos + 2, pos + 5)
                    local code = tonumber(hex, 16)
                    if not code then fail('invalid \\u escape') end
                    buf[#buf + 1] = utf8_char(code)
                    pos = pos + 6
                elseif ESCAPE_CHARS[nxt] then
                    buf[#buf + 1] = ESCAPE_CHARS[nxt]
                    pos = pos + 2
                else
                    fail('invalid escape \\' .. nxt)
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parse_number()
        local s, e = string.find(str, '^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
        if not s then fail('invalid number') end
        local num = tonumber(string.sub(str, s, e))
        if not num then fail('invalid number') end
        pos = e + 1
        return num
    end

    local function parse_object()
        pos = pos + 1 -- skip {
        local obj = {}
        skip_ws()
        if string.sub(str, pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            if string.sub(str, pos, pos) ~= '"' then fail('expected string key') end
            local key = parse_string()
            skip_ws()
            if string.sub(str, pos, pos) ~= ':' then fail("expected ':'") end
            pos = pos + 1
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local c = string.sub(str, pos, pos)
            if c == ',' then
                pos = pos + 1
            elseif c == '}' then
                pos = pos + 1
                break
            else
                fail("expected ',' or '}'")
            end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1 -- skip [
        local arr = {}
        skip_ws()
        if string.sub(str, pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while true do
            skip_ws()
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = string.sub(str, pos, pos)
            if c == ',' then
                pos = pos + 1
            elseif c == ']' then
                pos = pos + 1
                break
            else
                fail("expected ',' or ']'")
            end
        end
        return arr
    end

    function parse_value()
        skip_ws()
        local c = string.sub(str, pos, pos)
        if c == '{' then
            return parse_object()
        elseif c == '[' then
            return parse_array()
        elseif c == '"' then
            return parse_string()
        elseif c == 't' then
            if string.sub(str, pos, pos + 3) == 'true' then pos = pos + 4; return true end
            fail('invalid token')
        elseif c == 'f' then
            if string.sub(str, pos, pos + 4) == 'false' then pos = pos + 5; return false end
            fail('invalid token')
        elseif c == 'n' then
            if string.sub(str, pos, pos + 3) == 'null' then pos = pos + 4; return nil end
            fail('invalid token')
        elseif c == '-' or (c >= '0' and c <= '9') then
            return parse_number()
        end
        fail('unexpected character ' .. (c == '' and '<eof>' or ("'" .. c .. "'")))
    end

    skip_ws()
    local result = parse_value()
    skip_ws()
    if pos <= len then
        fail('trailing data after JSON value')
    end
    return result
end

-- Returns decoded value, or (nil, errmsg) on failure. Never throws.
function jsonutil.decode(str)
    if type(str) ~= 'string' then
        return nil, 'input is not a string'
    end
    local ok, result = pcall(decode_impl, str)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

return jsonutil
