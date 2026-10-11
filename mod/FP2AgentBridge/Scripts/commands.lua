-- Bridge commands. Each handler runs on the game thread and returns a JSON-ready table
-- or raises an error string. `mutation = true` marks commands that can change game state.

local json = require("json")
local reflect = require("reflect")
local extractors = require("extractors")
local geo = require("geo")
local actions = require("actions")

local commands = {}
local registry = {}

local function def(name, spec)
    spec.name = name
    registry[name] = spec
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

local function lower(s) return s and tostring(s):lower() or nil end

local plain = reflect.plain
commands.plain = plain

local function findClass(name)
    if name:sub(1, 1) == "/" then
        local c = StaticFindObject(name)
        if reflect.isValid(c) then return c end
        return nil
    end
    local inst = FindFirstOf(name)
    if reflect.isValid(inst) then return inst:GetClass() end
    local found
    ForEachUObject(function(obj)
        if found then return end
        local ok, isClass = pcall(function() return obj:IsClass() end)
        if ok and isClass and reflect.shortName(obj) == name then found = obj end
    end)
    return found
end

local function requireObject(args)
    local obj, err = reflect.find(args.ref or args.path or args.object)
    if not obj then error(err, 0) end
    return obj
end

---------------------------------------------------------------------------

def("ping", {
    help = "Liveness check from the game thread.",
    run = function()
        return { pong = true, time = os.time(), bridge = commands.VERSION }
    end,
})

def("help", {
    help = "List commands. args: name (optional)",
    run = function(args)
        local list = json.array()
        for name, spec in pairs(registry) do
            if not args.name or args.name == name then
                list[#list + 1] = { name = name, help = spec.help, mutation = spec.mutation or false }
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end,
})

def("world", {
    help = "Current world/map, game mode/state classes, pause and time dilation.",
    run = function()
        local out = {}
        local pc = FindFirstOf("PlayerController")
        local world
        if reflect.isValid(pc) then
            out.playerController = reflect.ref(pc)
            local ok, w = pcall(function() return pc:GetWorld() end)
            if ok then world = w end
        end
        if not reflect.isValid(world) then
            local eng = FindFirstOf("GameEngine")
            if reflect.isValid(eng) then
                pcall(function() world = eng.GameViewport.World end)
            end
        end
        if reflect.isValid(world) then
            out.world = reflect.ref(world)
            out.map = reflect.shortName(world)
            pcall(function() out.gameMode = reflect.ref(world.AuthorityGameMode) end)
            pcall(function() out.gameState = reflect.ref(world.GameState) end)
            pcall(function()
                local ws = world.PersistentLevel.WorldSettings
                out.timeDilation = ws.TimeDilation
                out.paused = reflect.isValid(ws.PauserPlayerState)
            end)
        end
        local gi = FindFirstOf("GameInstance")
        out.gameInstance = reflect.ref(gi)
        return out
    end,
})

def("find_all", {
    help = "Instances of a class by short name. args: class, limit=50, contains (name filter)",
    run = function(args)
        if not args.class then error("class required", 0) end
        local limit = num(args.limit, 50)
        local filter = lower(args.contains)
        local all = FindAllOf(args.class) or {}
        local items = json.array()
        for _, o in ipairs(all) do
            if reflect.isValid(o) then
                local p = reflect.path(o)
                if not filter or (p and p:lower():find(filter, 1, true)) then
                    if #items >= limit then break end
                    items[#items + 1] = reflect.ref(o)
                end
            end
        end
        return { total = #all, items = items }
    end,
})

def("classes", {
    help = "Scan loaded UClasses. args: contains (name substring), module (e.g. /Script/Frostpunk2), limit=200",
    run = function(args)
        local filter = lower(args.contains)
        local module = args.module
        local limit = num(args.limit, 200)
        local items = json.array()
        local total = 0
        ForEachUObject(function(obj)
            local ok, isClass = pcall(function() return obj:IsClass() end)
            if not (ok and isClass) then return end
            local p = reflect.path(obj)
            if not p then return end
            if module and p:sub(1, #module) ~= module then return end
            if filter and not p:lower():find(filter, 1, true) then return end
            total = total + 1
            if #items < limit then items[#items + 1] = p end
        end)
        table.sort(items)
        return { total = total, items = items, truncated = total > #items }
    end,
})

def("modules", {
    help = "List /Script/<Module> packages with native class counts (find game-specific code).",
    run = function()
        local counts = {}
        ForEachUObject(function(obj)
            local ok, isClass = pcall(function() return obj:IsClass() end)
            if not (ok and isClass) then return end
            local p = reflect.path(obj)
            local m = p and p:match("^(/Script/[^%.]+)")
            if m then counts[m] = (counts[m] or 0) + 1 end
        end)
        local list = json.array()
        for m, c in pairs(counts) do list[#list + 1] = { module = m, classes = c } end
        table.sort(list, function(a, b) return a.classes > b.classes end)
        return list
    end,
})

def("search", {
    help = "Scan live objects (not classes). args: contains (path substring), class (class-name substring), limit=100, includeDefaults=false",
    run = function(args)
        local filter = lower(args.contains)
        local clsFilter = lower(args.class)
        if not filter and not clsFilter then error("contains or class required", 0) end
        local limit = num(args.limit, 100)
        local items = json.array()
        local total = 0
        ForEachUObject(function(obj)
            local p = reflect.path(obj)
            if not p then return end
            if not args.includeDefaults and p:find("Default__", 1, true) then return end
            if filter and not p:lower():find(filter, 1, true) then return end
            if clsFilter then
                local c = reflect.className(obj)
                if not c or not c:lower():find(clsFilter, 1, true) then return end
            end
            total = total + 1
            if #items < limit then items[#items + 1] = reflect.ref(obj) end
        end)
        return { total = total, items = items, truncated = total > #items }
    end,
})

def("functions", {
    help = "Catalog UFunctions of loaded classes. args: module=/Script/Frostpunk2, contains (function-name substring), class (class-name substring), limit=5000, params=true",
    run = function(args)
        local module = args.module or "/Script/Frostpunk2"
        local fnFilter = lower(args.contains)
        local clsFilter = lower(args.class)
        local limit = num(args.limit, 5000)
        local items = json.array()
        local total = 0
        ForEachUObject(function(obj)
            local ok, isClass = pcall(function() return obj:IsClass() end)
            if not (ok and isClass) then return end
            local p = reflect.path(obj)
            if not p or p:sub(1, #module) ~= module then return end
            local cname = reflect.shortName(obj) or "?"
            if clsFilter and not cname:lower():find(clsFilter, 1, true) then return end
            pcall(function()
                obj:ForEachFunction(function(f)
                    local fname = reflect.shortName(f) or "?"
                    if fname:find("__DelegateSignature", 1, true) then return end
                    if fnFilter and not fname:lower():find(fnFilter, 1, true) then return end
                    total = total + 1
                    if #items >= limit then return end
                    local entry = cname .. "." .. fname
                    if args.params ~= false then
                        local ps = {}
                        pcall(function()
                            f:ForEachProperty(function(pp)
                                ps[#ps + 1] = reflect.propName(pp) .. ":" .. reflect.paramTypeName(pp)
                            end)
                        end)
                        entry = entry .. "(" .. table.concat(ps, ", ") .. ")"
                    end
                    items[#items + 1] = entry
                end)
            end)
        end)
        table.sort(items)
        return { total = total, items = items, truncated = total > #items }
    end,
})

def("describe", {
    help = "Class schema: properties+functions incl. supers. args: class (short name or /Script path) | ref (instance), filter, ownOnly, stopAtEngine=true",
    run = function(args)
        local cls
        if args.ref then
            cls = requireObject(args):GetClass()
        elseif args.class then
            cls = findClass(args.class)
        end
        if not reflect.isValid(cls) then error("class not found", 0) end
        return reflect.describeClass(cls, {
            filter = args.filter,
            ownOnly = args.ownOnly,
            stopAtEngine = args.stopAtEngine ~= false,
        })
    end,
})

def("object", {
    help = "Dump property values of one object. args: ref, depth=1, filter, arrayLimit=50, types=false, expandObjects=false, gameOnly=true (skip Engine/CoreUObject-owned props)",
    run = function(args)
        local obj = requireObject(args)
        return {
            ref = reflect.path(obj),
            class = reflect.className(obj),
            props = reflect.dump(obj, {
                depth = num(args.depth, 1),
                filter = args.filter,
                arrayLimit = num(args.arrayLimit, 50),
                types = args.types,
                expandObjects = args.expandObjects,
                gameOnly = args.gameOnly ~= false,
            }),
        }
    end,
})

def("components", {
    help = "List an actor's components (instance + blueprint-created). args: ref, contains (class filter)",
    run = function(args)
        local actor = requireObject(args)
        local filter = lower(args.contains)
        local items, seen = json.array(), {}
        for _, field in ipairs({ "InstanceComponents", "BlueprintCreatedComponents" }) do
            pcall(function()
                actor[field]:ForEach(function(_, e)
                    local c = e:get()
                    local r = reflect.ref(c)
                    if r and not seen[r.ref] and (not filter or r.class:lower():find(filter, 1, true)) then
                        seen[r.ref] = true
                        items[#items + 1] = r
                    end
                end)
            end)
        end
        return items
    end,
})

def("locate", {
    help = "World location and screen pixel (client area) of an object/actor/component. args: ref | refs=[...]",
    run = function(args)
        if args.refs then
            local out = json.array()
            for _, r in ipairs(args.refs) do
                local obj = reflect.find(r)
                local e = obj and geo.locate(obj) or { error = "not found" }
                e.ref = r
                out[#out + 1] = e
            end
            return out
        end
        local obj = requireObject(args)
        local e = geo.locate(obj)
        e.ref = reflect.path(obj)
        return e
    end,
})

def("camera", {
    help = "Move the camera. args: ref (focus that object's actor) | x,y[,z] world position | reset=true; zoomTime (fixedZoomTime, default -1 keeps zoom), radius",
    run = function(args)
        local utils = StaticFindObject("/Script/Frostpunk2.Default__PXPlayerContextUtils")
        local ctx = FindFirstOf("PlayerController")
        local zoom = num(args.zoomTime, -1)
        local radius = num(args.radius, 0)
        local zero = { X = 0, Y = 0, Z = 0 }
        if args.reset then
            local cam = FindFirstOf("PXPlayerMovementCameraController")
            cam:ResetToStartingPosition()
            return { reset = true }
        end
        if args.ref then
            local obj = requireObject(args)
            local actor = geo.actorOf(obj)
            if not actor then error("no actor for " .. tostring(args.ref), 0) end
            utils:FocusCameraOnActor(ctx, actor, zoom, zero, radius)
            return { focused = reflect.path(actor), location = geo.location(actor) }
        end
        if args.x and args.y then
            local pos = { X = num(args.x, 0), Y = num(args.y, 0), Z = num(args.z, 0) }
            utils:FocusCameraOnPosition(ctx, pos, zoom, zero, radius)
            return { focused = pos }
        end
        error("camera needs ref, x+y, or reset=true", 0)
    end,
})

def("get", {
    help = "Read a dotted property path: args: ref, path (e.g. Foo.Bar[2].Baz), depth=2, arrayLimit=50",
    run = function(args)
        local obj = requireObject(args)
        if not args.path then error("path required", 0) end
        local v, err = reflect.get(obj, args.path, {
            depth = num(args.depth, 2), arrayLimit = num(args.arrayLimit, 50),
            expandObjects = args.expandObjects,
        })
        if err then error(err, 0) end
        return { value = v }
    end,
})

local READONLY_PREFIXES = { "Get", "Is", "Can", "Has", "Should", "Calc", "Calculate", "Find", "Compute", "K2_Get", "BP_Get", "Was", "Are" }

local function looksReadOnly(fn)
    for _, p in ipairs(READONLY_PREFIXES) do
        if fn:sub(1, #p) == p then return true end
    end
    return false
end

def("call", {
    help = "Call a UFunction on an object. args: ref, fn, args=[...] (\"@ref\" strings become objects; structs as tables). Non-getter names (not Get*/Is*/Can*/Has*/...) need mutate=true.",
    mutation = true,
    run = function(args)
        local obj = requireObject(args)
        local fn = args.fn
        if type(fn) ~= "string" then error("fn required", 0) end
        if not looksReadOnly(fn) and args.mutate ~= true then
            error("'" .. fn .. "' is not a getter-style name; pass mutate=true to call it", 0)
        end
        local f = obj[fn]
        if not reflect.isValid(f) then error("function not found: " .. fn, 0) end
        reflect.assertSafeCall(f, fn, args.unsafe == true)
        -- "@<ref>" string args resolve to UObjects (e.g. "@first:PXCityComponent").
        local params = {}
        for i, a in ipairs(args.args or {}) do
            if type(a) == "string" and a:sub(1, 1) == "@" then
                local o, err = reflect.find(a:sub(2))
                if not o then error("arg " .. i .. ": " .. err, 0) end
                params[i] = o
            else
                params[i] = a
            end
        end
        local results = table.pack(f(obj, table.unpack(params, 1, #(args.args or {}))))
        local out = json.array()
        for i = 1, results.n do out[i] = plain(results[i]) end
        return { results = out }
    end,
})

def("set", {
    help = "Set a top-level numeric/bool/string property. args: ref, prop, value, mutate=true required.",
    mutation = true,
    run = function(args)
        if args.mutate ~= true then error("set requires mutate=true", 0) end
        local obj = requireObject(args)
        local before = obj[args.prop]
        obj[args.prop] = args.value
        return { prop = args.prop, before = plain(before), after = plain(obj[args.prop]) }
    end,
})

def("extract", {
    help = "Run curated extractors. args: name (omit for list), or names=[...]",
    run = function(args)
        if args.name then return extractors.run(args.name, args) end
        if args.names then
            local out = {}
            for _, n in ipairs(args.names) do
                local ok, v = pcall(extractors.run, n, args)
                out[n] = reflect.result(ok, v)
            end
            return out
        end
        return extractors.list()
    end,
})

def("state", {
    help = "Run every extractor marked inState=true (the default snapshot for agents).",
    run = function(args)
        return extractors.snapshot(args)
    end,
})

---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Gameplay actions (actions.lua). Mutations go through the game's command layer.

def("game.pause", { help = "Pause (player pause, same as Space).", mutation = true, run = function() return actions.setPaused(true) end })
def("game.resume", { help = "Remove the player pause (modals may still pause).", mutation = true, run = function() return actions.setPaused(false) end })
def("game.speed", { help = "Set speed. args: level=0|1|2 (normal/fast/fastest)", mutation = true, run = function(args) return actions.setSpeed(args.level) end })
def("date", { help = "Current game time: ticks, week, date string.", run = function() return actions.date() end })
def("cells", {
    help = "City hex cells. args: free, frozen=true|false, deposit (type substring), maxDistance, nearX/nearY, limit=60, screen (add sx,sy), neighbors=true, city",
    run = function(args) return actions.cells(args) end,
})
def("pick_cells", {
    help = "Suggest a connected cluster of free cells next to the city. args: count=6, deposit (seed deposit type substring), frozen=true (frozen cells to frostbreak), nearX/nearY",
    run = function(args) return actions.pickCells(args) end,
})
def("modals", { help = "Open popups/decision windows with title/description text.", run = function() return actions.modals() end })
def("choose", {
    help = "Click a choice on an open modal. args: index=0, ref (modal, default first open), close=true",
    mutation = true,
    run = function(args) return actions.choose(args) end,
})
def("research", { help = "Research status: active topic/outcome, speed.", run = function(args) return actions.researchStatus(args) end })
def("research_topics", {
    help = "Research topics (available by default). args: all=true, contains, limit. Shows cost, communities and the outcome each would produce.",
    run = function(args) return actions.researchTopics(args) end,
})
def("research_start", {
    help = "Start research. args: topic (id or substring), community (type substring; decides the outcome), dryRun",
    mutation = true,
    run = function(args) return actions.researchStart(args) end,
})
def("districts", { help = "City districts with type, id, buildings, construction state.", run = function(args) return actions.districts(args) end })
def("building_types", {
    help = "Unlocked building types with the district types that accept them and cost. args: district (filter), contains",
    run = function(args) return actions.buildingTypes(args) end,
})
def("place_building", {
    help = "Construct a building in a district. args: type (building id substring), district (ref or type substring; default first that supports it), dryRun",
    mutation = true,
    run = function(args) return actions.placeBuilding(args) end,
})
def("council", { help = "Council state: active, phase, agenda policy, seats per faction, active policies, time to next session.", run = function(args) return actions.council(args) end })
def("laws", { help = "Unlocked inactive policies with per-faction support. args: contains, limit", run = function(args) return actions.laws(args) end })
def("propose", {
    help = "Request a council session to vote on a policy (propose a law). args: policy (id substring), skipRecess, dryRun",
    mutation = true,
    run = function(args) return actions.propose(args) end,
})
def("vote", { help = "InstructVote on a policy during a session. args: policy", mutation = true, run = function(args) return actions.vote(args) end })
def("open_icon", {
    help = "Click a map tracker icon through the game (opens its event/modal). args: ref (from extract name=icons)",
    mutation = true,
    run = function(args)
        local w = requireObject(args)
        local ok, err = pcall(function() w:OnTrackerClicked() end)
        if not ok then
            ok, err = pcall(function() w:OnTrackerClickedEvent() end)
        end
        if not ok then error("cannot click tracker: " .. tostring(err), 0) end
        return { clicked = reflect.className(w), modals = actions.modals() }
    end,
})
def("enum", { help = "List a UEnum's values. args: name (e.g. EPXVoteAttitude or /Script/...)", run = function(args)
    local out = json.object()
    for v, n in pairs(reflect.enumNames(args.name or "")) do out[tostring(v)] = n end
    return out
end })
def("keybinds", {
    help = "Keyboard/mouse bindings from Enhanced Input mapping contexts. args: contains (action substring), gamepad=false",
    run = function(args)
        local filter = lower(args.contains)
        local out = json.object()
        for _, imc in ipairs(FindAllOf("InputMappingContext") or {}) do
            if reflect.isValid(imc) and not (reflect.path(imc) or ""):find("Default__", 1, true) then
                pcall(function()
                    imc.Mappings:ForEach(function(_, m)
                        local e = m:get()
                        local action = reflect.shortName(e.Action) or "?"
                        local key = e.Key.KeyName:ToString()
                        local pad = key:find("Gamepad", 1, true) ~= nil
                        if (not filter or action:lower():find(filter, 1, true)) and (args.gamepad or not pad) then
                            out[action] = out[action] or json.array()
                            local list, dup = out[action], false
                            for _, k in ipairs(list) do if k == key then dup = true end end
                            if not dup then list[#list + 1] = key end
                        end
                    end)
                end)
            end
        end
        return out
    end,
})
def("expanders", { help = "Area expander (frostbreaking) types for the city.", run = function(args) return actions.expanders(args) end })
def("expand", {
    help = "Frostbreak/expand area. args: cells=[indices], type (expander id substring), dryRun=true to only check/price",
    mutation = true,
    run = function(args) return actions.expand(args) end,
})
def("district_types", { help = "Supported district types with cost and canConstruct.", run = function(args) return actions.districtTypes(args) end })
def("place_district", {
    help = "Place a district. args: type (id substring), cells=[6 indices], dryRun=true to only check",
    mutation = true,
    run = function(args) return actions.placeDistrict(args) end,
})

def("saves", {
    help = "Save names known to the game (PXSaveSubsystem.GetSaveFileNames). The CLI 'fp2 saves' adds timestamps from disk.",
    run = function()
        local sub = FindFirstOf("PXSaveSubsystem")
        if not reflect.isValid(sub) then error("PXSaveSubsystem not found", 0) end
        return reflect.invoke(sub, "GetSaveFileNames", {})
    end,
})
def("save", {
    help = "Manual save. args: name. The game writes a NEW file each time (FrostPunk2SaveGame, ...1, ...2; measured) and flushes on the next game tick, so follow with 'fp2 advance ticks=10'.",
    mutation = true,
    run = function(args)
        if type(args.name) ~= "string" or args.name == "" then error("name required", 0) end
        local sub = FindFirstOf("PXSaveSubsystem")
        local ok = sub:SaveGame(args.name, false, 0)
        return { queued = ok, name = args.name, note = "flushes when the game ticks (fp2 advance ticks=10); check fp2 saves" }
    end,
})
def("load", {
    help = "Load a save by name (from 'saves'). Works from the main menu or in game.",
    mutation = true,
    run = function(args)
        if type(args.name) ~= "string" then error("name required", 0) end
        local sub = FindFirstOf("PXSaveSubsystem")
        if not sub:DoesSaveGameExists(args.name) then error("no save named " .. args.name, 0) end
        return { loading = sub:LoadGame(args.name), name = args.name }
    end,
})

function commands.dispatch(name, args)
    local spec = registry[name]
    if not spec then error("unknown command: " .. tostring(name) .. " (try help)", 0) end
    return spec.run(args or {})
end

return commands
