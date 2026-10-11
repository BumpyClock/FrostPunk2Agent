-- Curated, named extractors for game data.
--
-- Discovery loop: find data with the generic commands (classes/describe/object/get),
-- then promote it here so agents get it in one cheap `state` call. Document every
-- extractor in .agents/skills/play-frostpunk2/references/DATA_MAP.md.
--
-- Two forms:
--   declarative: X.fromClass{ name, class, props = { "A", "B.C" }, all = false }
--   custom:      X.register{ name, help, inState, run = function(args) ... end }

local json = require("json")
local reflect = require("reflect")

local X = {}
local registry = {}
local order = {}

function X.register(spec)
    assert(spec.name and spec.run, "extractor needs name and run")
    if not registry[spec.name] then order[#order + 1] = spec.name end
    registry[spec.name] = spec
end

-- Read listed property paths from the first (or every) instance of a class.
function X.fromClass(spec)
    X.register({
        name = spec.name,
        help = spec.help or ("props of " .. spec.class),
        inState = spec.inState,
        run = function(args)
            local function readOne(obj)
                local out = { ref = reflect.path(obj) }
                for _, p in ipairs(spec.props) do
                    local ok, v, err = pcall(reflect.get, obj, p, { depth = spec.depth or 2, arrayLimit = spec.arrayLimit or 50 })
                    if ok and not err then out[p] = v else out[p] = { error = tostring(err or v) } end
                end
                return out
            end
            if spec.all then
                local items = json.array()
                for _, o in ipairs(FindAllOf(spec.class) or {}) do
                    if reflect.isValid(o) and not (reflect.path(o) or ""):find("Default__", 1, true) then
                        items[#items + 1] = readOne(o)
                    end
                end
                return items
            end
            local obj = FindFirstOf(spec.class)
            if not reflect.isValid(obj) then return { missing = spec.class } end
            return readOne(obj)
        end,
    })
end

function X.list()
    local out = json.array()
    for _, n in ipairs(order) do
        local s = registry[n]
        out[#out + 1] = { name = n, help = s.help, inState = s.inState or false }
    end
    return out
end

function X.run(name, args)
    local spec = registry[name]
    if not spec then error("unknown extractor: " .. tostring(name), 0) end
    return spec.run(args or {})
end

function X.snapshot(args)
    local out = { ["$time"] = os.time() }
    for _, n in ipairs(order) do
        if registry[n].inState then
            local ok, v = pcall(registry[n].run, args or {})
            out[n] = reflect.result(ok, v)
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Engine-level extractors (game-agnostic).

X.register({
    name = "session",
    help = "Map name, game mode/state classes, pause flag, time dilation.",
    inState = true,
    run = function()
        local out = {}
        local pc = FindFirstOf("PlayerController")
        if not reflect.isValid(pc) then return { inWorld = false } end
        local world = pc:GetWorld()
        out.inWorld = reflect.isValid(world)
        out.map = reflect.shortName(world)
        pcall(function() out.gameMode = reflect.className(world.AuthorityGameMode) end)
        pcall(function() out.gameState = reflect.className(world.GameState) end)
        pcall(function() out.playerController = reflect.className(pc) end)
        pcall(function()
            local ws = world.PersistentLevel.WorldSettings
            out.timeDilation = ws.TimeDilation
            out.paused = reflect.isValid(ws.PauserPlayerState)
        end)
        return out
    end,
})

---------------------------------------------------------------------------
-- Frostpunk 2 extractors. Add discovered data below; keep DATA_MAP.md in sync.

local ok, fp2 = pcall(require, "fp2_extractors")
if ok and type(fp2) == "function" then
    fp2(X)
elseif not ok then
    print("[FP2AgentBridge] fp2_extractors failed to load: " .. tostring(fp2) .. "\n")
end

return X
