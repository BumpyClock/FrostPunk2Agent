-- Generic UE reflection -> plain Lua tables (JSON-ready).
-- Every read is pcall-guarded: one unreadable property must not fail a whole dump.

local json = require("json")

local reflect = {}

local NUMERIC = {
    Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true,
    FloatProperty = true, DoubleProperty = true,
}
local OBJECTISH = {
    ObjectProperty = true, ClassProperty = true, WeakObjectProperty = true,
    LazyObjectProperty = true, SoftObjectProperty = true, SoftClassProperty = true,
    InterfaceProperty = true, ObjectPtrProperty = true, ClassPtrProperty = true,
}

-- pcall result -> value, or {error=...}. Avoids the `ok and v or err` trap when v is false/nil.
function reflect.result(ok, v)
    if ok then return v end
    return { error = tostring(v) }
end

function reflect.isValid(obj)
    if obj == nil or type(obj) ~= "userdata" then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid
end

function reflect.fullName(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or nil
end

-- "Class /Path/To.Object" -> "/Path/To.Object"
function reflect.path(obj)
    local full = reflect.fullName(obj)
    if not full then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

function reflect.className(obj)
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and n or nil
end

function reflect.shortName(obj)
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or nil
end

function reflect.ref(obj)
    if not reflect.isValid(obj) then return nil end
    return { ref = reflect.path(obj), class = reflect.className(obj) }
end

function reflect.propType(prop)
    local ok, n = pcall(function() return prop:GetClass():GetFName():ToString() end)
    return ok and n or "UnknownProperty"
end

function reflect.propName(prop)
    return prop:GetFName():ToString()
end

-- Resolve an object reference string.
--   "/Script/Foo.Bar" or "/Game/Map.Map:PersistentLevel.Actor_1" -> StaticFindObject
--   "first:ClassName"                                       -> FindFirstOf
--   "Class /Path"  (a fullName copied from output)          -> path part
function reflect.find(ref)
    if type(ref) ~= "string" or ref == "" then return nil, "empty object reference" end
    local cls = ref:match("^first:(.+)$")
    if cls then
        local o = FindFirstOf(cls)
        if reflect.isValid(o) then return o end
        return nil, "no instance of " .. cls
    end
    local path = ref:match("^%S+%s+(/.+)$") or ref
    local ok, o = pcall(StaticFindObject, path)
    if ok and reflect.isValid(o) then return o end
    return nil, "object not found: " .. path
end

-- Iterate properties of a UStruct/UClass including supers.
function reflect.forEachProperty(struct, fn)
    local s = struct
    local guard = 0
    while reflect.isValid(s) and guard < 64 do
        local stop = false
        pcall(function()
            s:ForEachProperty(function(p)
                if fn(p, s) then stop = true; return true end
            end)
        end)
        if stop then return end
        local ok, sup = pcall(function() return s:GetSuperStruct() end)
        if not ok then return end
        s = sup
        guard = guard + 1
    end
end

function reflect.findProperty(struct, name)
    local found
    reflect.forEachProperty(struct, function(p)
        if reflect.propName(p) == name then found = p; return true end
    end)
    return found
end


-- Measured crash: UE4SS push_softobjectproperty dereferences null for some SoftObject values
-- (game crash while dumping a UMG widget). Never read these through the Lua bridge.
local UNSAFE_READ = { SoftObjectProperty = true, SoftClassProperty = true }
function reflect.unsafeRead(prop)
    local t = reflect.propType(prop)
    if UNSAFE_READ[t] then return t end
    if t == "ArrayProperty" or t == "SetProperty" then
        local ok, inner = pcall(function() return prop:GetInner() end)
        if ok and inner and UNSAFE_READ[reflect.propType(inner)] then return t .. "<" .. reflect.propType(inner) .. ">" end
    end
    if t == "MapProperty" then
        for _, getter in ipairs({ "GetKeyProp", "GetValueProp" }) do
            local ok, p = pcall(function() return prop[getter](prop) end)
            if ok and p and UNSAFE_READ[reflect.propType(p)] then return t .. "<" .. reflect.propType(p) .. ">" end
        end
    end
    return nil
end

local convert

local function toStr(v)
    local ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return tostring(v)
end

local function convertStruct(raw, prop, depth, opts)
    local okS, structDef = pcall(function() return prop:GetStruct() end)
    local structName = okS and reflect.shortName(structDef) or "?"
    if depth <= 0 then return { struct = structName, truncated = true } end
    local out = { ["$struct"] = structName }
    reflect.forEachProperty(structDef, function(p)
        local name = reflect.propName(p)
        local unsafe = reflect.unsafeRead(p)
        if unsafe then out[name] = { skipped = unsafe }; return end
        local ok, v = pcall(function() return convert(raw[name], p, depth - 1, opts) end)
        out[name] = reflect.result(ok, v)
    end)
    return out
end

local function convertArray(raw, prop, depth, opts)
    local okN, num = pcall(function() return raw:GetArrayNum() end)
    num = okN and num or 0
    if depth <= 0 then return { count = num, truncated = true } end
    local okI, inner = pcall(function() return prop:GetInner() end)
    local items = json.array()
    local limit = opts.arrayLimit or 50
    pcall(function()
        raw:ForEach(function(i, elem)
            if i > limit then return true end
            local ok, v = pcall(function() return convert(elem:get(), inner, depth - 1, opts) end)
            items[#items + 1] = reflect.result(ok, v)
        end)
    end)
    if num > limit then
        return { count = num, items = items, truncated = true }
    end
    return items
end

-- Best-effort conversion for values whose property type is unknown.
function reflect.plain(v, depth)
    depth = depth or 2
    if type(v) == "table" then
        -- UFunction array/struct returns arrive as Lua tables of userdata; TMaps inside them
        -- are Lua tables keyed by userdata params.
        local userKeys = false
        for k in pairs(v) do if type(k) == "userdata" then userKeys = true; break end end
        if userKeys then
            local entries = json.array()
            for k, x in pairs(v) do
                local key = k
                pcall(function() key = k:get() end)
                local val = x
                if type(x) == "userdata" then pcall(function() val = x:get() end) end
                entries[#entries + 1] = { key = reflect.plain(key, depth), value = reflect.plain(val, depth) }
            end
            return entries
        end
        local out = (#v > 0 or next(v) == nil) and json.array() or {}
        for k, x in pairs(v) do out[k] = reflect.plain(x, depth) end
        return out
    end
    if type(v) ~= "userdata" then return v end
    if reflect.isValid(v) then
        local r = reflect.ref(v)
        if r then return r end
    end
    local okS, s = pcall(function() return v:ToString() end)
    if okS then return s end
    local okA, n = pcall(function() return v:GetArrayNum() end)
    if okA then
        local items = json.array()
        if depth > 0 then
            pcall(function()
                v:ForEach(function(i, e)
                    if i > 100 then return true end
                    items[#items + 1] = reflect.plain(e:get(), depth - 1)
                end)
            end)
        end
        return { count = n, items = items }
    end
    local okG, g = pcall(function() return v:get() end)
    if okG and g ~= v then return reflect.plain(g, depth - 1) end
    return tostring(v)
end

local function firstProp(prop, names)
    for _, n in ipairs(names) do
        local ok, p = pcall(function() return prop[n](prop) end)
        if ok and p ~= nil then return p end
    end
    return nil
end

local function convertMap(raw, prop, depth, opts)
    if depth <= 0 then return { map = true, truncated = true } end
    local keyProp = firstProp(prop, { "GetKeyProp", "GetKeyProperty" })
    local valProp = firstProp(prop, { "GetValueProp", "GetValueProperty" })
    local entries = json.array()
    local limit = opts.arrayLimit or 50
    local function conv(x, p)
        if type(x) == "userdata" and x.get then
            local ok, g = pcall(function() return x:get() end)
            if ok then x = g end
        end
        if p then
            local ok, v = pcall(convert, x, p, depth - 1, opts)
            if ok then return v end
        end
        return reflect.plain(x, depth - 1)
    end
    local ok, err = pcall(function()
        local n = 0
        raw:ForEach(function(k, v)
            n = n + 1
            if n > limit then return true end
            entries[#entries + 1] = { key = conv(k, keyProp), value = conv(v, valProp) }
        end)
    end)
    if not ok then return { unsupported = "MapProperty", error = tostring(err) } end
    return entries
end

convert = function(raw, prop, depth, opts)
    local t = reflect.propType(prop)
    if raw == nil then return nil end
    if NUMERIC[t] then return raw end
    if t == "BoolProperty" then return raw and true or false end
    if t == "ByteProperty" then
        local okE, enum = pcall(function() return prop:GetEnum() end)
        if okE and reflect.isValid(enum) then
            local okN, nm = pcall(function() return enum:GetNameByValue(raw):ToString() end)
            return { value = raw, name = okN and nm or nil }
        end
        return raw
    end
    if t == "EnumProperty" then
        local okN, nm = pcall(function() return prop:GetEnum():GetNameByValue(raw):ToString() end)
        return { value = raw, name = okN and nm or nil }
    end
    if t == "NameProperty" or t == "StrProperty" or t == "TextProperty" then return toStr(raw) end
    if OBJECTISH[t] then
        local obj = raw
        if type(raw) == "userdata" and not reflect.isValid(raw) then
            local okG, g = pcall(function() return raw:Get() end)
            if okG then obj = g end
        end
        if not reflect.isValid(obj) then return nil end
        if opts.expandObjects and depth > 0 then
            local r = reflect.ref(obj)
            r.props = reflect.dump(obj, { depth = depth - 1, arrayLimit = opts.arrayLimit, filter = nil })
            return r
        end
        return reflect.ref(obj)
    end
    if t == "StructProperty" then return convertStruct(raw, prop, depth, opts) end
    if t == "ArrayProperty" then return convertArray(raw, prop, depth, opts) end
    if t == "MapProperty" or t == "SetProperty" then return convertMap(raw, prop, depth, opts) end
    if t:find("Delegate") then return { delegate = t } end
    return { unsupported = t }
end

reflect.convert = convert

local ENGINE_PREFIXES = { "/Script/Engine.", "/Script/CoreUObject.", "/Script/UMG.", "/Script/CommonUI." }

function reflect.isEngineStruct(struct)
    local p = reflect.path(struct) or ""
    for _, pre in ipairs(ENGINE_PREFIXES) do
        if p:sub(1, #pre) == pre then return true end
    end
    return false
end

-- Dump all properties of a UObject. opts: depth, arrayLimit, filter (substring), types, gameOnly (skip engine-owned props)
function reflect.dump(obj, opts)
    opts = opts or {}
    local depth = opts.depth or 1
    local filter = opts.filter and opts.filter:lower() or nil
    local out = {}
    local okC, cls = pcall(function() return obj:GetClass() end)
    if not okC then return { error = "no class" } end
    reflect.forEachProperty(cls, function(p, owner)
        if opts.gameOnly and reflect.isEngineStruct(owner) then return end
        local name = reflect.propName(p)
        if filter and not name:lower():find(filter, 1, true) then return end
        if out[name] ~= nil then return end
        local unsafe = reflect.unsafeRead(p)
        if unsafe then out[name] = { skipped = unsafe }; return end
        local ok, v = pcall(function() return convert(obj[name], p, depth, opts) end)
        local value = reflect.result(ok, v)
        if opts.types then
            out[name] = { type = reflect.propType(p), value = value }
        else
            out[name] = value == nil and json.object({ ["$null"] = true }) or value
        end
    end)
    return out
end

-- Describe a class: properties (name/type/owner) and functions, walking supers.
function reflect.describeClass(cls, opts)
    opts = opts or {}
    local filter = opts.filter and opts.filter:lower() or nil
    local props, funcs = json.array(), json.array()
    local chain = json.array()
    local s, guard = cls, 0
    while reflect.isValid(s) and guard < 64 do
        local owner = reflect.shortName(s)
        chain[#chain + 1] = owner
        if not opts.ownOnly or guard == 0 then
            pcall(function()
                s:ForEachProperty(function(p)
                    local name = reflect.propName(p)
                    if not filter or name:lower():find(filter, 1, true) then
                        props[#props + 1] = { name = name, type = reflect.propType(p), owner = owner }
                    end
                end)
            end)
            pcall(function()
                s:ForEachFunction(function(f)
                    local name = reflect.shortName(f)
                    if name and (not filter or name:lower():find(filter, 1, true)) then
                        local params = json.array()
                        pcall(function()
                            f:ForEachProperty(function(p)
                                params[#params + 1] = reflect.propName(p) .. ":" .. reflect.paramTypeName(p)
                            end)
                        end)
                        funcs[#funcs + 1] = { name = name, owner = owner, params = params }
                    end
                end)
            end)
        end
        local ok, sup = pcall(function() return s:GetSuperStruct() end)
        if not ok then break end
        s = sup
        guard = guard + 1
        if opts.stopAtEngine and owner and (owner == "Actor" or owner == "Object" or owner == "ActorComponent") then break end
    end
    return { class = reflect.path(cls), chain = chain, properties = props, functions = funcs }
end

-- Walk "a.b[2].c" from an object. Returns converted value.
function reflect.get(obj, path, opts)
    opts = opts or {}
    local cur = obj
    local curProp = nil
    local segments = {}
    for seg in path:gmatch("[^%.]+") do segments[#segments + 1] = seg end
    for i, seg in ipairs(segments) do
        local name, idx = seg:match("^([^%[]+)%[(%d+)%]$")
        name = name or seg
        local container = cur
        local struct
        if curProp and reflect.propType(curProp) == "StructProperty" then
            struct = curProp:GetStruct()
        else
            struct = container:GetClass()
        end
        local prop = reflect.findProperty(struct, name)
        if not prop then return nil, "no property '" .. name .. "' at segment " .. i end
        local unsafe = reflect.unsafeRead(prop)
        if unsafe then return nil, "refusing to read " .. unsafe .. " '" .. name .. "' (crashes UE4SS)" end
        local raw = container[name]
        if idx then
            idx = tonumber(idx)
            local inner = prop:GetInner()
            local found
            raw:ForEach(function(j, elem)
                if j - 1 == idx then found = elem:get(); return true end
            end)
            if found == nil then return nil, "index out of range at segment " .. i end
            raw, prop = found, inner
        end
        if i == #segments then
            return convert(raw, prop, opts.depth or 2, opts)
        end
        local t = reflect.propType(prop)
        if OBJECTISH[t] then
            if not reflect.isValid(raw) then return nil, "null object at segment " .. i end
            cur, curProp = raw, nil
        elseif t == "StructProperty" then
            cur, curProp = raw, prop
        else
            return nil, "cannot descend into " .. t .. " at segment " .. i
        end
    end
    return reflect.ref(cur)
end

-- UE4SS (3.0.1-1164) crashes the game (access violation in FText copy) when a UFunction
-- call marshals a struct that contains FText. Detect such signatures before calling.
local textCache = {}
local function typeHasText(prop, depth)
    if depth > 6 then return false end
    local t = reflect.propType(prop)
    if t == "TextProperty" then return true end
    if t == "StructProperty" then
        local ok, sd = pcall(function() return prop:GetStruct() end)
        if not ok or not reflect.isValid(sd) then return false end
        local key = reflect.path(sd) or "?"
        if textCache[key] ~= nil then return textCache[key] end
        textCache[key] = false
        local found = false
        reflect.forEachProperty(sd, function(p)
            if typeHasText(p, depth + 1) then found = true; return true end
        end)
        textCache[key] = found
        return found
    end
    if t == "ArrayProperty" or t == "SetProperty" then
        local ok, inner = pcall(function() return prop:GetInner() end)
        return ok and inner ~= nil and typeHasText(inner, depth + 1)
    end
    if t == "MapProperty" then
        local okK, k = pcall(function() return prop:GetKeyProp() end)
        local okV, v = pcall(function() return prop:GetValueProp() end)
        return (okK and k ~= nil and typeHasText(k, depth + 1)) or (okV and v ~= nil and typeHasText(v, depth + 1))
    end
    return false
end

-- Returns the list of parameter names that would marshal FText through a struct/container.
function reflect.unsafeParams(fn)
    local bad = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local t = reflect.propType(p)
            if t ~= "TextProperty" and typeHasText(p, 0) then bad[#bad + 1] = reflect.propName(p) end
        end)
    end)
    return bad
end

function reflect.paramTypeName(p)
    local t = reflect.propType(p):gsub("Property$", "")
    if t == "Struct" then
        local ok, sd = pcall(function() return p:GetStruct() end)
        if ok then t = "Struct<" .. (reflect.shortName(sd) or "?") .. ">" end
    elseif t == "Object" or t == "Class" then
        local ok, c = pcall(function() return p:GetPropertyClass() end)
        if ok and c then t = t .. "<" .. (reflect.shortName(c) or "?") .. ">" end
    elseif t == "Enum" or t == "Byte" then
        local ok, e = pcall(function() return p:GetEnum() end)
        if ok and reflect.isValid(e) then t = t .. "<" .. (reflect.shortName(e) or "?") .. ">" end
    end
    if typeHasText(p, 0) and reflect.propType(p) ~= "TextProperty" then t = t .. "!text" end
    return t
end

function reflect.assertSafeCall(fn, fnName, unsafe)
    local bad = reflect.unsafeParams(fn)
    if #bad > 0 and not unsafe then
        error(fnName .. ": params " .. table.concat(bad, ",") .. " contain FText inside a struct/container; " ..
            "UE4SS crashes the game on such calls. Read the data another way (pass unsafe=true only if you accept a crash).", 0)
    end
end

-- Call a UFunction and convert its ReturnValue using the function's own property type
-- (structs/arrays come back as tables instead of opaque userdata).
function reflect.invoke(obj, fnName, params, depth)
    local f = obj[fnName]
    if not reflect.isValid(f) then error("function not found: " .. tostring(fnName), 0) end
    reflect.assertSafeCall(f, fnName, false)
    local retProp
    pcall(function()
        f:ForEachProperty(function(p)
            if reflect.propName(p) == "ReturnValue" then retProp = p; return true end
        end)
    end)
    params = params or {}
    local raw = f(obj, table.unpack(params, 1, params.n or #params))
    if retProp == nil then return nil end
    if type(raw) ~= "userdata" then return reflect.plain(raw, depth or 3) end
    local ok, v = pcall(convert, raw, retProp, depth or 3, { arrayLimit = 2000 })
    if ok then return v end
    return reflect.plain(raw, depth or 3)
end

-- value -> short name for a UEnum ("/Script/Frostpunk2.EPXVoteAttitude" or just "EPXVoteAttitude").
local enumCache = {}
function reflect.enumNames(name)
    if enumCache[name] then return enumCache[name] end
    local path = name:sub(1, 1) == "/" and name or ("/Script/Frostpunk2." .. name)
    local e = StaticFindObject(path)
    local map = {}
    if reflect.isValid(e) then
        pcall(function()
            e:ForEachName(function(n, v) map[v] = (n:ToString():gsub("^.*::", "")) end)
        end)
    end
    enumCache[name] = map
    return map
end

return reflect
