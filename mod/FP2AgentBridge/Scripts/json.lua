-- Minimal JSON encoder/decoder for the bridge protocol.
-- Arrays are Lua tables with a positive integer sequence; set mt.__jsontype = "array"
-- (see json.array) to force an empty table to encode as [].

local json = {}

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }

function json.array(t) return setmetatable(t or {}, ARRAY_MT) end
function json.object(t) return setmetatable(t or {}, OBJECT_MT) end

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype then return mt.__jsontype == "array" end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n > 0 and n == #t
end

local encode

local function encode_table(t, seen)
    if seen[t] then return '"<cycle>"' end
    seen[t] = true
    local out = {}
    if is_array(t) then
        for i = 1, #t do out[i] = encode(t[i], seen) end
        seen[t] = nil
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        out[#out + 1] = encode_string(k) .. ":" .. encode(v, seen)
    end
    seen[t] = nil
    return "{" .. table.concat(out, ",") .. "}"
end

encode = function(v, seen)
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return string.format("%.14g", v)
    elseif tv == "string" then return encode_string(v)
    elseif tv == "table" then return encode_table(v, seen)
    else return encode_string("<" .. tv .. ">") end
end

function json.encode(v) return encode(v, {}) end

-- Decoder ---------------------------------------------------------------

local function decode_error(str, pos, msg)
    error(string.format("json decode error at %d: %s", pos, msg), 0)
end

local function skip_ws(str, pos)
    return str:find("[^ \t\r\n]", pos) or #str + 1
end

local decode_value

local function decode_string(str, pos)
    local buf, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then decode_error(str, i, "unterminated string") end
        if c == '"' then return table.concat(buf), i + 1 end
        if c == "\\" then
            local e = str:sub(i + 1, i + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if map[e] then
                buf[#buf + 1] = map[e]; i = i + 2
            elseif e == "u" then
                local code = tonumber(str:sub(i + 2, i + 5), 16)
                if not code then decode_error(str, i, "bad unicode escape") end
                buf[#buf + 1] = utf8 and utf8.char(code) or "?"
                i = i + 6
            else
                decode_error(str, i, "bad escape")
            end
        else
            buf[#buf + 1] = c; i = i + 1
        end
    end
end

decode_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected key") end
            local key
            key, pos = decode_string(str, pos)
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
            obj[key], pos = decode_value(str, pos + 1)
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or '}'") end
            pos = pos + 1
        end
    elseif c == "[" then
        local arr = json.array()
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            arr[#arr + 1], pos = decode_value(str, pos)
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decode_string(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then return nil, pos + 4
    else
        local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not num or num == "" then decode_error(str, pos, "unexpected character '" .. c .. "'") end
        return tonumber(num), pos + #num
    end
end

function json.decode(str)
    local v, pos = decode_value(str, 1)
    pos = skip_ws(str, pos)
    if pos <= #str then decode_error(str, pos, "trailing data") end
    return v
end

return json
