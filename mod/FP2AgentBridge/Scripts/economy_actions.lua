-- Economy and state reads: utopia_v2, stock_caps, heat_levels, health. All read-only.
--
-- Rules applied (MOD_DEVELOPMENT.md "Crash hazards (measured)"):
--   * register() only calls def(); no game object is touched at load, no userdata is cached between calls
--     (module-level caches hold plain data only).
--   * Every UFunction whose signature is not in a describe dump goes through checkedCall(): it refuses
--     FText params/returns (reflect.unsafeParams), requires every Object arg to be valid and an instance of the
--     declared param class, and checks arity, before the call. A mismatch returns data ("skipped"), not a call.
--   * Untested sub-reads are opt-in args (unlocks=true, deep=true, affinities=true, debug=true) so one crash can
--     be traced to one call.
--   * Never called: PXUtopiaToolsUtils.GetUtopiaToolGameplayDescription, PXUtopiaToolPanelsUtils.GetNodeUIData /
--     GetNodesUIData / GetNodeDetailsUIData (FText structs, class E), AddUtopiaToolBonusPoint and the
--     PXUtopiaToolsDebugPanel handlers (cheats).

local M = {}

---------------------------------------------------------------------------
-- health thresholds. Every number is a constant here. "src" cites research-tips.md (scratchpad) or brief.ts.
-- Labels: [spec] given by the task, [brief] same numbers as cli/src/brief.ts so both agree, [tips] research-tips.md
-- "Health dashboard (thresholds)", [guess] no source found (research-tips.md: "No numeric thresholds for trust,
-- tension, or fervour were found").
local TH = {
    TICKS_WEEK = 1680,                 -- measured: DATA_MAP.md (1680 ticks = 1 week)
    RUNWAY_OK = 20,                    -- [spec] weeks: >= 20 ok
    RUNWAY_WATCH = 10,                 -- [spec] 10..20 watch; brief.ts alerts under 10 weeks
    RUNWAY_ACT = 5,                    -- [spec] 5..10 act; under 5 critical
    GEN_LOAD_WATCH = 0.85,             -- [guess] power / powerLimit
    GEN_LOAD_ACT = 0.95,               -- [guess]
    WEAR_WATCH = 0.4,                  -- [tips] tip 18: overdrive "generally safe up to 60%"; watch below that
    WEAR_ACT = 0.6,                    -- [tips] tip 18
    WEAR_CRIT = 0.85,                  -- [guess] wear 1 = malfunction with casualties (actions.lua generator comment)
    STAT_WATCH_CUR = 40, STAT_WATCH_TGT = 60,   -- [brief] "worrying"
    STAT_ACT_CUR = 70, STAT_ACT_TGT = 80,       -- [brief] alert
    STAT_CRIT_CUR = 90,                         -- [guess]
    TENSION_WATCH = 40, TENSION_ACT = 70, TENSION_CRIT = 85,   -- [guess] tip 60: max Tension = game over; no numeric trigger found
    TRUST_CRIT = 0.1, TRUST_ACT = 0.25, TRUST_WATCH = 0.4,     -- [guess] totalTrust measured 0.565 (0..1 scale assumed, unverified vs HUD)
    HOMELESS_WATCH = 1, HOMELESS_ACT_FRAC = 0.02,              -- [brief] any homeless alerts; 2% of population is [guess]
    WHITEOUT_ACT_WEEKS = 20,           -- [guess] research-tips: early whiteouts run 30-40 weeks, warning came 73 weeks ahead
    WHITEOUT_WATCH_WEEKS = 75,         -- [tips] warning 73 weeks before the whiteout (DATA_MAP.md, measured)
    DROP_WATCH_WEEKS = 10,             -- [brief] weather.forecastDrop looks 10 weeks ahead (DATA_MAP.md)
    QUEST_WATCH_WEEKS = 10, QUEST_ACT_WEEKS = 5,   -- [guess] same bands as runway
    MAX_BYTES = 3000,                  -- [spec] keep the health output under ~3 KB
    MAX_REASONS = 8,
}
M.THRESHOLDS = TH

local SEV = { ok = 0, watch = 1, act = 2, critical = 3 }
local SEV_NAME = { [0] = "ok", "watch", "act", "critical" }
local GOOD_STATS = { Wealth = true, CitySize = true, NationSize = true, FAKE_Sickliness = true } -- [brief] + hidden fake stat

-- Plain-data caches (no userdata).
local effectCache = {}   -- district type path -> simplified stockpile effect list
local grantCache = {}    -- utopia node instance path -> grants table
local lastDeaths         -- { value = n, tick = n } for the deaths delta between health calls

function M.register(def, env)
    local A, reflect, json, h = env.actions, env.reflect, env.json, env.h
    local cdo, assetId, ctx, try, textOf, objList, uarray, simplify, compactCost =
        h.cdo, h.assetId, h.ctx, h.try, h.textOf, h.objList, h.uarray, h.simplify, h.compactCost

    ---------------------------------------------------------------------------
    -- helpers

    local function r1(x) if type(x) ~= "number" then return x end return math.floor(x * 10 + 0.5) / 10 end
    local function r3(x) if type(x) ~= "number" then return x end return math.floor(x * 1000 + 0.5) / 1000 end
    local function valid(x) return reflect.isValid(x) end
    local function flag(v) return v == true or v == "true" or v == 1 end
    local function on(args, key) return args[key] ~= false and args[key] ~= "false" end   -- opt-out switch (default on)
    local function isErr(v) return type(v) == "table" and v.error ~= nil end
    local function short(id) return (tostring(id):gsub("^Core_", ""):gsub("Resource$", "")) end

    local function names(obj)
        local set = {}
        pcall(function()
            local c, guard = obj:GetClass(), 0
            while valid(c) and guard < 40 do
                set[reflect.shortName(c) or "?"] = true
                c = c:GetSuperStruct()
                guard = guard + 1
            end
        end)
        return set
    end

    local function paramList(fn)
        local list = {}
        pcall(function()
            fn:ForEachProperty(function(p)
                local e = { name = reflect.propName(p), ptype = reflect.propType(p) }
                if e.ptype == "ObjectProperty" then
                    pcall(function() e.class = reflect.shortName(p:GetPropertyClass()) end)
                end
                list[#list + 1] = e
            end)
        end)
        return list
    end

    -- Returns true, or nil plus the reason the call is refused.
    local function checkArgs(util, fnName, values)
        local fn = util[fnName]
        if not valid(fn) then return nil, "no function " .. fnName end
        local bad = reflect.unsafeParams(fn)
        if #bad > 0 then return nil, "FText in " .. table.concat(bad, ",") end
        local n = values.n or #values
        local i = 0
        for _, p in ipairs(paramList(fn)) do
            if p.name ~= "ReturnValue" then
                i = i + 1
                if p.ptype == "ObjectProperty" then
                    local v = values[i]
                    if not valid(v) then return nil, "arg " .. p.name .. " invalid" end
                    if p.class and p.class ~= "Object" and not names(v)[p.class] then
                        return nil, "param " .. p.name .. " expects " .. p.class .. ", got " .. tostring(reflect.className(v))
                    end
                end
            end
        end
        if i ~= n then return nil, "arity " .. i .. " vs " .. n end
        return true
    end

    -- Raw call after checkArgs. Returns ok, value (or reason when refused).
    local function rawCall(util, fnName, ...)
        local values = table.pack(...)
        local ok, why = checkArgs(util, fnName, values)
        if not ok then return false, why end
        local okC, v = pcall(function() return util[fnName](util, table.unpack(values, 1, values.n)) end)
        return okC, v
    end

    -- Converted call (reflect.invoke turns structs/arrays into tables). Returns ok, value.
    local function convCall(util, fnName, ...)
        local values = table.pack(...)
        local ok, why = checkArgs(util, fnName, values)
        if not ok then return false, why end
        return pcall(reflect.invoke, util, fnName, values)
    end

    local function anyList(v)
        if type(v) == "table" then return objList(v) end
        if type(v) == "userdata" then
            local out = {}
            for _, x in ipairs(uarray(v)) do if valid(x) then out[#out + 1] = x end end
            return out
        end
        return {}
    end

    local function cityList() return A.cities() end
    local function cityIndex(city)
        local p = reflect.path(city)
        for i, c in ipairs(cityList()) do if reflect.path(c) == p then return i end end
        return 1
    end

    -- The player's main city (colonies exist in multi-city saves); args.city overrides (same selector as other commands).
    local function pickCity(args)
        if args.city ~= nil then return A.city(args) end
        local okN, nu = pcall(cdo, "PXNationUtils")
        if okN then
            local ok, c = rawCall(nu, "GetPlayerMainCity", ctx())
            if ok and valid(c) and reflect.className(c) == "PXCityComponent" then return c end
        end
        return A.city({})
    end

    local function extractorFor(name, cityRef)
        local ok, res = pcall(env.extractors.run, name, {})
        if not ok then return nil, tostring(res) end
        if type(res) == "table" then
            for _, e in ipairs(res) do if type(e) == "table" and e.ref == cityRef then return e end end
            if res[1] and res[1].ref == nil then return res end
        end
        return nil, "no " .. name .. " entry for the city"
    end

    local function strip(t) if type(t) == "table" then t["$struct"] = nil end return t end

    ---------------------------------------------------------------------------
    -- utopia_v2

    local GRANT_KINDS = {
        { key = "buildings", fn = "GetBuildingsRequiringUtopiaToolNode" },
        { key = "districts", fn = "GetDistrictsRequiringUtopiaToolNode" },
        { key = "laws", fn = "GetPoliciesRequiringUtopiaToolNode" },
        { key = "abilities", fn = "GetAbilitiesRequiringUtopiaToolNode" },
        { key = "actions", fn = "GetCommunityActionsRequiringUtopiaToolNode" },
        { key = "research", fn = "GetResearchTopicsRequiringUtopiaToolNode" },
    }

    local function nodeInstances(comp)
        local map = {}
        for _, inst in ipairs(uarray(comp.NodeInstances)) do
            if valid(inst) then
                local tag = h.tagName(inst.GameplayTag)
                if tag then map[tag] = inst end
            end
        end
        return map
    end

    -- Which object the requirement-relation getters expect (graph node definition or its runtime instance).
    local function nodeArgFor(ru, inst, mode)
        local fn = ru[GRANT_KINDS[1].fn]
        if not valid(fn) then return nil, "no " .. GRANT_KINDS[1].fn end
        local declared
        for _, p in ipairs(paramList(fn)) do if p.name == "utopiaToolNode" then declared = p.class end end
        local def_ = inst.Node
        local cands = { def = def_, inst = inst }
        if mode == "def" or mode == "inst" then return cands[mode], mode end
        for _, key in ipairs({ "def", "inst" }) do
            local c = cands[key]
            if valid(c) and declared and declared ~= "Object" and names(c)[declared] then return c, key end
        end
        if declared == "Object" or declared == nil then
            if valid(def_) then return def_, "def (declared class Object: assumed the node definition)" end
        end
        return nil, "declared class " .. tostring(declared) .. " matches neither inst.Node nor the instance"
    end

    local function nodeGrants(ru, inst, mode)
        local key = reflect.path(inst)
        if key and grantCache[key .. "|" .. tostring(mode)] then return grantCache[key .. "|" .. tostring(mode)] end
        local arg, how = nodeArgFor(ru, inst, mode)
        if not arg then return { skipped = how } end
        local g = json.object()
        for _, k in ipairs(GRANT_KINDS) do
            local ok, v = rawCall(ru, k.fn, ctx(), arg)
            if ok then
                local list = json.array()
                for _, o in ipairs(anyList(v)) do list[#list + 1] = assetId(o) end
                if #list > 0 then g[k.key] = list end
            else
                g[k.key] = { skipped = tostring(v) }
            end
        end
        g.arg = how
        if key then grantCache[key .. "|" .. tostring(mode)] = g end
        return g
    end

    def("utopia_v2", {
        help = "Utopia Tree v2 (Fractured Utopias): per faction points/cap/threshold (ScoreTracker + GetScoreUIData raw), HasPointToAssign, dominant tool, node states with counts and assignable (Open) nodes, panel target community. Read-only; spending a point stays utopia_assign (no non-UI path exists). args: faction, brief=false (node text), unlocks=true (what each node grants: buildings/districts/laws/abilities/actions/research; PXRequirementRelationsUtils), nodeArg=def|inst, affinities=true (community core affinities + nation state affinities), debug=true (UtopiaToolConfig dump). Opt-outs, default on, for crash isolation (minimal first run: dominant=false panel=false has=false score=false tracker=false): dominant, panel, has, score, tracker",
        run = function(args)
            local brief = args.brief ~= false
            local base = A.utopia({ faction = args.faction, brief = brief })
            local utils, panels = cdo("PXUtopiaToolsUtils"), cdo("PXUtopiaToolPanelsUtils")
            local byFaction, byPath = {}, {}
            for _, comp in ipairs(FindAllOf("PXUtopiaToolComponent") or {}) do
                if valid(comp) then
                    pcall(function()
                        local cc = comp:GetOwner():GetComponentByClass(StaticFindObject("/Script/Frostpunk2.PXCommunityComponent"))
                        if valid(cc) then
                            local fid = assetId(cc.Type)
                            if fid then
                                byFaction[fid] = { comp = comp, cc = cc }
                                byPath[reflect.path(comp) or "?"] = fid
                            end
                        end
                    end)
                end
            end

            local out = { factions = json.array(), nonUiAssign = false,
                note = "Spending a point has no reflected non-UI path (PXUtopiaToolComponent has only UtopiaName/NodeInstances/ScoreTracker; AssignPoint exists only on PXUtopiaNodeDetailsPanel); use utopia_assign / fp2 utopia-assign." }

            -- Dominant tool, panel target.
            if on(args, "dominant") then
                local okD, dom = rawCall(utils, "GetDominantUtopiaTool", ctx())
                if okD and valid(dom) then out.dominant = byPath[reflect.path(dom) or "?"] or assetId(dom) end
            end
            local panel = json.object()
            local function communityId(o)
                if not valid(o) then return nil end
                local id
                pcall(function() id = assetId(o.Type) end)
                return id or assetId(o)
            end
            if on(args, "panel") then
                local okC, cur = rawCall(panels, "GetCurrentCommunity", ctx())
                if okC then panel.community = communityId(cur) else panel.communityError = tostring(cur) end
                local okT, tool = rawCall(panels, "GetCurrentUtopiaTool", ctx())
                if okT and valid(tool) then panel.tool = byPath[reflect.path(tool) or "?"] or assetId(tool) end
                out.panel = panel
            end

            local ru
            if flag(args.unlocks) then
                local okR, r = pcall(cdo, "PXRequirementRelationsUtils")
                if okR then ru = r else out.unlocksError = tostring(r) end
            end
            local started = os.clock()
            for _, e in ipairs(base) do
                local m = byFaction[e.faction or ""]
                if m then
                    if on(args, "has") then
                        local okH, has = rawCall(utils, "HasPointToAssign", ctx(), m.comp)
                        e.hasPoint = okH and has or nil
                        if not okH then e.hasPointError = tostring(has) end
                    end
                    if on(args, "score") then
                        local okS, ui = convCall(panels, "GetScoreUIData", ctx(), m.comp)
                        e.score = okS and strip(simplify(ui, 4) or ui) or { error = tostring(ui) }
                    end
                    if on(args, "tracker") then
                        local okT2, tr, trErr = pcall(reflect.get, m.comp, "ScoreTracker", { depth = 3 })
                        if okT2 and tr ~= nil then e.scoreTracker = strip(simplify(tr, 4) or tr) else e.scoreTrackerError = tostring(trErr or tr) end
                    end
                    e.dominant = out.dominant == e.faction or nil

                    local counts, open = {}, json.array()
                    for _, n in ipairs(e.nodes or {}) do
                        counts[n.state or "?"] = (counts[n.state or "?"] or 0) + 1
                        if n.state == "Open" then open[#open + 1] = n.tag end
                    end
                    e.counts = counts
                    e.assignable = open

                    if ru then
                        local insts = nodeInstances(m.comp)
                        local trunc
                        for _, n in ipairs(e.nodes or {}) do
                            if os.clock() - started > 4 then trunc = true; break end
                            local inst = insts[n.tag or ""]
                            if inst then n.grants = nodeGrants(ru, inst, args.nodeArg) end
                        end
                        if trunc then e.grantsTruncated = true end
                    end
                    if flag(args.affinities) then
                        local okA, aff = convCall(cdo("PXCommunityUtils"), "GetCommunityCoreAffinities", m.cc)
                        e.coreAffinities = okA and simplify(aff, 4) or { error = tostring(aff) }
                    end
                else
                    e.v2 = "no PXUtopiaToolComponent/PXCommunityComponent match for " .. tostring(e.faction)
                end
                out.factions[#out.factions + 1] = e
            end
            if flag(args.affinities) then
                pcall(function()
                    local nation = pickCity(args).Nation
                    local okN, st = convCall(cdo("PXAffinityUtils"), "GetNationStateDominantAffinities", nation)
                    out.stateAffinities = okN and simplify(st, 4) or { error = tostring(st) }
                end)
            end
            if flag(args.debug) then
                pcall(function()
                    local cfg = cdo("PXGameplayUtils"):GetUtopiaToolConfig()
                    if valid(cfg) then
                        out.configRef = reflect.path(cfg)
                        out.config = simplify(reflect.dump(cfg, { depth = 3, arrayLimit = 20, gameOnly = true }), 5)
                    end
                end)
            end
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- stock_caps

    -- Hub id -> resources it is expected to raise when the effect cannot be parsed [inferred from the asset names].
    local HUB_HINT = { FuelDepotHub = { "Coal", "Oil" }, MaterialsDepotHub = { "Materials" }, GoodsDepotHub = { "Goods" }, FoodDepotHub = { "Food" } }
    local RES_SET = { Coal = true, Oil = true, Food = true, Materials = true, Goods = true, Prefabs = true, Heatnotes = true, Cores = true }

    -- Walk a simplified effect table: resource names and the numbers next to them.
    local function effectResources(t, acc, depth)
        acc = acc or { names = {}, adds = {} }
        depth = depth or 0
        if type(t) ~= "table" or depth > 6 then return acc end
        for k, v in pairs(t) do
            local ks = type(k) == "string" and short(k) or nil
            if ks and RES_SET[ks] then
                acc.names[ks] = true
                if type(v) == "number" then acc.adds[ks] = v end
            end
            if type(v) == "string" and RES_SET[short(v)] then acc.names[short(v)] = true end
            if type(v) == "table" then effectResources(v, acc, depth + 1) end
        end
        return acc
    end

    local function sourceId(path)
        local id = type(path) == "string" and path:match("/([^/%.]+)%.[^/:]*:") or nil
        return id and (id:gsub("^DA_", "")) or nil
    end

    local function dumpEffect(ef)
        local ok, d = pcall(reflect.dump, ef, { depth = 2, gameOnly = true })
        if not ok then return { error = tostring(d) } end
        local s = simplify(d, 4)
        return s or json.object()
    end

    -- Stockpile effects defined on a district type asset. Path pattern measured in research/city/PXStockpileComponent.json:
    -- <DA path>:PXModifiersWithRequirements_0.PXModifier_0.PXStockpileModifierEffect_0
    local function typeEffects(typ)
        local tp = reflect.path(typ)
        if not tp then return nil end
        if effectCache[tp] then return effectCache[tp] end
        local list = json.array()
        for i = 0, 2 do
            for j = 0, 2 do
                for k = 0, 2 do
                    local p = tp .. ":PXModifiersWithRequirements_" .. i .. ".PXModifier_" .. j .. ".PXStockpileModifierEffect_" .. k
                    local ef = reflect.find(p)
                    if ef and valid(ef) and reflect.className(ef) == "PXStockpileModifierEffect" then list[#list + 1] = dumpEffect(ef) end
                end
            end
        end
        effectCache[tp] = list
        return list
    end

    def("stock_caps", {
        help = "Per limited resource: stock, effective limit (GetCityStockpileLimitOfResource) vs the StockLimits map value, % full, change per day, weeks until cap, surplus-wasted flag, and the stockpile hubs (district types with a PXStockpileModifierEffect) that raise it with canConstruct, built count and cost. Also activeSources: every source in stockpile.Modifiers. Read-only. args: city, effects=false (skip effect dumps), debug=true (raw effect dumps)",
        run = function(args)
            local city = pickCity(args)
            local su, du = cdo("PXStockpileUtils"), cdo("PXDistrictUtils")
            local out = { city = (function() local id; pcall(function() id = assetId(city.CityType) end) return id end)() }
            local resEntry = extractorFor("resources", reflect.path(city)) or {}
            local stockOf, changeOf = resEntry.stock or {}, resEntry.change or {}
            local supplyOf, demandOf = resEntry.supply or {}, resEntry.demand or {}
            local effects = args.effects ~= false

            -- Active limit sources first (they carry the amounts for built hubs).
            local sources, srcById = json.array(), {}
            if effects then
                pcall(function()
                    city.stockpile.Modifiers:ForEach(function(k, v)
                        local ef = k:get()
                        if valid(ef) then
                            local id = sourceId(reflect.path(ef)) or reflect.shortName(ef)
                            local s = srcById[id]
                            if not s then
                                s = { src = id, n = 0, effect = effects and dumpEffect(ef) or nil }
                                if flag(args.debug) then s.ref = reflect.path(ef) end
                                srcById[id] = s
                                sources[#sources + 1] = s
                            end
                            s.n = s.n + 1
                        end
                    end)
                end)
            end

            -- Hub district types.
            local hubs, hubsByRes = json.array(), {}
            pcall(function()
                local built = {}
                for _, d in ipairs(objList(city:GetDistricts())) do
                    pcall(function()
                        local id = assetId(d.DistrictType)
                        built[id] = (built[id] or 0) + 1
                    end)
                end
                for _, t in ipairs(objList(du:GetSupportedDistricts(city))) do
                    local id = assetId(t)
                    local isHub = false
                    local okH, v = pcall(function() return du:IsDistrictHub(t) end)
                    if okH then isHub = v end
                    if isHub then
                        local list = effects and typeEffects(t) or json.array()
                        local entry = { id = id, built = built[id] or 0 }
                        pcall(function() entry.name = textOf(t.IngameName) end)
                        pcall(function() entry.placeable = du:CanConstructDistrict(city, t) end)
                        local okC, cost = pcall(reflect.invoke, du, "GetDistrictConstructionCost", { city.Nation, t, true })
                        if okC and type(cost) == "table" then entry.cost = compactCost(cost) end
                        local acc = effectResources(list)
                        local res = json.array()
                        for r in pairs(acc.names) do res[#res + 1] = r end
                        table.sort(res)
                        local via = "effect"
                        if #res == 0 and HUB_HINT[id] then
                            for _, r in ipairs(HUB_HINT[id]) do res[#res + 1] = r end
                            via = "name-hint"
                        end
                        if #res > 0 then
                            entry.raises = res
                            entry.via = via
                            if next(acc.adds) ~= nil then entry.adds = acc.adds end
                            if flag(args.debug) then entry.effects = list end
                            hubs[#hubs + 1] = entry
                            for _, r in ipairs(res) do
                                hubsByRes[r] = hubsByRes[r] or {}
                                table.insert(hubsByRes[r], entry)
                            end
                        end
                    end
                end
            end)
            out.hubs = hubs
            if effects then out.activeSources = sources end

            local rows = json.array()
            pcall(function()
                city.stockpile.StockLimits:ForEach(function(k, v)
                    local res = k:get()
                    if not valid(res) then return end
                    local id = assetId(res)
                    local name = short(id)
                    local mapLimit = v:get()
                    local row = { res = name, stock = stockOf[id], mapLimit = mapLimit }
                    local okL, lim = pcall(function() return su:GetCityStockpileLimitOfResource(city, res) end)
                    row.limit = okL and lim or nil
                    local okF, full = pcall(function() return su:IsCityStockpileOfResourceFull(city, res) end)
                    row.full = okF and full or nil
                    local limit = row.limit or mapLimit
                    local stock = row.stock
                    local perDay = changeOf[id]
                    row.perDay = perDay
                    row.supply, row.demand = supplyOf[id], demandOf[id]
                    if type(stock) == "number" and type(limit) == "number" and limit > 0 then
                        row.pct = r1(stock / limit * 100)   -- not clamped: over 100 means the map value is a base, not a ceiling
                        row.atCap = stock >= limit or full == true
                        if type(perDay) == "number" and perDay > 0 and stock < limit then
                            row.weeksToCap = r1((limit - stock) / perDay / 7)
                        end
                        row.wasted = row.atCap and ((type(perDay) == "number" and perDay > 0)
                            or (type(row.supply) == "number" and type(row.demand) == "number" and row.supply > row.demand)) or false
                        if type(perDay) == "number" and perDay < 0 then row.weeksToEmpty = r1(stock / -perDay / 7) end
                    end
                    local fix = json.array()
                    for _, hub in ipairs(hubsByRes[name] or {}) do
                        fix[#fix + 1] = { hub = hub.id, placeable = hub.placeable, built = hub.built }
                    end
                    if #fix > 0 then row.raisedBy = fix end
                    rows[#rows + 1] = row
                end)
            end)
            out.resources = rows
            local flagged = json.array()
            for _, r in ipairs(rows) do if r.wasted then flagged[#flagged + 1] = r.res end end
            out.wasted = flagged
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- heat_levels

    local BAD_HEAT = { "freez", "cold", "chill" }  -- HUD names: Freezing, Very Cold, Cold, Chilly are the bad ones (research-tips.md tip 13, M)

    local function isBadHeat(name)
        local l = tostring(name or ""):lower()
        if l:find("livable", 1, true) or l:find("warm", 1, true) then return false end
        for _, w in ipairs(BAD_HEAT) do if l:find(w, 1, true) then return true end end
        return nil
    end

    local function levelInfo(lv)
        if not valid(lv) then return nil end
        local e = { id = assetId(lv) }
        pcall(function() e.name = textOf(lv.IngameName) end)
        return e
    end

    -- Heat-level assets referenced by a PXHeatLevelComponent, found by property class (the component has no dump):
    -- the first one is the current level, the rest go into `others` keyed by property name.
    local function heatLevelProps(hc, raw)
        local found, rawProps = {}, raw and {} or nil
        reflect.forEachProperty(hc:GetClass(), function(p, owner)
            if reflect.isEngineStruct(owner) then return end
            local name = reflect.propName(p)
            local t = reflect.propType(p)
            if t == "ObjectProperty" then
                local okV, v = pcall(function() return hc[name] end)
                if okV and valid(v) then
                    local cn = reflect.className(v) or ""
                    if cn == "PXHeatLevelType" or (cn:find("HeatLevel", 1, true) and not cn:find("Component", 1, true)) then
                        found[#found + 1] = { prop = name, info = levelInfo(v) }
                    end
                end
            elseif rawProps and (t == "IntProperty" or t == "FloatProperty" or t == "BoolProperty" or t == "DoubleProperty") then
                local okV, v = pcall(function() return hc[name] end)
                if okV then rawProps[name] = v end
            end
        end)
        return found, rawProps
    end

    local function pickCurrent(found)
        local best
        for _, f in ipairs(found) do
            local n = f.prop:lower()
            if n == "heatlevel" or n == "currentheatlevel" or n == "level" or n == "currentlevel" then return f end
            if not best and n:find("current", 1, true) then best = f end
        end
        return best or found[1]
    end

    def("heat_levels", {
        help = "Per-district heat level under the patch 1.3 model: current level (id and HUD name from the PXHeatLevelType asset), bad-level flag (Freezing/Very Cold/Cold/Chilly), insulated, warmedBy (HeatGiver proximity), plus alloc/need/adj joined from `heat`, and generator power/limit/headroom. Read-only. args: city, deep=true (GetHeatBalance/GetHeatNeeded/IsWastingHeat, class-checked), opt-outs, default on, for crash isolation (minimal first run: levels=false insulation=false proximity=false): levels (PXHeatLevelComponent scan), insulation, proximity, debug=true (component property dump, level asset dumps, HeatManagementConfig dump)",
        run = function(args)
            local city = pickCity(args)
            local idx = cityIndex(city)
            local hv = {}
            local okHv, heat = pcall(A.heat, { city = idx })
            if okHv and type(heat) == "table" then hv = heat end
            local alloc = {}
            for _, a in ipairs(hv.allocations or {}) do alloc[a.district or "?"] = a end

            local out = { generator = json.object(), holder = json.object() }
            local okG, g = pcall(A.generator, { city = idx })
            if okG and type(g) == "table" then
                out.generator.power, out.generator.limit = g.power, g.powerLimit
                if type(g.power) == "number" and type(g.powerLimit) == "number" then
                    out.generator.headroom = g.powerLimit - g.power
                    if g.powerLimit > 0 then out.generator.loadPct = r1(g.power / g.powerLimit * 100) end
                end
                out.generator.overdrive, out.generator.wear = g.overdriveActive, g.wear
            end
            out.holder.auto, out.holder.leftoverBatches = hv.autoAllocate, hv.unallocatedHeatBatches
            out.holder.powerAllocated, out.holder.powerNeeded = hv.totalPowerAllocated, hv.totalPowerNeeded
            pcall(function()
                local hu = cdo("PXHeatManagementUtils")
                local holderObj = city.Generator:GetOwner().PXHeatAllocationHolderComponent
                if valid(holderObj) then
                    local okR, ratio = rawCall(hu, "GetPowerToHeatLevelRatio", holderObj)
                    out.holder.powerPerLevel = okR and ratio or nil
                end
            end)

            local deep, debug = flag(args.deep), flag(args.debug)
            local hcClass = StaticFindObject("/Script/Frostpunk2.PXHeatLevelComponent")
            local rows, byLevel, bad, unreadable = json.array(), {}, json.array(), 0
            local dbgComp
            for _, d in ipairs(objList(city:GetDistricts())) do
                local row = {}
                pcall(function()
                    row.d = (assetId(d.DistrictType) or "?") .. "#" .. tostring(d.DistrictId)
                    local owner = d:GetOwner()
                    if not valid(owner) then return end
                    local a = alloc[row.d]
                    if a then row.alloc, row.need, row.adj = a.allocation, a.needed, a.adjustment end
                    if valid(hcClass) and on(args, "levels") then
                        local hc = owner:GetComponentByClass(hcClass)
                        if valid(hc) then
                            local found, rawProps = heatLevelProps(hc, debug and not dbgComp)
                            local cur = pickCurrent(found)
                            if cur and cur.info then
                                row.lv = cur.info.name or cur.info.id
                                row.id = cur.info.id
                                row.bad = isBadHeat(row.lv) or isBadHeat(row.id)
                                byLevel[row.lv or "?"] = (byLevel[row.lv or "?"] or 0) + 1
                                if row.bad then bad[#bad + 1] = row.d end
                            else
                                unreadable = unreadable + 1
                            end
                            if #found > 1 then
                                local others = json.object()
                                for _, f in ipairs(found) do if f ~= cur and f.info then others[f.prop] = f.info.name or f.info.id end end
                                row.others = others
                            end
                            if debug and not dbgComp then
                                dbgComp = { ref = reflect.path(hc), numeric = rawProps }
                                dbgComp.dump = simplify(reflect.dump(hc, { depth = 1, gameOnly = true }), 3)
                            end
                            if deep then
                                local hu = cdo("PXHeatManagementUtils")
                                local okB, b = rawCall(hu, "GetHeatBalance", hc)
                                row.balance = okB and b or ("skipped: " .. tostring(b))
                                local okN, n = rawCall(hu, "GetHeatNeeded", hc)
                                row.heatNeeded = okN and n or ("skipped: " .. tostring(n))
                                local okW, w = rawCall(hu, "IsWastingHeat", ctx(), hc)
                                row.wasting = okW and w or ("skipped: " .. tostring(w))
                            end
                        else
                            row.noHeatComp = true
                        end
                    end
                    if on(args, "insulation") then
                        local okI, ins = rawCall(cdo("PXDistrictUtils"), "IsDistrictInsulated", ctx(), d)
                        row.insulated = okI and ins or nil
                    end
                    if on(args, "proximity") then
                        local warmed = json.array()
                        for _, t in ipairs(objList(cdo("PXCellProximityUtils"):GetActorAffectedCellProximities(owner))) do
                            local n = valid(t) and (assetId(t) or ""):gsub("^CellProximityType_", "") or ""
                            if n:find("Heat", 1, true) then warmed[#warmed + 1] = n end
                        end
                        if #warmed > 0 then row.warmedBy = warmed end
                    end
                end)
                if row.d then rows[#rows + 1] = row end
            end
            out.districts = rows
            out.byLevel = byLevel
            out.bad = bad
            if unreadable > 0 then out.levelUnreadable = unreadable end
            if debug then
                out.componentDebug = dbgComp
                pcall(function()
                    local cfg = cdo("PXGameplayUtils"):GetHeatManagementConfig()
                    if valid(cfg) then
                        out.configRef = reflect.path(cfg)
                        out.config = simplify(reflect.dump(cfg, { depth = 3, arrayLimit = 12, gameOnly = true }), 5)
                    end
                end)
                local lvDump = json.object()
                for _, lv in ipairs(FindAllOf("PXHeatLevelType") or {}) do
                    if valid(lv) and not (reflect.path(lv) or ""):find("Default__", 1, true) then
                        lvDump[assetId(lv) or "?"] = simplify(reflect.dump(lv, { depth = 1, gameOnly = true }), 3)
                    end
                end
                out.levelAssets = lvDump
            end
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- health

    local function band(weeks)
        if weeks >= TH.RUNWAY_OK then return "ok" end
        if weeks >= TH.RUNWAY_WATCH then return "watch" end
        if weeks >= TH.RUNWAY_ACT then return "act" end
        return "critical"
    end

    local function tierFrom(v, crit, act, watch, higherIsWorse)
        if type(v) ~= "number" then return nil end
        if higherIsWorse then
            if v >= crit then return "critical" elseif v >= act then return "act" elseif v >= watch then return "watch" end
        else
            if v <= crit then return "critical" elseif v <= act then return "act" elseif v <= watch then return "watch" end
        end
        return "ok"
    end

    def("health", {
        help = "One-call dashboard for the play loop (reads only, composed from the extractors): verdict + reasons (critical > act > watch > ok), generator load/headroom/overdrive wear, per-resource runway weeks with bands (ok >= 20, watch 10-20, act 5-10, critical < 5), stock-at-cap flags, need deficits, problem statistics (current/target/rising), trust and tension tiers, deaths (+delta since last call), population total vs unassigned, homeless, free workforce and demand, research idle, construction, Council (weeks to next session, open flag), whiteout/temperature/next drop, quests with weeks left. Thresholds are constants at the top of economy_actions.lua. args: city",
        run = function(args)
            local city = pickCity(args)
            local ref = reflect.path(city)
            local idx = cityIndex(city)
            local errors = json.array()
            local reasons = {}   -- { sev, text }
            local function note(sev, text) reasons[#reasons + 1] = { sev = SEV[sev], text = text } end
            local function section(label, fn)
                local ok, v = pcall(fn)
                if not ok then errors[#errors + 1] = label .. ": " .. tostring(v) end
                return ok and v or nil
            end

            local res = extractorFor("resources", ref)
            local needs = extractorFor("needs", ref)
            local stats = extractorFor("statistics", ref)
            local pop = extractorFor("population", ref)
            local soc = extractorFor("society", ref)
            local cons = section("construction", function() return env.extractors.run("construction", {}) end)
            local quests = section("quests", function() return env.extractors.run("quests", {}) end)
            local weather = section("weather", function() return env.extractors.run("weather", {}) end)
            local gen = section("generator", function() return A.generator({ city = idx }) end)
            local research = section("research", function() return A.researchStatus({ city = idx }) end)
            local council = section("council", function() return A.council({ city = idx }) end)
            if not res then errors[#errors + 1] = "resources: unavailable" end

            local out = { city = (function() local id; pcall(function() id = assetId(city.CityType) end) return id end)() }
            pcall(function() out.week = A.date().week end)

            -- Generator.
            if type(gen) == "table" then
                local g = json.object()
                g.power, g.limit = gen.power, gen.powerLimit
                if type(gen.power) == "number" and type(gen.powerLimit) == "number" and gen.powerLimit > 0 then
                    g.loadPct = r1(gen.power / gen.powerLimit * 100)
                    g.headroom = gen.powerLimit - gen.power
                    local load = gen.power / gen.powerLimit
                    if load >= TH.GEN_LOAD_ACT then note("act", "generator load " .. g.loadPct .. "%")
                    elseif load >= TH.GEN_LOAD_WATCH then note("watch", "generator load " .. g.loadPct .. "%") end
                end
                g.od, g.wear = gen.overdriveActive, gen.wear
                if gen.broken then note("critical", "generator broken") end
                if type(gen.wear) == "number" then
                    if gen.wear >= TH.WEAR_CRIT then note("critical", "generator wear " .. r3(gen.wear))
                    elseif gen.wear >= TH.WEAR_ACT then note("act", "generator wear " .. r3(gen.wear))
                    elseif gen.wear >= TH.WEAR_WATCH then note("watch", "generator wear " .. r3(gen.wear)) end
                end
                out.gen = g
            end

            -- Resources: runway and cap flags. change is per game day, 7 days per week.
            if res then
                local runway, minW = json.object(), nil
                for id, delta in pairs(res.change or {}) do
                    local stock = (res.stock or {})[id]
                    if type(delta) == "number" and delta < 0 and type(stock) == "number" then
                        local weeks = r1(stock / -delta / 7)
                        local b = band(weeks)
                        if not minW or weeks < minW then minW = weeks end
                        if b ~= "ok" then
                            runway[short(id)] = weeks
                            note(b, short(id) .. " runway " .. weeks .. "w")
                        end
                    end
                end
                out.runway = runway
                out.minRunwayWeeks = minW
                local caps = json.array()
                -- Effective limit (GetCityStockpileLimitOfResource) when readable, else the StockLimits map value.
                local su = cdo("PXStockpileUtils")
                section("caps", function()
                    city.stockpile.StockLimits:ForEach(function(k, v)
                        local r = k:get()
                        if not valid(r) then return end
                        local id = assetId(r)
                        local limit = v:get()
                        local okL, eff = pcall(function() return su:GetCityStockpileLimitOfResource(city, r) end)
                        if okL and type(eff) == "number" then limit = eff end
                        local stock = (res.stock or {})[id]
                        if type(stock) == "number" and type(limit) == "number" and stock >= limit then
                            local wasted = type((res.change or {})[id]) == "number" and res.change[id] > 0
                            caps[#caps + 1] = short(id) .. (wasted and "!" or "")   -- "!" = at cap and still gaining: surplus wasted
                            if wasted then note("watch", short(id) .. " at cap, surplus wasted") end
                        end
                    end)
                end)
                table.sort(caps)
                out.caps = caps
            end

            -- Needs.
            if needs and needs.needs then
                local def_ = json.object()
                for id, n in pairs(needs.needs) do
                    if type(n) == "table" and type(n.balance) == "number" and n.balance < 0 then
                        def_[id] = n.balance
                        note("act", "need " .. id .. " deficit " .. n.balance)
                    end
                end
                out.needDeficits = def_
            end

            -- Statistics.
            local tensionCur, tensionTgt
            if stats and stats.current then
                local st = json.object()
                for k, cur in pairs(stats.current) do
                    local tgt = (stats.target or {})[k] or cur
                    if k == "Tension" then tensionCur, tensionTgt = cur, tgt end
                    if not GOOD_STATS[k] and type(cur) == "number" and type(tgt) == "number" then
                        local worrying = cur >= TH.STAT_WATCH_CUR or tgt >= TH.STAT_WATCH_TGT
                        local rising = tgt > cur + 0.5
                        if worrying or (rising and tgt >= TH.STAT_WATCH_CUR) then
                            st[k] = { r1(cur), r1(tgt), rising and "up" or nil }
                            if k ~= "Tension" then
                                if cur >= TH.STAT_CRIT_CUR then note("critical", k .. " " .. r1(cur))
                                elseif tgt >= TH.STAT_ACT_TGT or cur >= TH.STAT_ACT_CUR then note("act", k .. " " .. r1(cur) .. "->" .. r1(tgt))
                                elseif worrying then note("watch", k .. " " .. r1(cur) .. "->" .. r1(tgt)) end
                            end
                        end
                    end
                end
                out.stats = st
            end
            if tensionCur then
                local tier = tierFrom(math.max(tensionCur, tensionTgt or 0), TH.TENSION_CRIT, TH.TENSION_ACT, TH.TENSION_WATCH, true)
                out.tension = { r1(tensionCur), r1(tensionTgt), tier }
                if tier ~= "ok" then note(tier, "tension " .. r1(tensionCur) .. "->" .. r1(tensionTgt)) end
            end

            -- Society: trust, deaths, population.
            local popTotal
            if soc then
                local trust = soc.totalTrust
                if type(trust) == "number" then
                    local tier = tierFrom(trust, TH.TRUST_CRIT, TH.TRUST_ACT, TH.TRUST_WATCH, false)
                    out.trust = { r3(trust), tier }
                    if tier ~= "ok" then note(tier, "trust " .. r3(trust)) end
                end
                if type(soc.deathToll) == "number" then
                    local since = 0
                    if lastDeaths and soc.deathToll >= lastDeaths.value then since = soc.deathToll - lastDeaths.value end
                    local tick; pcall(function() tick = A.date().ticks end)
                    lastDeaths = { value = soc.deathToll, tick = tick }
                    out.deaths = { soc.deathToll, since }
                    if since > 0 then note("critical", since .. " deaths since last health call") end
                end
                popTotal = soc.population
            end
            local unassigned = pop and pop.population or nil
            out.population = { total = popTotal, unassigned = unassigned, communities = soc and soc.communitiesSize or nil }
            if pop then
                out.homeless = pop.homeless
                if type(pop.homeless) == "number" and pop.homeless >= TH.HOMELESS_WATCH then
                    local frac = (type(popTotal) == "number" and popTotal > 0) and pop.homeless / popTotal or 0
                    if frac >= TH.HOMELESS_ACT_FRAC then note("act", pop.homeless .. " homeless") else note("watch", pop.homeless .. " homeless") end
                end
            end

            -- Workforce.
            section("workforce", function()
                local wu = cdo("PXWorkforceUtils")
                local w = json.object()
                w.total = wu:GetCityTotalWorkforce(city)
                w.required = wu:GetCityRequiredWorkforce(city)
                w.free = wu:GetCityAvailableWorkforce(city)
                local okU, un = pcall(function() return wu:GetCityUnemploymentPercentage(city) end)
                if okU then w.unemployedPct = r1(un) end
                out.work = w
                if type(w.required) == "number" and type(w.total) == "number" and w.required > w.total then
                    note("watch", "workforce short " .. (w.required - w.total))
                end
            end)

            -- Research, construction.
            if type(research) == "table" then
                local idle = research.supported ~= false and research.active == true and research.anyInProgress == false
                out.research = { idle = idle, topic = research.topic, weeks = research.weeksLeft }
                if idle then note("watch", "research idle") end
            end
            if type(cons) == "table" then
                local soonest
                for _, c in ipairs(cons) do
                    if type(c.weeksLeft) == "number" and (not soonest or c.weeksLeft < soonest) then soonest = c.weeksLeft end
                end
                out.build = { n = #cons, soonest = soonest }
            end

            -- Council: same open rule as watch.ts (phase 1 or minTicks <= 0).
            if type(council) == "table" then
                local mt = council.minTicksToNextSession
                local open = council.phase == 1 or (type(mt) == "number" and mt <= 0)
                local c = { open = open, phase = council.phase }
                if type(mt) == "number" then c.weeks = r1(mt / TH.TICKS_WEEK) end
                if council.phase == 1 and type(mt) == "number" and mt > 0 then c.ambiguous = "phase 1 with ticks to next session left" end
                out.council = c
                if open then note("watch", "council session open") end
            end

            -- Weather.
            if type(weather) == "table" and not weather.error then
                local w = json.object()
                local curLevel
                if weather.current then
                    w.level, w.deg = weather.current.level, weather.current.degrees
                    curLevel = tonumber(weather.current.level)
                end
                local wo = weather.whiteout
                if type(wo) == "table" and wo.known then
                    w.whiteout = { active = wo.active, startsIn = wo.startsInWeeks, endsIn = wo.endsInWeeks }
                    if wo.active then
                        note("act", "whiteout active" .. (wo.endsInWeeks and (", ends ~" .. wo.endsInWeeks .. "w") or ""))
                    elseif type(wo.startsInWeeks) == "number" then
                        if wo.startsInWeeks <= TH.WHITEOUT_ACT_WEEKS then note("act", "whiteout in " .. wo.startsInWeeks .. "w")
                        elseif wo.startsInWeeks <= TH.WHITEOUT_WATCH_WEEKS then note("watch", "whiteout in " .. wo.startsInWeeks .. "w") end
                    end
                end
                if curLevel and type(weather.forecast) == "table" then
                    local prev = curLevel
                    for _, f in ipairs(weather.forecast) do
                        if type(f.level) == "number" then
                            if f.level > prev then
                                w.drop = { f.weeksFromNow, f.level, f.degrees }
                                if type(f.weeksFromNow) == "number" and f.weeksFromNow <= TH.DROP_WATCH_WEEKS then
                                    note("watch", "temperature drop to level " .. f.level .. " in " .. f.weeksFromNow .. "w")
                                end
                                break
                            end
                            prev = f.level
                        end
                    end
                end
                out.weather = w
            elseif weather and weather.error then
                errors[#errors + 1] = "weather: " .. tostring(weather.error)
            end

            -- Quests.
            if type(quests) == "table" then
                local q = json.array()
                for _, e in ipairs(quests) do
                    if #q < 4 then
                        local o = e.objectives and e.objectives[1]
                        q[#q + 1] = { n = tostring(e.name or e.class or "?"):sub(1, 40), w = e.weeksLeft,
                            p = o and o.progress ~= nil and (tostring(o.progress) .. "/" .. tostring(o.max)) or nil }
                    end
                    if type(e.weeksLeft) == "number" then
                        if e.weeksLeft < TH.QUEST_ACT_WEEKS then note("act", "quest " .. tostring(e.name):sub(1, 30) .. " " .. e.weeksLeft .. "w left")
                        elseif e.weeksLeft < TH.QUEST_WATCH_WEEKS then note("watch", "quest " .. tostring(e.name):sub(1, 30) .. " " .. e.weeksLeft .. "w left") end
                    end
                end
                out.quests = q
            end

            -- Verdict.
            table.sort(reasons, function(a, b) return a.sev > b.sev end)
            local top = reasons[1] and reasons[1].sev or 0
            local texts = json.array()
            for i, r in ipairs(reasons) do
                if i > TH.MAX_REASONS then break end
                texts[#texts + 1] = SEV_NAME[r.sev] .. ": " .. r.text
            end
            out.verdict = SEV_NAME[top]
            out.reasons = texts
            if #errors > 0 then out.errors = errors end

            -- Size guard: drop detail sections until the JSON fits.
            local function size() return #json.encode(out) end
            for _, key in ipairs({ "quests", "stats", "build", "work", "weather", "errors" }) do
                if size() <= TH.MAX_BYTES then break end
                out[key] = nil
                out.trimmed = out.trimmed or json.array()
                out.trimmed[#out.trimmed + 1] = key
            end
            return out
        end,
    })
end

return M
