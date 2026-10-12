-- Frostland: teams, expeditions, outposts, trails.
-- Extension module (see extensions.txt). Every game call goes through `call`, which refuses functions with FText inside
-- struct/container params (crash class, measured) and turns Lua errors into data. Rules kept here:
--   * never hold a UObject across an Instruct*/Upgrade*/Execute*/BuildTrail call: capture paths, re-find with h.fresh;
--   * in-progress explorations come from the revealed territory list (GetAllCurrentlyExploringTerritories plus
--     GetOwner chains crashed the game, measured);
--   * no SoftObject property reads (propList skips them), no struct property reads except declared plain ones.

local M = {}

local TICKS_WEEK = 1680
local TERRITORY_STATE = { hidden = 1, revealed = 2, explored = 4, charted = 8 }
local NUM = {
    Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, UInt16Property = true,
    UInt32Property = true, UInt64Property = true, FloatProperty = true, DoubleProperty = true, ByteProperty = true,
}
local OBJ = { ObjectProperty = true, ObjectPtrProperty = true }
local SKIP_OWNERS = {
    Object = true, ActorComponent = true, SceneComponent = true, PXActorComponent = true, Actor = true,
    DataAsset = true, PrimaryDataAsset = true,
}
local PLAYER_CHOICE = "/Game/Scenarios/Shared/Configs/Activity/DeactivationReasons/DA_DeactivationReason_PlayerChoice.DA_DeactivationReason_PlayerChoice"

function M.register(def, env)
    local A, R, H, json, geo = env.actions, env.reflect, env.h, env.json, env.geo
    local cdo, assetId, ctx, fresh, textOf, objList = H.cdo, H.assetId, H.ctx, H.fresh, H.textOf, H.objList

    local function flag(v) return v == true or v == "true" or v == 1 end
    local function weeks(t)
        local ticks
        pcall(function() ticks = t.ScaledTicks end)
        if type(ticks) ~= "number" then return nil end
        return math.floor(ticks / (TICKS_WEEK / 10) + 0.5) / 10
    end
    local function idOf(o)
        if type(o) == "table" and o.ref then return ((o.ref:match("%.([^%.:]+)$") or o.ref):gsub("^DA_", "")) end
        if R.isValid(o) then return assetId(o) end
        return nil
    end

    -- UFunction call with the FText guard; returns value or nil, error.
    local function call(obj, fn, ...)
        if not R.isValid(obj) then return nil, "invalid object for " .. fn end
        local f
        pcall(function() f = obj[fn] end)
        if not R.isValid(f) then return nil, "no function " .. fn end
        if #R.unsafeParams(f) > 0 then return nil, fn .. ": FText inside a struct param (crash class); not called" end
        local res = table.pack(pcall(f, obj, ...))
        if not res[1] then return nil, tostring(res[2]) end
        return res[2]
    end
    local function note(out, key, err)
        if not err then return end
        out.errors = out.errors or json.object()
        out.errors[key] = err
    end
    local function get(out, key, obj, fn, ...)
        local v, err = call(obj, fn, ...)
        note(out, key, err)
        return v
    end

    -- Declared class of a UFunction object param, so a call gets the component or its actor as the game expects.
    local function paramClassPath(obj, fn, pname)
        local f
        pcall(function() f = obj[fn] end)
        if not R.isValid(f) then return nil end
        local path
        pcall(function()
            f:ForEachProperty(function(p)
                if R.propName(p) == pname then path = R.path(p:GetPropertyClass()); return true end
            end)
        end)
        return path
    end
    local function isA(o, clsPath)
        if not clsPath then return true end
        local ok, r = pcall(function() return o:IsA(clsPath) end)
        return ok and r == true
    end
    local OUTPOST_CLASS = "/Script/Frostpunk2.PXOutpostComponent"
    local PAINT_TOOL_CLASS = "/Script/Frostpunk2.PXPaintTrailInputTool"
    local function isOutpost(o) return R.isValid(o) and isA(o, OUTPOST_CLASS) end
    -- Generic Object params get the owning actor (every measured PXTrailUtils call passed actors).
    local function asParam(o, obj, fn, pname)
        local cls = paramClassPath(obj, fn, pname)
        if not cls or cls == "/Script/CoreUObject.Object" then
            local actor = geo.actorOf(o)
            if actor then return actor end
            return nil, pname .. ": no owning actor"
        end
        if isA(o, cls) then return o end
        local actor = geo.actorOf(o)
        if actor and isA(actor, cls) then return actor end
        return nil, (pname .. " must be " .. tostring(cls))
    end

    ---------------------------------------------------------------------------
    -- Safe property discovery: scalars, object ids, Map<Object,number>, Array<Object>. Skips SoftObject and structs.
    local propCache = {}
    local function propList(obj)
        local cls
        pcall(function() cls = obj:GetClass() end)
        if not R.isValid(cls) then return {} end
        local key = R.path(cls) or "?"
        if propCache[key] then return propCache[key] end
        local list = {}
        R.forEachProperty(cls, function(p, s)
            if SKIP_OWNERS[R.shortName(s) or ""] or R.unsafeRead(p) then return end
            local t = R.propType(p)
            local e = { name = R.propName(p), t = t }
            if t == "MapProperty" then
                local okK, k = pcall(function() return p:GetKeyProp() end)
                local okV, v = pcall(function() return p:GetValueProp() end)
                if okK and okV and OBJ[R.propType(k)] and NUM[R.propType(v)] then e.kind = "objnum" else return end
            elseif t == "ArrayProperty" or t == "SetProperty" then
                local ok, inner = pcall(function() return p:GetInner() end)
                if ok and inner and OBJ[R.propType(inner)] then e.kind = "objarr" else return end
            elseif NUM[t] or t == "BoolProperty" or t == "NameProperty" or t == "EnumProperty" then
                e.kind = "scalar"
            elseif OBJ[t] then
                e.kind = "obj"
            else
                return
            end
            list[#list + 1] = e
        end)
        propCache[key] = list
        return list
    end
    local function numMap(m)
        local out = json.object()
        pcall(function()
            m:ForEach(function(k, v)
                local ko = k.get and k:get() or k
                local vo = v.get and v:get() or v
                out[idOf(ko) or tostring(ko)] = vo
            end)
        end)
        return out
    end
    local function readProps(obj, match)
        local out = json.object()
        if not R.isValid(obj) then return out end
        for _, e in ipairs(propList(obj)) do
            if not match or e.name:lower():find(match, 1, true) then
                pcall(function()
                    local v = obj[e.name]
                    if e.kind == "scalar" then
                        if type(v) == "userdata" then
                            local ok, s = pcall(function() return v:ToString() end)
                            v = ok and s or tostring(v)
                        end
                        out[e.name] = v
                    elseif e.kind == "obj" then
                        if R.isValid(v) then out[e.name] = idOf(v) end
                    elseif e.kind == "objnum" then
                        out[e.name] = numMap(v)
                    elseif e.kind == "objarr" then
                        local ids = json.array()
                        for _, x in ipairs(H.uarray(v)) do
                            if #ids < 20 and R.isValid(x) then ids[#ids + 1] = idOf(x) end
                        end
                        out[e.name] = ids
                    end
                end)
            end
        end
        return out
    end
    -- Value of the LogisticsUnits key in a Map<PXResource, number> (keys matched by asset id, never a guessed path).
    local function logisticsIn(m)
        local val, key
        pcall(function()
            m:ForEach(function(k, v)
                local ko = k.get and k:get() or k
                if (assetId(ko) or ""):find("LogisticsUnits", 1, true) then
                    val = v.get and v:get() or v
                    key = ko
                end
            end)
        end)
        return val, key
    end
    -- First LogisticsUnits value found in any Map<Object,number> property of obj: (value, propName).
    local function logisticsProp(obj)
        if not R.isValid(obj) then return nil end
        for _, e in ipairs(propList(obj)) do
            if e.kind == "objnum" then
                local m
                pcall(function() m = obj[e.name] end)
                local v = m and logisticsIn(m)
                if v ~= nil then return v, e.name end
            end
        end
        return nil
    end

    local function nameOfTerritory(t)
        if not R.isValid(t) then return nil end
        local n
        pcall(function() n = textOf(t.ExploredName) end)
        if not n then pcall(function() n = textOf(t.UnexploredName) end) end
        return n
    end
    local function weatherInfo(lv)
        if not R.isValid(lv) then return nil end
        local w = { id = assetId(lv) }
        pcall(function() w.name = lv.IngameName:ToString() end)
        pcall(function() w.level = lv.Level end)
        if type(w.level) == "number" then w.storm = w.level > 0 end
        return w
    end

    ---------------------------------------------------------------------------
    -- Territories (union of revealed/explored/charted, deduped by path)
    local function allTerritories()
        local tu = cdo("PXTerritoryUtils")
        local list, seen = {}, {}
        for _, st in ipairs({ "revealed", "explored", "charted" }) do
            local arr = call(tu, "GetTerritoriesByState", ctx(), TERRITORY_STATE[st])
            for _, t in ipairs(objList(arr)) do
                local p = R.path(t)
                if p and not seen[p] then seen[p] = true; list[#list + 1] = t end
            end
        end
        return list
    end

    local function territoryState(info)
        if info.inProgress then return "exploring" end
        if info.explored then return "explored" end
        return "unexplored"
    end

    def("frost_teams", {
        help = "Frostland teams (LogisticsUnitsResource is a flow resource: total = TargetSupply, inUse = TargetDemand, free = total - inUse), nation totals, Logistics districts, expeditions and outposts using them. args: city, breakdown=true (per economy component that supplies/demands teams)",
        run = function(args)
            local city = A.city(args)
            local nation = city.Nation
            local out = { city = assetId(city.CityType) }
            local eh = city.EconomyHolder
            local supply, res = logisticsIn(eh.TargetSupply)
            local demand = logisticsIn(eh.TargetDemand)
            out.total = supply or 0
            out.inUse = demand or 0
            out.free = out.total - out.inUse
            if res then
                local eu = cdo("PXEconomyUtils")
                out.check = {
                    citySupply = get(out, "citySupply", eu, "GetSupplyOfResource", city, res),
                    cityDemand = get(out, "cityDemand", eu, "GetDemandOfResource", city, res),
                    nationSupply = get(out, "nationSupply", eu, "GetTargetResourceSupplyInNation", nation, res),
                    nationDemand = get(out, "nationDemand", eu, "GetTargetResourceDemandInNation", nation, res),
                }
            else
                out.note = "no LogisticsUnitsResource in EconomyHolder.TargetSupply (no Logistics district yet?)"
            end
            local dl = json.array()
            for _, d in ipairs(objList(get(out, "districts", city, "GetDistricts"))) do
                local id
                pcall(function() id = assetId(d.DistrictType) end)
                if id and id:find("Logistic", 1, true) then
                    local e = { district = id .. "#" .. tostring(d.DistrictId) }
                    pcall(function()
                        local owner = d:GetOwner()
                        if R.isValid(owner) then
                            local rs = json.array()
                            for _, r in ipairs(objList(cdo("PXActivityUtils"):GetDeactivationReasons(owner))) do rs[#rs + 1] = assetId(r) end
                            e.deactivationReasons = rs
                        end
                    end)
                    dl[#dl + 1] = e
                end
            end
            out.logisticsDistricts = dl
            local exploring = json.array()
            for _, t in ipairs(objList(get(out, "revealed", cdo("PXTerritoryUtils"), "GetTerritoriesByState", ctx(), TERRITORY_STATE.revealed))) do
                local info = H.territoryInfo(t, nation, nil)
                if info.inProgress then exploring[#exploring + 1] = { name = info.name, progress = info.progress } end
            end
            out.expeditions = exploring
            out.constructedOutposts = #objList(get(out, "outposts", cdo("PXOutpostUtils"), "GetAllConstructedOutposts", ctx(), nation))
            if flag(args.breakdown) then
                local rows = json.array()
                for _, c in ipairs(H.uarray(eh.Components)) do
                    if R.isValid(c) then
                        local v, prop = logisticsProp(c)
                        if v ~= nil and v ~= 0 then
                            local p = R.path(c) or ""
                            local actor = p:match("PersistentLevel%.([^%.]+)%.") or p
                            rows[#rows + 1] = { actor = actor:gsub("_C?_?%d+$", ""), prop = prop, value = v, ref = p }
                        end
                    end
                end
                out.byComponent = rows
            end
            return out
        end,
    })

    def("explorations", {
        help = "Every revealed/explored territory: name, state (unexplored|exploring|explored), charted, progress and weeksLeft for running expeditions, explorationWeeks, preparationWeeks, difficulty and baseDifficulty, possibleResources, neighbours, distance, sites. args: state (unexplored|exploring|explored), name (substring), limit=40, teams=true (search exploration props for a LogisticsUnits cost), weather=true (storm level over the territory; new call chain), debug=true (raw exploration props)",
        run = function(args)
            local city = A.city(args)
            local nation = city.Nation
            local center = geo.location(city)
            local tu = cdo("PXTerritoryUtils")
            local wantState = args.state and tostring(args.state):lower() or nil
            local wantName = args.name and tostring(args.name):lower() or nil
            local rows = {}
            for _, t in ipairs(allTerritories()) do
                local e = H.territoryInfo(t, nation, center)
                e.state = territoryState(e)
                local keep = (not wantState or e.state == wantState) and (not wantName or (e.name or ""):lower():find(wantName, 1, true))
                if keep then
                    e.difficulty = nil
                    local d = get(e, "difficulty", tu, "GetTerritoryDifficulty", ctx(), t)
                    if R.isValid(d) then e.difficulty = assetId(d) end
                    local bd = get(e, "baseDifficulty", tu, "GetTerritoryBaseDifficulty", ctx(), t)
                    if R.isValid(bd) then e.baseDifficulty = assetId(bd) end
                    local ex = get(e, "exploration", t, "GetExplorationComponent", nation)
                    if R.isValid(ex) then
                        e.explorationWeeks = weeks(get(e, "explorationTime", tu, "GetTerritoryExplorationTime", ctx(), ex))
                        if e.inProgress and e.explorationWeeks and e.progress then
                            e.weeksLeft = math.floor(e.explorationWeeks * (1 - e.progress) * 10 + 0.5) / 10 -- inferred
                        end
                        if flag(args.teams) or flag(args.debug) then
                            -- The exploration component itself holds no cost props (measured: components, Progress,
                            -- State); its EconomyComponent (PXEconomyComponent Base/TotalResources maps) is the
                            -- candidate for the LogisticsUnits demand (inferred: explore raised inUse by 10, measured).
                            local v, prop
                            local eco
                            pcall(function() eco = ex.EconomyComponent end)
                            if R.isValid(eco) then
                                v, prop = logisticsProp(eco)
                                if v ~= nil then e.teamsRequired, e.teamsRequiredFrom = v, "exploration.EconomyComponent." .. prop end
                                if flag(args.debug) then e.explorationEconomy = readProps(eco) end
                            end
                            if v == nil then
                                v, prop = logisticsProp(ex)
                                if v ~= nil then e.teamsRequired, e.teamsRequiredFrom = v, "exploration." .. prop end
                            end
                            if v == nil then
                                local tt
                                pcall(function() tt = t.TerritoryType end)
                                v, prop = logisticsProp(tt)
                                if v ~= nil then e.teamsRequired, e.teamsRequiredFrom = v, "territoryType." .. prop end
                            end
                        end
                        if flag(args.debug) then e.explorationProps = readProps(ex) end
                    end
                    if e.state == "unexplored" then
                        e.preparationWeeks = weeks(get(e, "preparationTime", tu, "GetExplorationPreparationTime", ctx(), t, city))
                    end
                    local resList = json.array()
                    for _, r in ipairs(objList(get(e, "possibleResources", tu, "GetTerritoryPossibleResources", ctx(), nation, t))) do
                        resList[#resList + 1] = assetId(r)
                    end
                    e.possibleResources = resList
                    local nb = json.array()
                    for _, n in ipairs(objList(get(e, "neighbours", t, "GetNeighborTerritories"))) do
                        -- Unnamed entries (printed as "PXTerritory", measured) are skipped.
                        local nm = nameOfTerritory(n)
                        if nm then nb[#nb + 1] = nm end
                    end
                    e.neighbours = nb
                    if flag(args.weather) then
                        local owner = get(e, "owner", t, "GetOwner")
                        if R.isValid(owner) then
                            e.weather = weatherInfo(get(e, "weather", cdo("PXWeatherUtils"), "GetWeatherLevelForActor", owner))
                        end
                    end
                    rows[#rows + 1] = e
                end
            end
            local rank = { exploring = 0, unexplored = 1, explored = 2 }
            table.sort(rows, function(a, b)
                if rank[a.state] ~= rank[b.state] then return rank[a.state] < rank[b.state] end
                return (a.d or 1e18) < (b.d or 1e18)
            end)
            local out = json.array()
            for i = 1, math.min(tonumber(args.limit) or 40, #rows) do out[#out + 1] = rows[i] end
            local counts = json.object()
            for _, r in ipairs(rows) do counts[r.state] = (counts[r.state] or 0) + 1 end
            return {
                counts = counts, territories = out,
                skipped = { researchedRequirements = "GetResearchedTerritoryRequirements returns an FText array (crash class)",
                    canExplore = "CanCityExploreTerritory returns PXCheckResult (FText)" },
            }
        end,
    })

    -- In-progress expedition by name (from the revealed list, filtered on inProgress).
    local function runningExpedition(args, nation)
        local tu = cdo("PXTerritoryUtils")
        local want = args.territory and tostring(args.territory):lower() or nil
        local found = {}
        for _, t in ipairs(objList(call(tu, "GetTerritoriesByState", ctx(), TERRITORY_STATE.revealed))) do
            local info = H.territoryInfo(t, nation, nil)
            if info.inProgress and (not want or (info.name or ""):lower():find(want, 1, true)) then
                found[#found + 1] = { t = t, info = info }
            end
        end
        if #found == 0 then error("no running expedition" .. (want and (" matching " .. want) or "") .. " (see fp2 explorations state=exploring)", 0) end
        if #found > 1 then
            local names = {}
            for _, f in ipairs(found) do names[#names + 1] = f.info.name or "?" end
            error("several expeditions running (" .. table.concat(names, ", ") .. "); pass territory=<name>", 0)
        end
        return found[1].t, found[1].info
    end

    def("explore_stop", {
        help = "Recall a running expedition (PXInstructionUtils.InstructStopTerritoryExploration on the territory's exploration component). Progress is lost (research note); no refund getter exists. args: territory (name substring; optional when one runs), dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("explore_stop")
            local city = A.city(args)
            local nation = city.Nation
            local t, info = runningExpedition(args, nation)
            local out = { territory = info.name, ref = info.ref, progress = info.progress }
            local ex = get(out, "exploration", t, "GetExplorationComponent", nation)
            if not R.isValid(ex) then error("territory has no exploration component for this nation", 0) end
            out.explorationWeeks = weeks(get(out, "explorationTime", cdo("PXTerritoryUtils"), "GetTerritoryExplorationTime", ctx(), ex))
            out.refund = "unknown (no getter); recalling forfeits progress"
            if args.dryRun then return out end
            local exPath = R.path(ex)
            local iu = cdo("PXInstructionUtils")
            if not R.isValid(ex) then error("exploration became invalid before the call", 0) end
            iu:InstructStopTerritoryExploration(ctx(), ex)
            ex, t = nil, nil -- never touch these after the instruction
            local now = fresh(exPath)
            if now then
                pcall(function() out.inProgressNow = now:IsExplorationInProgress() end)
            else
                out.inProgressNow = "exploration object gone"
            end
            out.next = "verify with: fp2 explorations state=exploring; fp2 frost_teams"
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- Outposts
    local function outpostActions(ty)
        local acts = {}
        if not R.isValid(ty) then return acts end
        for _, e in ipairs(propList(ty)) do
            if e.name:lower():find("action", 1, true) and (e.kind == "obj" or e.kind == "objarr") then
                pcall(function()
                    local v = ty[e.name]
                    local list = e.kind == "obj" and { v } or H.uarray(v)
                    for _, a in ipairs(list) do
                        if R.isValid(a) then acts[#acts + 1] = { obj = a, id = idOf(a), class = R.className(a), from = e.name } end
                    end
                end)
            end
        end
        return acts
    end

    local function outpostInfo(o, nation, cityByPath, opts)
        local ou, tu = cdo("PXOutpostUtils"), cdo("PXTrailUtils")
        local e = { ref = R.path(o) }
        local ty
        pcall(function() ty = o.Type end)
        if R.isValid(ty) then
            e.type = assetId(ty)
            e.name = textOf(ty.IngameName)
        end
        local terr = get(e, "territory", ou, "GetOutpostTerritory", ctx(), o)
        e.territory = nameOfTerritory(terr)
        local mr = get(e, "mainResource", ou, "GetOutpostMainResource", o)
        if R.isValid(mr) then e.mainResource = assetId(mr) end
        local dt = get(e, "depositType", ou, "GetOutpostDepositType", o)
        if R.isValid(dt) then e.depositType = assetId(dt) end
        e.permanent = get(e, "permanent", ou, "IsPermamentOutpost", o)
        e.depleted = get(e, "depleted", ou, "IsOutpostDepleted", o)
        e.depositLeft = get(e, "depositLeft", ou, "GetOutpostCurrentDepositAmount", o)
        e.extractionWeeksLeft = weeks(get(e, "extractionTime", ou, "GetOutpostTimeToFinishExtraction", o))
        local ec
        pcall(function() ec = o.EconomyComponent end)
        if R.isValid(ec) then
            local eco = readProps(ec)
            for k, v in pairs(eco) do
                if type(v) == "table" and next(v) ~= nil then
                    for res, n in pairs(v) do
                        if res:find("LogisticsUnits", 1, true) then e.teams = n; e.teamsFrom = "economy." .. k end
                    end
                end
            end
            e.economy = eco -- maps by property name; output rate is the main resource in a supply map (inferred)
        end
        local owner = get(e, "owner", o, "GetOwner")
        if R.isValid(owner) then
            local rs = json.array()
            for _, r in ipairs(objList(get(e, "deactivation", cdo("PXActivityUtils"), "GetDeactivationReasons", owner))) do
                rs[#rs + 1] = (assetId(r) or "?"):gsub("^DeactivationReason_", "")
            end
            e.deactivationReasons = rs
            e.active = #rs == 0
        end
        local cc = get(e, "connectedCity", ou, "GetOutpostConnectedCity", o)
        if R.isValid(cc) then
            pcall(function() e.connectedCity = assetId(cc.CityType) end)
            local cOwner = get(e, "cityOwner", cc, "GetOwner")
            if R.isValid(owner) and R.isValid(cOwner) then
                local src = asParam(owner, tu, "GetActorsConnectedTrailType", "Source")
                local tgt = asParam(cOwner, tu, "GetActorsConnectedTrailType", "Target")
                if src and tgt then
                    local tt = get(e, "trailType", tu, "GetActorsConnectedTrailType", ctx(), src, tgt)
                    if R.isValid(tt) then e.trailType = assetId(tt) end
                end
            end
        end
        pcall(function() e.connected = R.isValid(o.CurrentConnection) end)
        local up
        pcall(function() up = o.UpgradedOutpostType end)
        if not R.isValid(up) and R.isValid(ty) then pcall(function() up = ty.UpgradedOutpostType end) end
        if R.isValid(up) then e.upgradesTo = assetId(up) end
        e.canShowUpgrade = get(e, "canShowUpgrade", ou, "CanShowOutpostUpgrade", ctx(), o, nation)
        e.upgradeProgress = get(e, "upgradeProgress", ou, "GetOutpostUpgradeProgress", o)
        pcall(function() e.upgrading = R.isValid(o.UpgradeOperation) end)
        local wt
        pcall(function() wt = o.weatherTarget end)
        if R.isValid(wt) then e.weather = weatherInfo(get(e, "weather", wt, "GetCurrentWeatherLevel")) end
        local ch
        pcall(function() ch = o.CommunitiesHolder end)
        if R.isValid(ch) then e.population = get(e, "population", ch, "GetTotalCommunitiesSize") end
        pcall(function() e.cellIndex = o.CellIndex end)
        local acts = json.array()
        for _, a in ipairs(outpostActions(ty)) do acts[#acts + 1] = a.id end
        e.actions = acts
        if opts and opts.debug and R.isValid(ty) then e.typeProps = readProps(ty) end
        return e
    end

    local function constructedOutposts(nation)
        local list = {}
        for _, o in ipairs(objList(call(cdo("PXOutpostUtils"), "GetAllConstructedOutposts", ctx(), nation))) do
            if isOutpost(o) then list[#list + 1] = o end
        end
        return list
    end

    -- Built outpost by ref, or by type/territory substring among GetAllConstructedOutposts (no FindAllOf walk).
    local function resolveBuilt(args, nation)
        if args.ref then
            local o = R.find(tostring(args.ref))
            if not isOutpost(o) then error("ref is not a live PXOutpostComponent", 0) end
            return o
        end
        local wantType = args.type and tostring(args.type):lower() or nil
        local wantTerr = args.territory and tostring(args.territory):lower() or nil
        if not wantType and not wantTerr then error("pass ref, type or territory (see fp2 outposts)", 0) end
        for _, o in ipairs(constructedOutposts(nation)) do
            local ty, terr
            pcall(function() ty = assetId(o.Type) end)
            terr = nameOfTerritory(call(cdo("PXOutpostUtils"), "GetOutpostTerritory", ctx(), o))
            if (not wantType or (ty or ""):lower():find(wantType, 1, true)) and (not wantTerr or (terr or ""):lower():find(wantTerr, 1, true)) then
                return o
            end
        end
        error("no constructed outpost matching type=" .. tostring(wantType) .. " territory=" .. tostring(wantTerr), 0)
    end

    def("outposts", {
        help = "Constructed outposts: type, name, territory, main resource, deposit left, depleted, extractionWeeksLeft, permanent, active and deactivation reasons, teams (LogisticsUnits demand), economy maps, connected city and trail type, upgradesTo, canShowUpgrade, upgradeProgress, storm level over it, population, cellIndex, type actions. args: city, territory, type, limit=40, debug=true (outpost type props)",
        run = function(args)
            local city = A.city(args)
            local nation = city.Nation
            local wantType = args.type and tostring(args.type):lower() or nil
            local wantTerr = args.territory and tostring(args.territory):lower() or nil
            local out = json.array()
            local all = constructedOutposts(nation)
            for _, o in ipairs(all) do
                if #out < (tonumber(args.limit) or 40) then
                    local e = outpostInfo(o, nation, nil, { debug = flag(args.debug) })
                    if (not wantType or (e.type or ""):lower():find(wantType, 1, true)) and (not wantTerr or (e.territory or ""):lower():find(wantTerr, 1, true)) then
                        out[#out + 1] = e
                    end
                end
            end
            return {
                total = #all, outposts = out,
                skipped = { canUpgrade = "CanUpgradeOutpost/CanExecuteOutpostAction/CanActivateOutpost return PXCheckResult (FText)",
                    upgradeCost = "GetSettlementUpgradeTooltipInfo out-param holds FText", deposits = "GetOutpostDeposits map not read (asset container)" },
            }
        end,
    })

    local function playerChoiceReason()
        local r = StaticFindObject(PLAYER_CHOICE)
        if R.isValid(r) then return r end
        for _, x in ipairs(FindAllOf("PXDeactivationReasonType") or {}) do
            if (R.shortName(x) or "") == "DA_DeactivationReason_PlayerChoice" then return x end
        end
        error("PlayerChoice deactivation reason not found", 0)
    end

    def("outpost_active", {
        help = "Activate or deactivate a built outpost (InstructActivateLogic / InstructDeactivateLogic with the PlayerChoice reason, the measured district path). Deactivating frees its teams (inferred). args: ref | type | territory, active=true|false, dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("outpost_active")
            local city = A.city(args)
            local o = resolveBuilt(args, city.Nation)
            local out = { ref = R.path(o) }
            pcall(function() out.type = assetId(o.Type) end)
            local owner = get(out, "owner", o, "GetOwner")
            if not R.isValid(owner) then error("outpost has no valid owner actor", 0) end
            local before = json.array()
            for _, r in ipairs(objList(call(cdo("PXActivityUtils"), "GetDeactivationReasons", owner))) do before[#before + 1] = assetId(r) end
            out.reasonsBefore = before
            out.requested = args.active ~= false and args.active ~= "false"
            if args.dryRun then return out end
            local reason = playerChoiceReason()
            local ownerPath = R.path(owner)
            if out.requested then
                cdo("PXInstructionUtils"):InstructActivateLogic(ctx(), owner)
            else
                cdo("PXInstructionUtils"):InstructDeactivateLogic(ctx(), owner, reason)
            end
            owner, o = nil, nil
            local now = fresh(ownerPath)
            if now then
                local after = json.array()
                for _, r in ipairs(objList(call(cdo("PXActivityUtils"), "GetDeactivationReasons", now))) do after[#after + 1] = assetId(r) end
                out.reasonsNow = after
            end
            return out
        end,
    })

    def("outpost_action", {
        help = "List or run an outpost type's actions (PXOutpostUtils.ExecuteOutpostAction with the Leader origin). The game check CanExecuteOutpostAction returns FText and is not called: the game validates. args: ref | type | territory, action (id substring; omit to list), dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("outpost_action")
            local city = A.city(args)
            local o = resolveBuilt(args, city.Nation)
            local ty
            pcall(function() ty = o.Type end)
            local out = { ref = R.path(o), type = R.isValid(ty) and assetId(ty) or nil }
            local acts = outpostActions(ty)
            local list = json.array()
            for _, a in ipairs(acts) do list[#list + 1] = { id = a.id, class = a.class, from = a.from, props = flag(args.debug) and readProps(a.obj) or nil } end
            out.actions = list
            if not args.action then
                out.note = #acts == 0 and "no action-like properties on the outpost type; describe PXOutpostType to find the action list" or "pass action=<id>"
                return out
            end
            local want = tostring(args.action):lower()
            local act
            for _, a in ipairs(acts) do if (a.id or ""):lower():find(want, 1, true) then act = a.obj; out.action = a.id; break end end
            if not R.isValid(act) then error("no action matching " .. want, 0) end
            local ou = cdo("PXOutpostUtils")
            local cls = paramClassPath(ou, "ExecuteOutpostAction", "Action")
            out.actionParamClass = cls
            if not isA(act, cls) then error("action " .. tostring(out.action) .. " is not a " .. tostring(cls), 0) end
            if args.dryRun then return out end
            local origin = A.leaderOrigin()
            if not (R.isValid(o) and R.isValid(act)) then error("outpost or action invalid before the call", 0) end
            ou:ExecuteOutpostAction(ctx(), o, act, origin)
            o, act = nil, nil
            out.next = "verify with: fp2 outposts ref=" .. tostring(out.ref) .. " (and fp2 frost_teams)"
            return out
        end,
    })

    def("outpost_upgrade", {
        help = "Upgrade a built outpost to its UpgradedOutpostType (PXOutpostUtils.UpgradeOutpost, Leader origin). Refused unless CanShowOutpostUpgrade is true and no upgrade runs. Cost is not readable (FText); compare extract name=resources before/after. args: ref | type | territory, dryRun, debug=true (upgrade type props)",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("outpost_upgrade")
            local city = A.city(args)
            local nation = city.Nation
            local o = resolveBuilt(args, nation)
            local ou = cdo("PXOutpostUtils")
            local out = { ref = R.path(o) }
            local ty, up
            pcall(function() ty = o.Type end)
            if R.isValid(ty) then out.type = assetId(ty) end
            pcall(function() up = o.UpgradedOutpostType end)
            if not R.isValid(up) and R.isValid(ty) then pcall(function() up = ty.UpgradedOutpostType end) end
            if not R.isValid(up) then error("outpost has no upgrade type", 0) end
            out.upgradesTo = assetId(up)
            pcall(function() out.upgradeName = textOf(up.IngameName) end)
            out.canShowUpgrade = get(out, "canShowUpgrade", ou, "CanShowOutpostUpgrade", ctx(), o, nation)
            out.upgradeProgress = get(out, "upgradeProgress", ou, "GetOutpostUpgradeProgress", o)
            pcall(function() out.upgrading = R.isValid(o.UpgradeOperation) end)
            if flag(args.debug) then out.upgradeTypeProps = readProps(up) end
            if args.dryRun then return out end
            if out.canShowUpgrade ~= true then error("upgrade not offered (CanShowOutpostUpgrade=" .. tostring(out.canShowUpgrade) .. "); research Settlement Heating/Skyways first", 0) end
            if out.upgrading then error("an upgrade is already running", 0) end
            local origin = A.leaderOrigin()
            if not (R.isValid(o) and R.isValid(up)) then error("outpost or upgrade type invalid before the call", 0) end
            ou:UpgradeOutpost(ctx(), o, up, origin)
            o, ty = nil, nil
            local now = fresh(out.ref)
            if now then pcall(function() out.upgradingNow = R.isValid(now.UpgradeOperation) end) end
            out.next = "verify: fp2 outposts ref=<ref> (upgradeProgress), fp2 extract name=resources (cost charged?)"
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- Trails
    local function fnObject(cls, fn)
        local f = StaticFindObject("/Script/Frostpunk2." .. cls .. ":" .. fn)
        if R.isValid(f) then return f end
        local d = StaticFindObject("/Script/Frostpunk2.Default__" .. cls)
        if R.isValid(d) then pcall(function() f = d[fn] end) end
        if R.isValid(f) then return f end
        return nil
    end
    local function propSchema(p, depth)
        if not p then return nil end
        depth = depth or 0
        local t = R.propType(p)
        local e = { type = R.paramTypeName(p) }
        if R.unsafeRead(p) then e.soft = true end
        if (t == "ArrayProperty" or t == "SetProperty") and depth < 3 then
            local ok, inner = pcall(function() return p:GetInner() end)
            if ok and inner then e.inner = propSchema(inner, depth + 1) end
        elseif t == "StructProperty" and depth < 3 then
            local fields = json.array()
            pcall(function()
                R.forEachProperty(p:GetStruct(), function(f)
                    fields[#fields + 1] = R.propName(f) .. ":" .. R.paramTypeName(f) .. (R.unsafeRead(f) and " (soft)" or "")
                end)
            end)
            e.fields = fields
        end
        return e
    end
    local function fnParamSchema(cls, fn, pname)
        local f = fnObject(cls, fn)
        if not f then return { missing = cls .. "." .. fn } end
        local found
        pcall(function() f:ForEachProperty(function(p) if R.propName(p) == pname then found = p; return true end end) end)
        if not found then return { missing = cls .. "." .. fn .. "." .. pname } end
        return propSchema(found)
    end
    local function classPropSchema(cls, pname)
        local c = StaticFindObject("/Script/Frostpunk2." .. cls)
        if not R.isValid(c) then return { missing = cls } end
        local p = R.findProperty(c, pname)
        if not p then return { missing = cls .. "." .. pname } end
        return propSchema(p)
    end
    local function trailCellsSchema()
        return {
            buildTrail = fnParamSchema("PXInstructionUtils", "BuildTrail", "trailCells"),
            createTrail = fnParamSchema("PXTrailSubsystem", "CreateTrail", "trailCells"),
            trailComponentPath = classPropSchema("PXTrailComponent", "Path"),
            tryStartPainting = fnParamSchema("PXPaintTrailInputTool", "TryStartPainting", "worldPos"),
        }
    end
    local function innerType(schema)
        return schema and schema.inner and schema.inner.type or nil
    end
    local function plainScheme(s)
        -- Element types whose values are safe to read back: ints, names, or structs of plain numeric fields.
        if not s or not s.inner or s.inner.soft then return false end
        local t = s.inner.type or ""
        if t == "Int" or t == "Name" then return true end
        if t:find("^Struct<") and not t:find("!text", 1, true) and s.inner.fields then
            for _, f in ipairs(s.inner.fields) do
                if f:find("soft", 1, true) or f:find("!text", 1, true) or f:find(":Text", 1, true) or f:find(":Object", 1, true) then return false end
            end
            return true
        end
        return false
    end

    local function trailTypes(nation, city)
        local tu = cdo("PXTrailUtils")
        local out = json.array()
        for _, t in ipairs(objList(call(tu, "GetAvailableTrailTypes", ctx(), nation))) do
            local e = { id = assetId(t), ref = R.path(t) }
            pcall(function() e.name = textOf(t.IngameName) end)
            e.available = get(e, "available", tu, "IsTrailTypeAvailable", ctx(), nation, t)
            e.capacity = get(e, "capacity", tu, "GetTrailTypeCapacity", ctx(), t)
            e.weeksFor1Chunk = weeks(get(e, "duration1", tu, "GetTrailTypeConstructionDuration", t, 1))
            e.weeksFor5Chunks = weeks(get(e, "duration5", tu, "GetTrailTypeConstructionDuration", t, 5))
            e.costProps = readProps(t, "cost")
            out[#out + 1] = e
        end
        return out
    end
    local function findTrailType(nation, want)
        local list = objList(call(cdo("PXTrailUtils"), "GetAvailableTrailTypes", ctx(), nation))
        for _, t in ipairs(list) do
            if not want or (assetId(t) or ""):lower():find(tostring(want):lower(), 1, true) then return t end
        end
        error("no available trail type" .. (want and (" matching " .. tostring(want)) or ""), 0)
    end
    local function liveTrails(center)
        local out = json.array()
        for _, tc in ipairs(FindAllOf("PXTrailComponent") or {}) do
            if R.isValid(tc) and not (R.path(tc) or ""):find("Default__", 1, true) then
                local e = { ref = R.path(tc) }
                pcall(function() e.type = assetId(tc.trailType) end)
                pcall(function() e.progress = tc.Progress end)
                pcall(function() local n = 0; tc.Path:ForEach(function() n = n + 1 end); e.pathLength = n end)
                local loc = geo.location(tc)
                if loc then
                    e.x, e.y = math.floor(loc.X), math.floor(loc.Y)
                    if center then e.d = math.floor(math.sqrt((loc.X - center.X) ^ 2 + (loc.Y - center.Y) ^ 2)) end
                end
                out[#out + 1] = e
            end
        end
        return out
    end
    local function endpoints(from, debug)
        local list = {}
        for _, c in ipairs(FindAllOf("PXTrailEndpointComponent") or {}) do
            if R.isValid(c) and not (R.path(c) or ""):find("Default__", 1, true) then
                local e = { ref = R.path(c) }
                local loc = geo.location(c)
                if loc then
                    e.x, e.y, e.z = math.floor(loc.X), math.floor(loc.Y), math.floor(loc.Z)
                    if from then e.d = math.floor(math.sqrt((loc.X - from.X) ^ 2 + (loc.Y - from.Y) ^ 2)) end
                end
                if debug then e.props = readProps(c) end
                list[#list + 1] = e
            end
        end
        table.sort(list, function(a, b) return (a.d or 1e18) < (b.d or 1e18) end)
        return list
    end

    def("trails", {
        help = "Trail types (available, capacity, build weeks for 1 and 5 chunks, cost-like props), live trails (type, progress, path length, position), trails under construction, whether the city has any connection, per-outpost trail links, nearest trail endpoints, and the trailCells schema. args: city, debug=true (endpoint props). Cost getters return FText and are skipped.",
        run = function(args)
            local city = A.city(args)
            local nation = city.Nation
            local center = geo.location(city)
            local tu = cdo("PXTrailUtils")
            local out = { types = trailTypes(nation, city), trails = liveTrails(center) }
            out.constructing = #objList(get(out, "constructing", tu, "GetAllTrailConstructing", ctx()))
            out.cityHasConnection = get(out, "hasAnyConnection", tu, "HasAnyConnection", ctx(), city)
            local links = json.array()
            local cOwner = get(out, "cityOwner", city, "GetOwner")
            for _, o in ipairs(constructedOutposts(nation)) do
                local e = { ref = R.path(o) }
                pcall(function() e.type = assetId(o.Type) end)
                local owner = call(o, "GetOwner")
                if R.isValid(owner) and R.isValid(cOwner) then
                    local src = asParam(owner, tu, "AreActorsConnectedWithTrail", "Source")
                    local tgt = asParam(cOwner, tu, "AreActorsConnectedWithTrail", "Target")
                    if src and tgt then
                        e.connected = get(e, "connected", tu, "AreActorsConnectedWithTrail", ctx(), src, tgt)
                        local tt = get(e, "trailType", tu, "GetActorsConnectedTrailType", ctx(), src, tgt)
                        if R.isValid(tt) then e.trailType = assetId(tt) end
                    end
                end
                links[#links + 1] = e
            end
            out.outpostLinks = links
            local eps = endpoints(center, flag(args.debug))
            local near = json.array()
            for i = 1, math.min(8, #eps) do near[#near + 1] = eps[i] end
            out.endpoints = near
            out.endpointCount = #eps
            out.trailCellsSchema = trailCellsSchema()
            out.skipped = { cost = "GetTrailTypeConstructionCost / GetTrailCost / CanCityAffordTrailCreation hold FText" }
            return out
        end,
    })

    -- Target of a trail: a PXOutpostComponent by ref (built or not), or a built outpost by type/territory.
    local function trailTarget(args, nation)
        if args.ref then
            local o = R.find(tostring(args.ref))
            if not R.isValid(o) then error("ref not found", 0) end
            return o
        end
        return resolveBuilt(args, nation)
    end

    -- Vector returns: GetNearestTrailpointVector came back as denormal garbage (X 4e-316, measured), so every
    -- returned vector passes this sanity check before use.
    local function saneVec(v)
        local x, y, z
        pcall(function() x, y, z = v.X, v.Y, v.Z end)
        local function ok(n) return type(n) == "number" and n == n and math.abs(n) < 1e9 and (n == 0 or math.abs(n) > 1e-3) end
        if ok(x) and ok(y) and (z == nil or ok(z)) then return { X = x, Y = y, Z = z or 0 } end
        return nil
    end

    -- Frostland dot grid (PXFrostlandDetailsSubsystem: GridCellSize, WorldSize, *ByDot maps, CityToCellMap; dumps measured).
    -- Hypothesis (inferred): trail cells and PXOutpostComponent.CellIndex are dot indices on a square grid of
    -- GridCellSize over WorldSize, index = row * cols + col. Calibrated from (index, world position) pairs.
    local function mapKinds(cls, name)
        local p = R.isValid(cls) and R.findProperty(cls, name) or nil
        if not p then return nil end
        local okK, k = pcall(function() return p:GetKeyProp() end)
        local okV, v = pcall(function() return p:GetValueProp() end)
        return okK and R.propType(k) or "?", okV and R.propType(v) or "?"
    end
    local function frostGrid(target, city)
        local g = {}
        local sub = FindFirstOf("PXFrostlandDetailsSubsystem")
        if not R.isValid(sub) then g.missing = "PXFrostlandDetailsSubsystem"; return g end
        local cls = StaticFindObject("/Script/Frostpunk2.PXFrostlandDetailsSubsystem")
        pcall(function() g.cellSize = sub.GridCellSize end)
        local ws = R.isValid(cls) and propSchema(R.findProperty(cls, "WorldSize")) or nil
        g.worldSizeSchema = ws
        local plain = ws and ws.fields and #ws.fields > 0
        for _, f in ipairs(ws and ws.fields or {}) do
            if f:find("soft", 1, true) or f:find("!text", 1, true) or f:find(":Object", 1, true) or f:find(":Text", 1, true) then plain = false end
        end
        if plain then pcall(function() local v = sub.WorldSize; g.worldSize = { X = v.X, Y = v.Y } end) end
        local tPath, tOwner = R.path(target), R.path(geo.actorOf(target))
        local cPath, cOwner = R.path(city), R.path(geo.actorOf(city))
        local function matches(o, p1, p2)
            local p = R.path(o)
            return p ~= nil and (p == p1 or p == p2)
        end
        -- OutpostByDot: Map<Int, Object> expected; read only when the key is Int and the value a hard object ref.
        local kk, vk = mapKinds(cls, "OutpostByDot")
        g.outpostByDotKinds = tostring(kk) .. "->" .. tostring(vk)
        if kk == "IntProperty" and OBJ[vk or ""] then
            local n = 0
            pcall(function()
                sub.OutpostByDot:ForEach(function(k, v)
                    n = n + 1
                    local dot = k.get and k:get() or k
                    local o = v.get and v:get() or v
                    if R.isValid(o) and matches(o, tPath, tOwner) then g.targetDot = dot end
                end)
            end)
            g.outpostDots = n
        end
        kk, vk = mapKinds(cls, "CityToCellMap")
        g.cityToCellKinds = tostring(kk) .. "->" .. tostring(vk)
        if OBJ[kk or ""] and NUM[vk or ""] then
            pcall(function()
                sub.CityToCellMap:ForEach(function(k, v)
                    local o = k.get and k:get() or k
                    local cell = v.get and v:get() or v
                    if R.isValid(o) and matches(o, cPath, cOwner) then g.cityCell = cell end
                end)
            end)
        end
        g.territoryIndicesSchema = classPropSchema("PXTerritoryComponent", "Indices")
        g.unitPathSchema = classPropSchema("PXTerritoryExplorationComponent", "UnitPath")
        return g
    end
    -- Row-major and column-major calibrations from (index, location) pairs; consistent = origins agree within a cell.
    local function calibrate(g, list)
        local size, wsz = g.cellSize, g.worldSize
        if type(size) ~= "number" or size <= 0 or not wsz or type(wsz.X) ~= "number" then return nil end
        local cols, rows = math.floor(wsz.X / size + 0.5), math.floor(wsz.Y / size + 0.5)
        if cols < 1 or rows < 1 then return nil end
        local res = json.object()
        for _, mode in ipairs({ "rowMajor", "colMajor" }) do
            local origins = json.array()
            for _, p in ipairs(list) do
                local col, row
                if mode == "rowMajor" then col, row = p.i % cols, math.floor(p.i / cols) else row, col = p.i % rows, math.floor(p.i / rows) end
                origins[#origins + 1] = { i = p.i, col = col, row = row, originX = math.floor(p.loc.X - (col + 0.5) * size), originY = math.floor(p.loc.Y - (row + 0.5) * size) }
            end
            local consistent = #origins >= 2
            for k = 2, #origins do
                if math.abs(origins[k].originX - origins[1].originX) > size * 1.5 or math.abs(origins[k].originY - origins[1].originY) > size * 1.5 then consistent = false end
            end
            res[mode] = { origins = origins, consistent = consistent }
        end
        res.cols, res.rows = cols, rows
        return res
    end
    -- 8-connected grid line (Bresenham) between two dot indices, row-major.
    local function gridLine(i0, i1, cols)
        local x0, y0, x1, y1 = i0 % cols, math.floor(i0 / cols), i1 % cols, math.floor(i1 / cols)
        local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
        local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
        local err = dx + dy
        local cells = json.array()
        while true do
            cells[#cells + 1] = y0 * cols + x0
            if (x0 == x1 and y0 == y1) or #cells > 5000 then break end
            local e2 = 2 * err
            if e2 >= dy then err = err + dy; x0 = x0 + sx end
            if e2 <= dx then err = err + dx; y0 = y0 + sy end
        end
        return cells
    end
    local function arraySample(arr, n)
        local sample = json.array()
        pcall(function()
            for _, x in ipairs(H.uarray(arr)) do
                if #sample >= n then break end
                if type(x) == "userdata" then x = R.plain(x, 2) end
                sample[#sample + 1] = x
            end
        end)
        return sample
    end

    def("trail_plan", {
        help = "Plan a trail from the city to an outpost on the Frostland dot grid (PXFrostlandDetailsSubsystem: GridCellSize, WorldSize, OutpostByDot, CityToCellMap): grid facts, target dot (outpost CellIndex), city dot, row/column-major calibration, candidate trailCells (8-connected grid line, row-major, inferred), samples of an existing trail Path and a running expedition UnitPath when their element type is plain, trail config, straight-line waypoints with screen pixels for the UI fallback, build weeks. args: ref (outpost component) | type | territory, trailType, chunks (default: candidate cell count - 1), debug=true (endpoint props, raw GetNearestTrailpointVector)",
        run = function(args)
            local city = A.city(args)
            local nation = city.Nation
            local tu = cdo("PXTrailUtils")
            local out = { schema = trailCellsSchema() }
            if plainScheme(out.schema.trailComponentPath) then
                for _, tc in ipairs(FindAllOf("PXTrailComponent") or {}) do
                    if R.isValid(tc) and not (R.path(tc) or ""):find("Default__", 1, true) then
                        out.existingTrail = { ref = R.path(tc), path = arraySample(tc.Path, 64) }
                        break
                    end
                end
            else
                out.existingTrail = { skipped = "Path element type not plain: " .. tostring(innerType(out.schema.trailComponentPath)) }
            end
            local cfg = get(out, "trailConfig", cdo("PXGameplayUtils"), "GetTrailConfig")
            if R.isValid(cfg) then out.trailConfig = readProps(cfg) end
            local target = trailTarget(args, nation)
            local tgt = { ref = R.path(target), class = R.className(target) }
            pcall(function() tgt.type = assetId(target.Type) end)
            pcall(function() tgt.cellIndex = target.CellIndex end)
            pcall(function() tgt.built = R.isValid(target.City) end)
            local tloc = geo.location(target)
            tgt.location = tloc
            out.target = tgt
            local cloc = geo.location(city)
            out.cityLocation = cloc
            local grid = frostGrid(target, city)
            out.grid = grid
            if plainScheme(grid.unitPathSchema) then
                for _, t in ipairs(objList(call(cdo("PXTerritoryUtils"), "GetTerritoriesByState", ctx(), TERRITORY_STATE.revealed))) do
                    local ex = call(t, "GetExplorationComponent", nation)
                    if R.isValid(ex) and call(ex, "IsExplorationInProgress") == true then
                        out.expeditionUnitPath = { territory = nameOfTerritory(t), path = arraySample(ex.UnitPath, 64) }
                        break
                    end
                end
            end
            local known = {}
            local tIdx = grid.targetDot or tgt.cellIndex
            if tIdx and tloc then known[#known + 1] = { i = tIdx, loc = tloc } end
            if grid.cityCell and cloc then known[#known + 1] = { i = grid.cityCell, loc = cloc } end
            local cal = calibrate(grid, known)
            out.calibration = cal
            if cal and cal.rowMajor.consistent and tIdx and grid.cityCell then
                out.candidateCells = gridLine(grid.cityCell, tIdx, cal.cols)
                out.candidateNote = "inferred: row-major dots, 8-connected line from the city dot; compare with existingTrail.path / expeditionUnitPath before trail_build"
            elseif cal then
                out.candidateNote = "no consistent row-major calibration; see calibration (colMajor?) and grid"
            end
            local eps = endpoints(tloc, flag(args.debug))
            local near = json.array()
            for i = 1, math.min(5, #eps) do near[#near + 1] = eps[i] end
            out.endpointsNearTarget = near
            if flag(args.debug) then
                local srcArg = asParam(city, tu, "GetNearestTrailpointVector", "Source")
                local tgtArg = asParam(target, tu, "GetNearestTrailpointVector", "Target")
                if srcArg and tgtArg then
                    local v = get(out, "nearestTrailpoint", tu, "GetNearestTrailpointVector", ctx(), srcArg, tgtArg)
                    out.nearestTrailpoint = saneVec(v) or "unreadable (denormal Vector return, measured)"
                end
            end
            local actor = geo.actorOf(city)
            if actor then
                local a = asParam(actor, tu, "CanStartTrailPaintingFromActorPosition", "Actor")
                if a then out.canStartFromCity = get(out, "canStart", tu, "CanStartTrailPaintingFromActorPosition", ctx(), a) end
            end
            local start = cloc
            if start and tloc then
                local dx, dy = tloc.X - start.X, tloc.Y - start.Y
                out.distance = math.floor(math.sqrt(dx * dx + dy * dy))
                local chunks = tonumber(args.chunks) or (out.candidateCells and math.max(1, #out.candidateCells - 1)) or 8
                out.chunks = chunks
                local nPts = math.min(chunks, 12)
                local pts = json.array()
                for i = 0, nPts do
                    local f = i / nPts
                    local p = { X = start.X + dx * f, Y = start.Y + dy * f, Z = (start.Z or 0) + ((tloc.Z or 0) - (start.Z or 0)) * f }
                    local s = geo.project(p)
                    pts[#pts + 1] = { x = math.floor(p.X), y = math.floor(p.Y), sx = s and s.x or nil, sy = s and s.y or nil }
                end
                out.waypoints = pts
                local ok, ty = pcall(findTrailType, nation, args.trailType)
                if ok then
                    out.trailType = assetId(ty)
                    out.weeks = weeks(get(out, "duration", tu, "GetTrailTypeConstructionDuration", ty, chunks))
                else
                    out.trailType = "none available (" .. tostring(ty) .. ")"
                end
            end
            out.buildTrailReady = innerType(out.schema.buildTrail) == "Int" and "trailCells is Array<Int> (measured). Cell meaning inferred: Frostland dot indices; verify candidateCells against a real trail Path first" or ("trailCells element " .. tostring(innerType(out.schema.buildTrail)) .. ": trail_build refuses; use trail_tool")
            out.uiFallback = {
                "fp2 keys v  (Frostland view)",
                "fp2 trail_tool step=start ref=<outpost ref>  (ActivateTrailInputTool + TryStartPainting at the city)",
                "fp2 click <sx>,<sy> for each waypoint after the first (re-run trail_plan in Frostland view for fresh pixels)",
                "fp2 trail_tool step=status  (IsTrailPaintingFinished, GetChuncksCount, CanBuildTrail)",
                "fp2 trail_tool step=build  (PXPaintTrailInputTool.BuildTrail) or step=cancel",
                "pure UI: select the city, bottom-right trail button, click the outpost marker, hold the confirm button",
            }
            return out
        end,
    })

    def("trail_build", {
        help = "Build a trail through the command layer (PXInstructionUtils.BuildTrail(World, ownerCityId, trailType, Leader origin, trailCells, chunksCount)). Refused unless the trailCells element type is Int (see trail_plan.schema). args: cells=[ints] (required), chunks (required), trailType, city, dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("trail_build")
            local city = A.city(args)
            local nation = city.Nation
            local schema = fnParamSchema("PXInstructionUtils", "BuildTrail", "trailCells")
            local out = { schema = schema }
            if innerType(schema) ~= "Int" then error("trailCells element type is " .. tostring(innerType(schema)) .. ", not Int; use trail_tool (input-tool route)", 0) end
            if type(args.cells) ~= "table" or #args.cells < 2 then error("cells=[...] with at least 2 cell indices required (trail_plan candidateCells)", 0) end
            local chunks = tonumber(args.chunks)
            if not chunks or chunks < 1 then error("chunks=<n> required", 0) end
            local ints = {}
            for i, c in ipairs(args.cells) do
                local n = tonumber(c)
                if not n then error("cell " .. i .. " is not a number", 0) end
                ints[i] = math.floor(n)
            end
            local ty = findTrailType(nation, args.trailType)
            out.trailType = assetId(ty)
            out.cells, out.chunks = #ints, chunks
            out.weeks = weeks(get(out, "duration", cdo("PXTrailUtils"), "GetTrailTypeConstructionDuration", ty, chunks))
            out.available = get(out, "available", cdo("PXTrailUtils"), "IsTrailTypeAvailable", ctx(), nation, ty)
            if args.dryRun then return out end
            if out.available ~= true then error("trail type not available", 0) end
            local res = cdo("PXInstructionUtils"):BuildTrail(H.world(), H.cityId(city), ty, A.leaderOrigin(), ints, chunks)
            if R.isValid(res) then out.result = R.path(res) else out.result = "nil (the game refused or built nothing)" end
            out.next = "verify with: fp2 trails (constructing, trails), fp2 extract name=resources (cost)"
            return out
        end,
    })

    -- Input-tool route (tier 2): the game's own trail painter builds trailCells itself.
    -- Active input tool of any class (for cancel/status), and the trail painter when that is the active one.
    local function activeTool()
        local tool = call(cdo("PXInputToolUtils"), "GetActiveInputTool", ctx())
        if R.isValid(tool) then return tool end
        return nil
    end
    local function paintTool()
        local tool = activeTool()
        if tool and isA(tool, PAINT_TOOL_CLASS) then return tool end
        return nil
    end
    local function toolStatus(tool, out)
        out.started = get(out, "started", tool, "IsTrailPaintingStarted")
        out.finished = get(out, "finished", tool, "IsTrailPaintingFinished")
        out.chunks = get(out, "chunks", tool, "GetChuncksCount")
        out.canBuild = get(out, "canBuild", tool, "CanBuildTrail")
        return out
    end

    def("trail_tool", {
        help = "Drive the game's trail painter (tier 2). step=start: ActivateTrailInputTool(trailType) + TryStartPainting(city location, or x,y args) (dryRun only resolves positions, activates nothing); step=status: painting started/finished, chunk count, CanBuildTrail; step=build: PXPaintTrailInputTool.BuildTrail() when CanBuildTrail; step=cancel: DeactivateCurrentInputTool. Intermediate points need clicks (no AddPoint UFunction): use trail_plan waypoints. args: step, ref|type|territory (target outpost, start), x,y (start world position, optional), trailType, dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("trail_tool")
            local step = tostring(args.step or "status")
            local iu = cdo("PXInputToolUtils")
            local out = { step = step }
            if step == "status" then
                local any = activeTool()
                out.activeToolClass = any and R.className(any) or nil
                local tool = paintTool()
                out.active = tool ~= nil
                if tool then toolStatus(tool, out) end
                return out
            elseif step == "cancel" then
                -- Deactivates whatever tool is active, so a painter of an unexpected class can still be closed.
                local any = activeTool()
                out.wasActiveClass = any and R.className(any) or nil
                if args.dryRun or not any then return out end
                iu:DeactivateCurrentInputTool(ctx())
                any = activeTool()
                out.activeNowClass = any and R.className(any) or nil
                return out
            elseif step == "build" then
                local tool = paintTool()
                if not tool then error("trail painter not active (step=start first)", 0) end
                toolStatus(tool, out)
                if args.dryRun then return out end
                if out.canBuild ~= true then error("CanBuildTrail is false; add points (click) or cancel", 0) end
                tool:BuildTrail()
                tool = nil
                out.next = "verify with: fp2 trails; fp2 trail_tool step=status"
                return out
            elseif step ~= "start" then
                error("step must be start|status|build|cancel", 0)
            end
            local city = A.city(args)
            local nation = city.Nation
            local ty = findTrailType(nation, args.trailType)
            out.trailType = assetId(ty)
            -- Start: x,y args (e.g. a trail_plan waypoint) or the city location. GetNearestTrailpointVector is not
            -- used: its Vector return read as denormal garbage (measured).
            local start
            if tonumber(args.x) and tonumber(args.y) then
                start = { X = tonumber(args.x), Y = tonumber(args.y), Z = tonumber(args.z) or 0 }
            end
            if args.ref or args.type or args.territory then
                local target = trailTarget(args, nation)
                out.target = R.path(target)
                local tl = geo.location(target)
                if tl then out.targetScreen = geo.project(tl) end
            end
            start = start or geo.location(city)
            if not start then error("no start position", 0) end
            out.start = start
            out.startScreen = geo.project(start)
            local before = activeTool()
            out.activeBeforeClass = before and R.className(before) or nil
            if args.dryRun then return out end
            local ok, errA = call(cdo("PXInputToolTypeUtils"), "ActivateTrailInputTool", ctx(), ty)
            out.activated = ok
            note(out, "activate", errA)
            local function bail(msg)
                out.error = msg
                if activeTool() then
                    pcall(function() iu:DeactivateCurrentInputTool(ctx()) end)
                    out.deactivated = true
                end
                return out
            end
            local tool = paintTool()
            if not tool then
                local any = activeTool()
                return bail("no PXPaintTrailInputTool active after ActivateTrailInputTool (active: " .. tostring(any and R.className(any)) .. "); open Frostland view first: fp2 keys v")
            end
            out.toolClass = R.className(tool)
            local okS, errS = pcall(function() tool:TryStartPainting({ X = start.X, Y = start.Y, Z = start.Z or 0 }, true) end)
            if not okS then return bail("TryStartPainting: " .. tostring(errS)) end
            toolStatus(tool, out)
            if out.started ~= true then out.warning = "painter active but IsTrailPaintingStarted is false (may wait for a start click); click the city trailpoint (startScreen) or run step=cancel" end
            out.next = "click the trail_plan waypoints, then trail_tool step=status / step=build (or step=cancel)"
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- build_outpost2: resolves the target without walking every PXOutpostComponent (frost_sites); reads only Type and City.
    def("build_outpost2", {
        help = "Safer build_outpost: target by ref (StaticFindObject only) or by explored territory -> GetSites -> PXSiteUtils.TryGetOutpostFromSite (no FindAllOf walk over every outpost, the suspected food-herd crash path). Reads only Type and City before InstructConstructOutpost; nothing after. args: ref | territory (+ type substring), dryRun",
        mutation = true,
        run = function(args)
            A.assertNoCutscene("build_outpost2")
            local city = A.city(args)
            local nation = city.Nation
            local target
            local out = {}
            if args.ref then
                target = R.find(tostring(args.ref))
            else
                local wantTerr = args.territory and tostring(args.territory):lower() or nil
                if not wantTerr then error("pass ref or territory", 0) end
                local wantType = args.type and tostring(args.type):lower() or nil
                local su = cdo("PXSiteUtils")
                for _, t in ipairs(allTerritories()) do
                    if (nameOfTerritory(t) or ""):lower():find(wantTerr, 1, true) then
                        out.territory = nameOfTerritory(t)
                        for _, site in ipairs(objList(call(t, "GetSites"))) do
                            local o = call(su, "TryGetOutpostFromSite", ctx(), site)
                            if isOutpost(o) then
                                local id, built
                                pcall(function() id = assetId(o.Type) end)
                                pcall(function() built = R.isValid(o.City) end)
                                if not built and (not wantType or (id or ""):lower():find(wantType, 1, true)) then target = o; break end
                            end
                        end
                        if target then break end
                    end
                end
            end
            if not isOutpost(target) then error("no unbuilt PXOutpostComponent found", 0) end
            out.ref = R.path(target)
            if call(target, "IsBeingDestroyed") == true then error("outpost is being destroyed; advance time and retry", 0) end
            local ty
            pcall(function() ty = target.Type end)
            if not R.isValid(ty) then error("outpost has no valid Type", 0) end
            out.type = assetId(ty)
            pcall(function() out.name = textOf(ty.IngameName) end)
            local built
            pcall(function() built = R.isValid(target.City) end)
            if built then error("outpost already built", 0) end
            if args.dryRun then return out end
            local iu, wco, origin = cdo("PXInstructionUtils"), ctx(), A.leaderOrigin()
            if not (R.isValid(city) and R.isValid(target)) then error("city or outpost invalid before the call", 0) end
            iu:InstructConstructOutpost(wco, city, target, origin)
            target, ty = nil, nil
            out.next = "verify with: fp2 outposts territory=<name> (do not run frost_sites in the same week)"
            return out
        end,
    })
end

return M
