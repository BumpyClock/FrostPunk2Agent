-- Multi-city play: player cities and colonies, colony sites, founding/abandoning/recolonizing a colony,
-- trade routes (ongoing resource shipments), people transfers, and the colony stockpile-exchange layer.
--
-- City selectors (`city=`, `from=`, `to=`, `parent=`) use the same index space as every other command:
-- `index` = position in A.cities() (every PXCityComponent, 1-based, player-owned or not). A string matches a
-- cityType id substring, an in-game name substring, or a full ref. `fp2 cities` prints the index of each city.
--
-- Crash rules applied here (MOD_DEVELOPMENT.md): every Can*/Is*Available check and every *Cost getter of
-- PXCityUtils returns a struct with FText (PXCheckResult / PXGameplayDescription). They go only through
-- h.try (reflect.invoke refuses FText structs before marshalling and returns the refusal as data); never
-- call them as methods. No reference is held across an Instruct*/Abandon/Recolonize/Transfer call: paths are
-- captured before, objects re-found with h.fresh after.

local M = {}

local SUMMARY = {
    food = "Core_FoodResource", coal = "CoalResource", oil = "OilResource", materials = "Core_MaterialsResource",
    goods = "Core_GoodsResource", prefabs = "Core_PrefabsResource", heatstamps = "Core_Heatnotes", cores = "CoresResource",
}

function M.register(def, env)
    local A, reflect, json, h = env.actions, env.reflect, env.json, env.h
    local cdo, assetId, ctx, try, fresh, textOf, costMap, objList =
        h.cdo, h.assetId, h.ctx, h.try, h.fresh, h.textOf, h.costMap, h.objList

    local function r1(x) if type(x) ~= "number" then return x end return math.floor(x * 10 + 0.5) / 10 end
    local function valid(x) return reflect.isValid(x) end
    local function call(fn) local ok, v = pcall(fn); if ok then return v end return nil end
    local function isErr(v) return type(v) == "table" and v.error ~= nil end
    -- Ordered list of {name, object}: a nil object fails too (pairs() would skip it).
    local function requireValid(list, what)
        for _, p in ipairs(list) do
            if not valid(p[2]) then error(p[1] .. " invalid before the call; not " .. what, 0) end
        end
    end

    local function isPlayer(c)
        return call(function() return cdo("PXNationUtils"):IsCityOwnedByPlayer(c) end) == true
    end
    local function isMain(c)
        return call(function() return cdo("PXNationUtils"):IsMainCityOfNation(c) end) == true
    end
    local function cityName(c)
        local ct = call(function() return c.CityType end)
        if not valid(ct) then return nil end
        for _, f in ipairs({ "IngameName", "CityName", "Name", "DisplayName" }) do
            local n = call(function() return textOf(ct[f]) end)
            if type(n) == "string" and n ~= "" then return n end
        end
        return nil
    end
    local function label(c, idx)
        local e = { index = idx, ref = reflect.path(c) }
        pcall(function() e.cityType = assetId(c.CityType) end)
        e.name = cityName(c)
        return e
    end

    -- Index of a city in A.cities() (the shared selector space), by path.
    local function indexOf(c)
        local p = reflect.path(c)
        for i, x in ipairs(A.cities()) do if reflect.path(x) == p then return i end end
        return nil
    end

    local function mainCity()
        local list = A.cities()
        local m = call(function() return cdo("PXNationUtils"):GetPlayerMainCity(ctx()) end)
        if valid(m) then
            local p = reflect.path(m)
            for _, c in ipairs(list) do if reflect.path(c) == p then return c end end
        end
        for _, c in ipairs(list) do if isMain(c) and isPlayer(c) then return c end end
        for _, c in ipairs(list) do if isPlayer(c) then return c end end
        error("no player city", 0)
    end

    -- sel: nil -> default (main city unless allowDefault == false), number -> A.cities() index,
    -- string -> full ref, cityType id substring or in-game name substring.
    local function findCity(sel, what, allowDefault)
        if sel == nil or sel == "" then
            if allowDefault == false then error(what .. " required (index, cityType or name; see fp2 cities)", 0) end
            return mainCity()
        end
        local list = A.cities()
        if tonumber(sel) then
            local c = list[tonumber(sel)]
            if not valid(c) then error("no city #" .. tostring(sel) .. " for " .. what .. " (see fp2 cities)", 0) end
            return c
        end
        local s = tostring(sel)
        if s:sub(1, 1) == "/" then
            for _, c in ipairs(list) do if reflect.path(c) == s then return c end end
        end
        local want = s:lower()
        for _, c in ipairs(list) do
            if (assetId(call(function() return c.CityType end)) or ""):lower():find(want, 1, true) then return c end
        end
        for _, c in ipairs(list) do
            if (cityName(c) or ""):lower():find(want, 1, true) then return c end
        end
        error("no city matching " .. s .. " for " .. what .. " (see fp2 cities)", 0)
    end

    local function playerCity(sel, what, allowDefault)
        local c = findCity(sel, what, allowDefault)
        if not isPlayer(c) then error(what .. " " .. tostring(reflect.path(c)) .. " is not owned by the player", 0) end
        return c
    end

    -- TMap<statistic asset, number> -> { id = value }
    local function statMap(map)
        local out = {}
        pcall(function()
            map:ForEach(function(k, v)
                local key = k.get and k:get() or k
                local val = v.get and v:get() or v
                local id = assetId(key)
                if id and type(val) == "number" then out[id] = val end
            end)
        end)
        return out
    end

    -- Tension and colony unrest of one city: the city's tension statistic (PXCityUtils.GetCityTensionStatistic)
    -- plus every statistic id containing "tension" or "unrest" from statisticHolder.
    local function unrestOf(c)
        local out = json.object()
        pcall(function()
            local st = cdo("PXCityUtils"):GetCityTensionStatistic(c)
            if valid(st) then
                out.tensionStatistic = assetId(st)
                out.tensionStatisticClass = reflect.className(st)
                -- PXStatisticUtils getters take the statistic asset. CityComponent *Statistic fields are
                -- PXStatisticComponent instances; never pass an object of another class to a native getter.
                if not (out.tensionStatisticClass or "Component"):find("Component", 1, true) then
                    local su = cdo("PXStatisticUtils")
                    pcall(function() out.tension = r1(su:GetCurrentStatisticValue(c, st)) end)
                    pcall(function() out.tensionTarget = r1(su:GetTargetStatisticValue(c, st)) end)
                end
            end
        end)
        pcall(function()
            local sh = c.statisticHolder
            if not valid(sh) then return end
            local cur, tgt = statMap(sh.CurrentStatistics), statMap(sh.TargetStatistics)
            local stats = json.object()
            for id, v in pairs(cur) do
                local l = id:lower()
                if l:find("tension", 1, true) or l:find("unrest", 1, true) then
                    stats[id] = { current = r1(v), target = r1(tgt[id]) }
                end
            end
            out.statistics = stats
        end)
        return out
    end

    local function communitiesOf(c)
        local out = json.array()
        pcall(function()
            for _, cm in ipairs(objList(cdo("PXCommunityUtils"):GetCommunitiesSortedBySize(c))) do
                local e = {}
                pcall(function() e.community = assetId(cm.Type) end)
                pcall(function() e.size = cm.Size end)
                out[#out + 1] = e
            end
        end)
        return out
    end

    -- Community component in a city: by type id substring, else the largest.
    local function pickCommunity(c, want)
        local list = call(function() return objList(cdo("PXCommunityUtils"):GetCommunitiesSortedBySize(c)) end) or {}
        local w = want and tostring(want):lower() or nil
        for _, cm in ipairs(list) do
            local ty = call(function() return cm.Type end)
            if valid(ty) and (not w or (assetId(ty) or ""):lower():find(w, 1, true)) then return cm, ty end
        end
        error("no community " .. (w and ("matching " .. w .. " ") or "") .. "in " .. tostring(assetId(call(function() return c.CityType end))), 0)
    end

    local function weeks(t)
        if type(t) == "table" and type(t.ScaledTicks) == "number" then return r1(t.ScaledTicks / 1680) end
        return nil
    end

    local function costOf(v)
        if isErr(v) then return v end
        local ok, m = pcall(costMap, v)
        if ok then return m end
        return { error = tostring(m) }
    end

    local function ownerOf(c)
        local o = call(function() return c:GetOwner() end)
        if valid(o) then return o end
        return nil
    end

    -- Trail between two cities: connected flag, trail type and its capacity.
    local function trailInfo(a, b)
        local out = {}
        local oa, ob = ownerOf(a), ownerOf(b)
        if not (oa and ob) then return out end
        local tu = cdo("PXTrailUtils")
        pcall(function() out.connected = tu:AreActorsConnectedWithTrail(ctx(), oa, ob) end)
        pcall(function()
            local tt = tu:GetActorsConnectedTrailType(ctx(), oa, ob)
            if valid(tt) then
                out.trailType = assetId(tt)
                pcall(function() out.trailCapacity = tu:GetTrailTypeCapacity(ctx(), tt) end)
            end
        end)
        return out
    end

    local NUMERIC = { IntProperty = true, Int64Property = true, FloatProperty = true, DoubleProperty = true, UInt32Property = true, Int16Property = true }
    local OBJKEY = { ObjectProperty = true, ObjectPtrProperty = true }

    -- Runtime signature of a TMap parameter (the describe dumps print only "Map"). The trade mutation runs only
    -- when the key is a UObject and the value a number.
    local function mapSig(obj, fnName, param)
        local out = { fn = fnName, param = param }
        local f = call(function() return obj[fnName] end)
        if not valid(f) then out.error = "function not found"; out.ok = false; return out end
        pcall(function()
            f:ForEachProperty(function(p)
                if reflect.propName(p) == param then
                    out.type = reflect.propType(p)
                    -- Measured 2026-10-11: GetKeyProp/GetValueProp resolved nothing on a UFunction param, so try the
                    -- other accessor spellings; when none works, trade_route falls back to mapEvidence.
                    local k, v
                    for _, n in ipairs({ "GetKeyProp", "GetKeyProperty", "KeyProp" }) do
                        k = k or call(function() local x = p[n]; if type(x) == "function" then return x(p) end return nil end)
                    end
                    for _, n in ipairs({ "GetValueProp", "GetValueProperty", "ValueProp" }) do
                        v = v or call(function() local x = p[n]; if type(x) == "function" then return x(p) end return nil end)
                    end
                    if k then out.keyType = reflect.propType(k); out.key = reflect.paramTypeName(k) end
                    if v then out.valueType = reflect.propType(v); out.value = reflect.paramTypeName(v) end
                    return true
                end
            end)
        end)
        out.ok = out.type == "MapProperty" and OBJKEY[out.keyType or ""] == true and NUMERIC[out.valueType or ""] == true
        return out
    end

    -- Evidence for the Resources map type from stored route maps (PXTradeComponent.TradedResources, a property read
    -- through TMap:ForEach): every entry must have a UObject key and a number value. Counts over all player routes.
    local function mapEvidence(routes)
        local ev = { routes = 0, entries = 0, objectKeys = 0, numberValues = 0 }
        for _, r in ipairs(routes) do
            if valid(r) then
                ev.routes = ev.routes + 1
                pcall(function()
                    r.TradedResources:ForEach(function(k, v)
                        local key = k.get and k:get() or k
                        local val = v.get and v:get() or v
                        ev.entries = ev.entries + 1
                        if valid(key) then ev.objectKeys = ev.objectKeys + 1 end
                        if type(val) == "number" then
                            ev.numberValues = ev.numberValues + 1
                            if math.type and math.type(val) == "float" then ev.floatValues = (ev.floatValues or 0) + 1 end
                        end
                    end)
                end)
            end
        end
        ev.ok = ev.entries > 0 and ev.objectKeys == ev.entries and ev.numberValues == ev.entries
        return ev
    end

    local function resourcesSummary(byRef, c)
        local r = byRef[reflect.path(c)]
        if type(r) ~= "table" then return nil end
        local out = json.object()
        for short, id in pairs(SUMMARY) do
            local s = r.stock and r.stock[id]
            local ch = r.change and r.change[id]
            if s ~= nil or ch ~= nil then out[short] = { stock = s, change = ch, limit = r.limits and r.limits[id] or nil } end
        end
        return out
    end

    ---------------------------------------------------------------------------
    -- cities

    def("cities", {
        help = "Player cities (main + colonies): index (the city= selector everywhere), cityType, name, main/colony, accessible, population, workforce, tension/colony unrest, stock summary (stock/change/limit), selected city. args: all=true includes non-player cities.",
        run = function(args)
            local nu, cu, wu = cdo("PXNationUtils"), cdo("PXCityUtils"), cdo("PXWorkforceUtils")
            local commU, tradeU = cdo("PXCommunityUtils"), cdo("PXTradeUtils")
            local selected = try(cdo("PXSelectionUtils"), "GetCurrentCity", { ctx() })
            local selectedRef = type(selected) == "table" and selected.ref or nil
            local main = try(nu, "GetPlayerMainCity", { ctx() })
            local nationList = try(nu, "GetAllPlayerCities", { ctx() })
            local inNation = {}
            if type(nationList) == "table" and not isErr(nationList) then
                for _, e in ipairs(nationList) do if type(e) == "table" and e.ref then inNation[e.ref] = e.class or true end end
            end
            local res = {}
            pcall(function()
                for _, r in ipairs(env.extractors.run("resources") or {}) do if r.ref then res[r.ref] = r end end
            end)
            local out = json.array()
            for i, c in ipairs(A.cities()) do
                local owned = isPlayer(c)
                if owned or args.all then
                    local e = label(c, i)
                    e.player = owned
                    e.main = isMain(c)
                    e.kind = e.main and "main" or "colony"
                    pcall(function() e.id = c.CityOfTypeId:ToString() end)
                    pcall(function() e.accessible = cu:IsCityAccessible(c) end)
                    pcall(function() e.population = commU:GetScaledCityPopulationSize(c) end)
                    pcall(function() e.communitiesSize = commU:GetCityCommunitiesSize(c) end)
                    e.communities = communitiesOf(c)
                    pcall(function()
                        local f = c.FounderCommunityType
                        if valid(f) then e.founder = assetId(f) end
                    end)
                    pcall(function()
                        local ct = c.CityType
                        if valid(ct) then
                            e.cityTypeLimits = { startCommunitySize = ct.StartCommunitySize, minimalCommunitySize = ct.MinimalCommunitySize,
                                minimalCommunitySizeAfterTransfer = ct.MinimalCommunitySizeAfterTransfer, transportLimit = ct.TransportLimit,
                                canBeAbandonedByPlayer = ct.CanBeAbandonedByPlayer }
                        end
                    end)
                    e.workforce = {}
                    pcall(function() e.workforce.total = wu:GetCityTotalWorkforce(c) end)
                    pcall(function() e.workforce.available = wu:GetCityAvailableWorkforce(c) end)
                    pcall(function() e.workforce.working = wu:GetCityWorkingWorkforce(c) end)
                    pcall(function() e.workforce.required = wu:GetCityRequiredWorkforce(c) end)
                    e.unrest = unrestOf(c)
                    e.stock = resourcesSummary(res, c)
                    pcall(function() e.tradingUnlocked = tradeU:IsTradingUnlocked(c) end)
                    pcall(function() e.hasTradeRoute = tradeU:HasAnyTradeRoute(c) end)
                    pcall(function() e.relocatingOut = cdo("PXUnitUtils"):IsAnyUnitRelocatingFromCity(ctx(), c) end)
                    e.selected = selectedRef ~= nil and selectedRef == e.ref
                    e.inPlayerNationList = inNation[e.ref] ~= nil
                    out[#out + 1] = e
                end
            end
            return {
                cities = out,
                mainCity = type(main) == "table" and (main.ref or main.error) or nil,
                selected = selectedRef,
                playerCitiesFromNation = nationList,
                selector = "city=<index> uses the index above (position among all PXCityComponents, same as every other command); city=<text> matches cityType id or name. Default for colony commands: the main city.",
                abandonRecolonizeChecks = "unreadable from Lua: PXCityUtils.Can*/Is*Available return PXCheckResult (FText). city_abandon/recolonize dryRun report the guard error.",
            }
        end,
    })

    ---------------------------------------------------------------------------
    -- colony sites

    local DETAIL_FILTERS = { "Cost", "Duration", "Communit", "Requir", "Unit", "Recolon", "Abandon", "Founder", "ConstructionSetup", "TransportLimit", "TradeSetup", "TensionStatistic" }

    local function colonySites(args)
        local fs = A.frostSites({ kind = "colony", limit = 200, state = args.state, territory = args.territory })
        local nation = call(function() return mainCity().Nation end)
        local cu, su, au = cdo("PXCityUtils"), cdo("PXSiteUtils"), cdo("PXCityAreaUtils")
        local out = json.array()
        for _, e in ipairs(fs.sites or {}) do
            local sp = reflect.find(e.ref)
            if valid(sp) then
                local ct = call(function() return sp.CityType end)
                local at = call(function() return sp.CityAreaType end)
                if valid(ct) then
                    e.name = call(function() return textOf(ct.IngameName) end)
                    if valid(nation) then
                        pcall(function() e.canShow = su:CanShowBuildingColony(ctx(), ct, nation) end)
                    end
                    pcall(function()
                        local city = cu:GetCityByType(ctx(), ct)
                        e.built = valid(city)
                        if e.built then
                            e.cityRef = reflect.path(city)
                            e.cityIndex = indexOf(city)
                            e.cityPlayer = isPlayer(city)
                        end
                    end)
                    e.weeks = weeks(try(cu, "GetCityConstructionDuration", { ct }))
                    -- Possibly only the founding unit's share (teams), not cores/prefabs: unverified.
                    e.unitCost = costOf(try(cdo("PXUnitUtils"), "GetUnitCostFromCityConstructionCost", { ct }))
                    if args.details then
                        local props = json.object()
                        for _, f in ipairs(DETAIL_FILTERS) do
                            local ok, d = pcall(reflect.dump, ct, { depth = 3, filter = f, arrayLimit = 20 })
                            if ok and type(d) == "table" then for k, v in pairs(d) do props[k] = v end end
                        end
                        e.cityTypeProps = props
                    end
                end
                if valid(at) then
                    pcall(function()
                        local area = au:GetCityAreaByType(ctx(), at)
                        e.areaSpawned = valid(area)
                        if e.areaSpawned then e.areaRef = reflect.path(area) end
                    end)
                end
            end
            out[#out + 1] = e
        end
        return { counts = fs.counts, sites = out }
    end

    def("colony_sites", {
        help = "Colony sites (frost_sites kind=colony) with in-game name, canShow (PXSiteUtils.CanShowBuildingColony), built (existing city of that type), areaSpawned, construction weeks and unitCost (GetUnitCostFromCityConstructionCost; may be only the founding unit's share). args: state, territory, details=true (city type cost/requirement/community properties).",
        run = function(args) return colonySites(args) end,
    })

    ---------------------------------------------------------------------------
    -- colony_build / city_abandon / recolonize

    local function pickSite(args)
        local want = args.site or args.ref or args.territory
        if want == nil then error("site required: ref, territory, cityType or area substring (see fp2 colony_sites)", 0) end
        local w = tostring(want):lower()
        local list = colonySites({}).sites
        for _, e in ipairs(list) do
            if e.ref == tostring(want) then return e end
        end
        for _, e in ipairs(list) do
            local hay = table.concat({ e.territory or "", e.cityType or "", e.area or "", e.name or "" }, "|"):lower()
            if hay:find(w, 1, true) and not e.built then return e end
        end
        error("no unbuilt colony site matching " .. tostring(want) .. " (see fp2 colony_sites)", 0)
    end

    def("colony_build", {
        mutation = true,
        help = "Found a colony on a colony site (PXInstructionUtils.InstructBuildCity, Leader origin, sendUnit=true: the founders travel). args: site (ref or territory/cityType/name substring), community (founding community type substring; default the parent's largest), parent (city selector; default main city), dryRun. dryRun reports cost, weeks, area and the (FText-guarded) CanCreateCity result.",
        run = function(args)
            A.assertNoCutscene("colony_build")
            local e = pickSite(args)
            if e.built then error("site " .. tostring(e.ref) .. " already has a city (cityIndex " .. tostring(e.cityIndex) .. "); see recolonize", 0) end
            if e.state == "Hidden" then error("site " .. tostring(e.ref) .. " is Hidden; explore its territory first", 0) end
            local sp = reflect.find(e.ref)
            if not valid(sp) then error("site spawner not found: " .. tostring(e.ref), 0) end
            local ct = call(function() return sp.CityType end)
            local at = call(function() return sp.CityAreaType end)
            if not valid(ct) then error("site has no valid CityType", 0) end
            if not valid(at) then error("site has no valid CityAreaType", 0) end
            local parent = playerCity(args.parent, "parent", true)
            local nation = call(function() return parent.Nation end)
            if not valid(nation) then error("parent city has no valid Nation", 0) end
            local area = call(function() return cdo("PXCityAreaUtils"):GetCityAreaByType(ctx(), at) end)
            if not valid(area) then error("city area " .. tostring(assetId(at)) .. " is not spawned; not building (no SpawnCityArea: SoftObject param)", 0) end
            local comm, commType = pickCommunity(parent, args.community)
            local out = {
                site = e.ref, territory = e.territory, cityType = assetId(ct), name = e.name, area = assetId(at),
                areaRef = reflect.path(area), parent = label(parent, indexOf(parent)), community = assetId(commType),
                communitySize = call(function() return comm.Size end), communities = communitiesOf(parent),
                canShow = e.canShow, weeks = e.weeks, unitCost = e.unitCost, sendUnit = true,
            }
            out.check = try(cdo("PXCityUtils"), "CanCreateCity", { ctx(), nation, area, ct })
            if args.dryRun then return out end
            local ctPath = reflect.path(ct)
            local iu, wco, origin = cdo("PXInstructionUtils"), ctx(), A.leaderOrigin()
            requireValid({ { "parent", parent }, { "area", area }, { "cityType", ct }, { "community", commType }, { "origin", origin }, { "world", wco } }, "building")
            reflect.assertSafeCall(iu.InstructBuildCity, "InstructBuildCity", false)
            iu:InstructBuildCity(wco, parent, area, ct, origin, commType, true)
            -- Do not touch parent/area/sp after the instruction; re-find the new city by its type.
            local ct2 = fresh(ctPath)
            if ct2 then
                pcall(function()
                    local city = cdo("PXCityUtils"):GetCityByType(ctx(), ct2)
                    out.cityNow = valid(city) and reflect.path(city) or nil
                end)
            end
            out.next = "verify with: fp2 colony_sites territory=<name>, fp2 cities, fp2 extract name=construction"
            return out
        end,
    })

    def("city_abandon", {
        mutation = true,
        help = "Abandon a colony (PXCityUtils.AbandonCity, Leader origin). Irreversible for the colony; refuses the main city. args: city (selector, required), confirm=true (required to act), dryRun.",
        run = function(args)
            A.assertNoCutscene("city_abandon")
            local c = playerCity(args.city, "city", false)
            if isMain(c) then error("refusing to abandon the main city", 0) end
            local cu = cdo("PXCityUtils")
            local out = label(c, indexOf(c))
            pcall(function() out.population = cdo("PXCommunityUtils"):GetScaledCityPopulationSize(c) end)
            out.check = try(cu, "CanAbandonCity", { ctx(), c })
            out.available = try(cu, "IsCityAbandonmentAvailable", { ctx(), c })
            if args.dryRun then return out end
            if args.confirm ~= true then
                out.refused = "pass confirm=true to abandon this colony (the game check above is unreadable from Lua)"
                return out
            end
            local path = out.ref
            local wco, origin = ctx(), A.leaderOrigin()
            if not (valid(c) and valid(origin)) then error("city or origin invalid before the call; not abandoning", 0) end
            cu:AbandonCity(wco, c, origin)
            local now = fresh(path)
            out.existsNow = now ~= nil
            if now then
                out.playerNow = isPlayer(now)
                pcall(function() out.accessibleNow = cu:IsCityAccessible(now) end)
            end
            return out
        end,
    })

    def("recolonize", {
        mutation = true,
        help = "Recolonize an abandoned city (PXCityUtils.RecolonizeCity, Leader origin, player nation). Refuses active player cities; a non-player city also needs confirm=true. args: city (selector over all cities, required), community (type substring from the main city; default its largest), confirm, dryRun. Cost and check are FText-guarded (reported as errors).",
        run = function(args)
            A.assertNoCutscene("recolonize")
            local c = findCity(args.city, "city", false)
            if isMain(c) then error("that is the main city", 0) end
            local owned = isPlayer(c)
            local accessible = call(function() return cdo("PXCityUtils"):IsCityAccessible(c) end)
            if owned and accessible == true then error("city is an active player city; nothing to recolonize", 0) end
            local cu = cdo("PXCityUtils")
            local nation = call(function() return cdo("PXNationUtils"):GetPlayerNation(ctx()) end)
            if not valid(nation) then error("no player nation", 0) end
            local main = mainCity()
            local _, commType = pickCommunity(main, args.community)
            local out = label(c, indexOf(c))
            out.player = isPlayer(c)
            pcall(function() out.accessible = cu:IsCityAccessible(c) end)
            out.community = assetId(commType)
            out.check = try(cu, "CanRecolonizeCity", { ctx(), nation, c })
            out.available = try(cu, "IsCityRecolonizationAvailable", { ctx(), nation, c })
            pcall(function() out.cost = try(cu, "GetCityRecolonizationCost", { c.CityType }) end)
            if args.dryRun then return out end
            if not owned and args.confirm ~= true then
                out.refused = "city is not player-owned; the game check is unreadable from Lua, pass confirm=true to recolonize it"
                return out
            end
            local path = out.ref
            local wco, origin = ctx(), A.leaderOrigin()
            requireValid({ { "city", c }, { "nation", nation }, { "community", commType }, { "origin", origin } }, "recolonizing")
            cu:RecolonizeCity(wco, c, nation, origin, commType)
            local now = fresh(path)
            if now then
                out.playerNow = isPlayer(now)
                pcall(function() out.accessibleNow = cu:IsCityAccessible(now) end)
            end
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- trade routes

    local function playerCities()
        local out = {}
        for i, c in ipairs(A.cities()) do if isPlayer(c) then out[#out + 1] = { i = i, c = c } end end
        return out
    end

    local function routeInfo(tu, r)
        local e = { ref = reflect.path(r) }
        e.resources = costOf(try(tu, "GetTradedResources", { r }))
        pcall(function() e.total = tu:GetTotalAmountOfTradedResources(r) end)
        pcall(function() e.tradingAny = tu:IsTradeRouteTradingAnyResource(r) end)
        return e
    end

    def("trade_routes", {
        help = "Trade routes (ongoing resource shipments) between player cities: per ordered pair the route (GetCityTradeRoute) with traded resources, the per-resource limit (GetTradeRouteResourceLimit) and the trail (type, capacity). Per city: trading unlocked/visible, route count limit, tradable resources. args: city (selector; only pairs touching it).",
        run = function(args)
            local tu = cdo("PXTradeUtils")
            local pcs = playerCities()
            local only = args.city ~= nil and reflect.path(findCity(args.city, "city")) or nil
            local cities = json.array()
            for _, x in ipairs(pcs) do
                local c = x.c
                local e = label(c, x.i)
                pcall(function() e.unlocked = tu:IsTradingUnlocked(c) end)
                pcall(function() e.visible = tu:IsTradingVisible(c) end)
                pcall(function() e.insufficient = tu:HasInsufficientResourcesInCityTrade(c) end)
                pcall(function()
                    local th = c.TradeHolder
                    if valid(th) then
                        e.routeCountLimit = th.TradeRouteCountLimit
                        local refs = json.array()
                        for _, r in ipairs(h.uarray(th.TradeRoutes)) do if valid(r) then refs[#refs + 1] = reflect.path(r) end end
                        e.routes = refs
                    end
                end)
                cities[#cities + 1] = e
            end
            local pairsOut = json.array()
            for _, a in ipairs(pcs) do
                for _, b in ipairs(pcs) do
                    local pa, pb = reflect.path(a.c), reflect.path(b.c)
                    if pa ~= pb and (not only or only == pa or only == pb) then
                        local e = { from = a.i, fromType = assetId(call(function() return a.c.CityType end)), to = b.i,
                            toType = assetId(call(function() return b.c.CityType end)) }
                        pcall(function() e.limit = tu:GetTradeRouteResourceLimit(ctx(), a.c, b.c) end)
                        pcall(function() e.sending = tu:IsSourceCitySendingAnythingToTargetCity(a.c, b.c) end)
                        local tr = trailInfo(a.c, b.c)
                        for k, v in pairs(tr) do e[k] = v end
                        pcall(function()
                            local r = tu:GetCityTradeRoute(a.c, b.c)
                            if valid(r) then e.route = routeInfo(tu, r) end
                        end)
                        pairsOut[#pairsOut + 1] = e
                    end
                end
            end
            local tradable = json.array()
            pcall(function()
                for _, r in ipairs(objList(tu:GetNationTradableResources(mainCity().Nation))) do tradable[#tradable + 1] = assetId(r) end
            end)
            return { cities = cities, pairs = pairsOut, tradable = tradable }
        end,
    })

    local ALIAS = {}
    for short, id in pairs(SUMMARY) do ALIAS[short] = id end

    -- resources arg: table {id = amount} (CLI parses JSON) or a JSON string.
    local function parseResources(v)
        if type(v) == "string" then
            local ok, t = pcall(json.decode, v)
            if not ok or type(t) ~= "table" then error("resources must be a JSON object, e.g. {\"Core_FoodResource\":100}", 0) end
            v = t
        end
        if type(v) ~= "table" then error("resources required, e.g. resources='{\"Core_FoodResource\":100,\"CoalResource\":200}'", 0) end
        return v
    end

    def("trade_route", {
        mutation = true,
        help = "Create or update the trade route from one player city to another (InstructCreateTradeRoute / InstructUpdateTradeRoute). args: to (city selector, required), from (default main city), resources='{\"Core_FoodResource\":100,\"coal\":200}' (id, id substring or alias food/coal/oil/materials/goods; 0 stops that resource), replace=true (drop resources not listed; default keeps current amounts), unverifiedMap=true (act although the map type is unconfirmed; save first), dryRun. Refuses when trading is locked, amounts above the per-resource limit, and an unconfirmed map type (mapSignature, else mapEvidence from stored route maps).",
        run = function(args)
            A.assertNoCutscene("trade_route")
            local src = playerCity(args.from, "from", true)
            local tgt = playerCity(args.to, "to", false)
            if reflect.path(src) == reflect.path(tgt) then error("from and to are the same city", 0) end
            local want = parseResources(args.resources)
            local tu, iu = cdo("PXTradeUtils"), cdo("PXInstructionUtils")
            local nation = call(function() return src.Nation end)
            if not valid(nation) then error("source city has no valid Nation", 0) end
            local tradable = call(function() return objList(tu:GetNationTradableResources(nation)) end) or {}
            if #tradable == 0 then
                -- fallback: the source stockpile's resource keys (same assets the resources extractor reads)
                pcall(function() src.stockpile.Stock:ForEach(function(k) local r = k.get and k:get() or k; if valid(r) then tradable[#tradable + 1] = r end end) end)
            end
            local byId = {}
            for _, r in ipairs(tradable) do local id = assetId(r); if id then byId[id] = r end end
            local function resolve(key)
                local k = ALIAS[tostring(key):lower()] or tostring(key)
                if byId[k] then return k end
                local w = k:lower()
                for id in pairs(byId) do if id:lower() == w then return id end end
                for id in pairs(byId) do if id:lower():find(w, 1, true) then return id end end
                return nil
            end
            local requested, unknown = json.object(), json.array()
            for k, v in pairs(want) do
                local id = resolve(k)
                local n = tonumber(v)
                if not id then unknown[#unknown + 1] = tostring(k)
                elseif not n or n < 0 then error("amount for " .. tostring(k) .. " must be a number >= 0", 0)
                else requested[id] = math.floor(n + 0.5) end
            end
            if #unknown > 0 then
                local ids = {}
                for id in pairs(byId) do ids[#ids + 1] = id end
                table.sort(ids)
                error("unknown resource(s) " .. table.concat(unknown, ",") .. "; tradable: " .. table.concat(ids, ","), 0)
            end
            local existing = call(function() return tu:GetCityTradeRoute(src, tgt) end)
            if not valid(existing) then existing = nil end
            local out = { from = label(src, indexOf(src)), to = label(tgt, indexOf(tgt)), requested = requested }
            local merged = json.object()
            if existing then
                out.existing = routeInfo(tu, existing)
                if not args.replace and type(out.existing.resources) == "table" and not isErr(out.existing.resources) then
                    for id, v in pairs(out.existing.resources) do if byId[id] and type(v) == "number" then merged[id] = v end end
                end
            end
            for id, v in pairs(requested) do merged[id] = v end
            out.resources = merged
            out.mode = existing and "update" or "create"
            pcall(function() out.limit = tu:GetTradeRouteResourceLimit(ctx(), src, tgt) end)
            for k, v in pairs(trailInfo(src, tgt)) do out[k] = v end
            local over = json.array()
            if type(out.limit) == "number" then
                for id, v in pairs(merged) do if v > out.limit then over[#over + 1] = id end end
            end
            out.overLimit = over
            local total = 0
            for _, v in pairs(merged) do total = total + v end
            out.requestedTotal = total
            local sourceStock = json.object()
            for id in pairs(merged) do
                pcall(function() sourceStock[id] = cdo("PXStockpileUtils"):GetCityStockpileOfResource(src, byId[id]) end)
            end
            out.sourceStock = sourceStock
            local fnName = existing and "InstructUpdateTradeRoute" or "InstructCreateTradeRoute"
            out.mapSignature = mapSig(iu, fnName, "Resources")
            local allRoutes = {}
            for _, x in ipairs(playerCities()) do
                pcall(function()
                    local th = x.c.TradeHolder
                    if valid(th) then for _, r in ipairs(h.uarray(th.TradeRoutes)) do if valid(r) then allRoutes[#allRoutes + 1] = r end end end
                end)
            end
            out.mapEvidence = mapEvidence(allRoutes)
            pcall(function() out.tradingUnlocked = tu:IsTradingUnlocked(src) end)
            if existing then pcall(function() out.canActivate = try(tu, "CanActivateTradeRoute", { existing }) end) end
            if args.dryRun then return out end
            if out.tradingUnlocked == false then error("trading is locked for the source city (IsTradingUnlocked false); not calling", 0) end
            if #over > 0 then error("amounts above the route limit " .. tostring(out.limit) .. ": " .. table.concat(over, ","), 0) end
            -- Gate on the Resources map type: the param's own key/value properties when readable, else stored route maps
            -- with UObject keys and number values, else only with unverifiedMap=true (risk E; save first).
            local gate
            if out.mapSignature.ok then gate = "signature"
            elseif out.mapSignature.keyType == nil and out.mapEvidence.ok then gate = "storedRouteMaps"
            elseif out.mapSignature.keyType == nil and args.unverifiedMap == true then gate = "unverifiedMap"
            else
                error("Resources map type not confirmed (signature " .. tostring(out.mapSignature.key) .. " -> " .. tostring(out.mapSignature.value) ..
                    ", stored route entries " .. tostring(out.mapEvidence.entries) .. "); pass unverifiedMap=true after a save to try anyway", 0)
            end
            out.mapGate = gate
            local vt = out.mapSignature.valueType
            local intValues = vt ~= "FloatProperty" and vt ~= "DoubleProperty" and not (vt == nil and (out.mapEvidence.floatValues or 0) > 0)
            local m = {}
            for id, v in pairs(merged) do
                local r = byId[id]
                if not valid(r) then error("resource " .. id .. " invalid before the call", 0) end
                m[r] = intValues and math.floor(v) or (v + 0.0)
            end
            local srcPath, tgtPath = reflect.path(src), reflect.path(tgt)
            if not (valid(src) and valid(tgt)) then error("city invalid before the call; not trading", 0) end
            reflect.assertSafeCall(iu[fnName], fnName, false)
            if existing then
                if not valid(existing) then error("route invalid before the call", 0) end
                iu:InstructUpdateTradeRoute(ctx(), existing, tgt, m)
            else
                iu:InstructCreateTradeRoute(ctx(), src, tgt, m)
            end
            local s2, t2 = fresh(srcPath), fresh(tgtPath)
            if s2 and t2 then
                pcall(function()
                    local r = tu:GetCityTradeRoute(s2, t2)
                    if valid(r) then out.after = routeInfo(tu, r) end
                end)
            end
            return out
        end,
    })

    ---------------------------------------------------------------------------
    -- people

    -- Unit types in the unit config (PXGameplayUtils.GetUnitConfig): object properties whose value is a PXUnitType.
    local function unitTypes()
        local out = {}
        local cfg = call(function() return cdo("PXGameplayUtils"):GetUnitConfig() end)
        if not valid(cfg) then return out end
        local cls = call(function() return cfg:GetClass() end)
        reflect.forEachProperty(cls, function(p)
            local t = reflect.propType(p)
            if t == "ObjectProperty" or t == "ObjectPtrProperty" then
                local name = reflect.propName(p)
                local v = call(function() return cfg[name] end)
                if valid(v) and (reflect.className(v) or ""):find("UnitType", 1, true) then
                    out[#out + 1] = { prop = name, id = assetId(v), ref = reflect.path(v), obj = v }
                end
            end
        end)
        return out
    end

    local function pickUnitType(want)
        local list = unitTypes()
        local w = want and tostring(want):lower() or nil
        local function hay(u) return ((u.prop or "") .. "|" .. (u.id or "")):lower() end
        if w then
            for _, u in ipairs(list) do if u.ref == want or hay(u):find(w, 1, true) then return u, list end end
            return nil, list
        end
        for _, key in ipairs({ "relocat", "communit", "transfer", "people", "colon" }) do
            for _, u in ipairs(list) do if hay(u):find(key, 1, true) then return u, list end end
        end
        return nil, list
    end

    def("transfer_people", {
        mutation = true,
        help = "Send people of one community from one player city to another by a relocation unit (PXUnitUtils.AssignUnitToRelocateCommunityOrder; they travel). args: to (city selector, required), from (default main city), community (type substring; default the source's largest), amount (required), unit (unit type prop/id substring from the unit config; default the relocation one), dryRun. dryRun lists unit types, size, minimum left behind, relocation in progress and the trail.",
        run = function(args)
            A.assertNoCutscene("transfer_people")
            local src = playerCity(args.from, "from", true)
            local tgt = playerCity(args.to, "to", false)
            if reflect.path(src) == reflect.path(tgt) then error("from and to are the same city", 0) end
            local amount = tonumber(args.amount)
            if not amount or amount <= 0 then error("amount required (> 0)", 0) end
            amount = math.floor(amount)
            local cu, commU, uu = cdo("PXCityUtils"), cdo("PXCommunityUtils"), cdo("PXUnitUtils")
            local comm, commType = pickCommunity(src, args.community)
            local out = { from = label(src, indexOf(src)), to = label(tgt, indexOf(tgt)), community = assetId(commType), amount = amount }
            pcall(function() out.size = commU:GetCommunitySize(ctx(), src, commType) end)
            pcall(function() out.cityCommunitiesSize = commU:GetCityCommunitiesSize(src) end)
            pcall(function() out.excluded = commU:IsCommunityExcludedFromRelocation(comm) end)
            pcall(function() out.accessibleFrom = cu:IsCityAccessible(src) end)
            pcall(function() out.accessibleTo = cu:IsCityAccessible(tgt) end)
            pcall(function() out.relocatingAlready = uu:IsAnyUnitRelocatingFromCity(ctx(), src) end)
            pcall(function()
                local ct = src.CityType
                if valid(ct) then
                    out.minimalSizeAfterTransfer = ct.MinimalCommunitySizeAfterTransfer
                    out.transportLimit = ct.TransportLimit
                end
            end)
            for k, v in pairs(trailInfo(src, tgt)) do out[k] = v end
            local unit, units = pickUnitType(args.unit)
            out.unitTypes = json.array()
            for _, u in ipairs(units) do out.unitTypes[#out.unitTypes + 1] = { prop = u.prop, id = u.id, ref = u.ref } end
            out.unitType = unit and unit.id or nil
            local blockers = json.array()
            if type(out.size) == "number" and amount > out.size then blockers[#blockers + 1] = "amount > community size " .. out.size end
            if type(out.minimalSizeAfterTransfer) == "number" and type(out.cityCommunitiesSize) == "number"
                and out.cityCommunitiesSize - amount < out.minimalSizeAfterTransfer then
                blockers[#blockers + 1] = "source would keep fewer than MinimalCommunitySizeAfterTransfer " .. out.minimalSizeAfterTransfer
            end
            if out.excluded == true then blockers[#blockers + 1] = "community excluded from relocation" end
            if out.accessibleTo == false then blockers[#blockers + 1] = "target city not accessible" end
            if out.relocatingAlready == true then blockers[#blockers + 1] = "a relocation from this city is already under way (one group at a time)" end
            if not unit then blockers[#blockers + 1] = "no relocation unit type found in the unit config (pass unit=<prop or id> from unitTypes)" end
            out.blockers = blockers
            if args.dryRun then return out end
            if #blockers > 0 then error("transfer blocked: " .. table.concat(blockers, "; "), 0) end
            local srcPath, tgtPath, typePath = reflect.path(src), reflect.path(tgt), reflect.path(commType)
            requireValid({ { "from", src }, { "to", tgt }, { "community", comm }, { "unitType", unit.obj } }, "transferring")
            reflect.assertSafeCall(uu.AssignUnitToRelocateCommunityOrder, "AssignUnitToRelocateCommunityOrder", false)
            uu:AssignUnitToRelocateCommunityOrder(ctx(), unit.obj, src, tgt, comm, amount)
            -- Do not touch src/tgt/comm or the returned order; re-find by path.
            local s2, t2, ty2 = fresh(srcPath), fresh(tgtPath), fresh(typePath)
            if s2 then
                pcall(function() out.relocatingNow = uu:IsAnyUnitRelocatingFromCity(ctx(), s2) end)
                if ty2 then pcall(function() out.sizeNow = commU:GetCommunitySize(ctx(), s2, ty2) end) end
                if t2 then
                    pcall(function() out.relocatingAmount = uu:GetUnitRelocatingFromCityAmount(ctx(), s2, t2) end)
                    pcall(function() out.relocatingProgress = uu:GetUnitRelocatingFromCityProgress(ctx(), s2, t2) end)
                end
            end
            if t2 and ty2 then pcall(function() out.targetSizeNow = commU:GetCommunitySize(ctx(), t2, ty2) end) end
            return out
        end,
    })

    -- Removed 2026-10-11: PXCityUtils.TransferCommunity(ctx, src, tgt, communityType, amount) moved 100 people
    -- INSTANTLY with no unit and no cost (measured: sizeNow 2487, targetSizeNow 100, relocatingNow false), which makes
    -- it a cheat-class direct population edit. Never call it from the bridge. The call was:
    --     cu:TransferCommunity(ctx(), src, tgt, commType, amount)

    ---------------------------------------------------------------------------
    -- colony unrest + stockpile-exchange components (refs only)

    def("colony_exchange", {
        help = "Colony unrest per player city (tension statistic, ColonyUnrest) and the PXStockpileExchangeComponent instances (count and refs only: no calls on them; the full read crashed the game, see MOD_GAPS).",
        run = function(args)
            local unrest = json.array()
            for _, x in ipairs(playerCities()) do
                local e = label(x.c, x.i)
                e.main = isMain(x.c)
                e.unrest = unrestOf(x.c)
                unrest[#unrest + 1] = e
            end
            local refs = json.array()
            for _, x in ipairs(FindAllOf("PXStockpileExchangeComponent") or {}) do
                local p = valid(x) and reflect.path(x) or nil
                if p and not p:find("Default__", 1, true) then refs[#refs + 1] = p end
            end
            return { unrest = unrest, exchangeComponents = { count = #refs, refs = refs } }
        end,
    })

    -- crashed live 2026-10-11: the first `fp2 colony_exchange` run of the version below killed the game:
    -- EXCEPTION_ACCESS_VIOLATION reading 0x150, stack Frostpunk2!AK::WriteBytesMem::SetCount <- UE4SS
    -- FAnsiString::operator= <- SinglePassScanner::string_to_vector <- process_lua_function (inside a UFunction call
    -- from Lua; the Wwise symbol is the nearest export, not necessarily the real frame). Not bisected. Candidates,
    -- ranked, are in MOD_GAPS.md ("colony_exchange crash"). Do not re-enable a call without a save and a one-call test.
    -- ---------------------------------------------------------------------------
    -- -- colony exchange (stockpile-exchange negotiation layer) + colony unrest
    --
    -- def("colony_exchange", {
    --     help = "Colony unrest per player city (tension statistic, ColonyUnrest) and every PXStockpileExchangeComponent (offer/negotiation state: state, waiting for player accept, time left, response progress, defiance threshold valid, resources to deliver). Read-only; offers and actions are not read (FText/untested maps).",
    --     run = function(args)
    --         local unrest = json.array()
    --         for _, x in ipairs(playerCities()) do
    --             local e = label(x.c, x.i)
    --             e.main = isMain(x.c)
    --             e.unrest = unrestOf(x.c)
    --             unrest[#unrest + 1] = e
    --         end
    --         local seu = cdo("PXStockpileExchangeUtils")
    --         local stateNames = reflect.enumNames("EPXStockpileExchangeState")
    --         local list = json.array()
    --         for _, x in ipairs(FindAllOf("PXStockpileExchangeComponent") or {}) do
    --             if valid(x) and not (reflect.path(x) or ""):find("Default__", 1, true) then
    --                 local e = { ref = reflect.path(x) }
    --                 pcall(function()
    --                     local o = x:GetOwner()
    --                     if valid(o) then e.owner = reflect.path(o); e.ownerClass = reflect.className(o) end
    --                 end)
    --                 pcall(function()
    --                     local s = x:GetCurrentState()
    --                     e.state = stateNames[s] or s
    --                 end)
    --                 pcall(function() e.waitingForPlayerAccept = x:IsWaitingForAcceptOfColonyOffer() end)
    --                 pcall(function() e.stateProgress = r1(x:GetTimeProgressInCurrentState()) end)
    --                 e.weeksLeftInState = weeks(try(x, "GetTimeLeftInCurrentState", {}))
    --                 pcall(function() e.defianceAllowsNegotiation = seu:IsDefianceThresholdValidForNegotiations(ctx(), x) end)
    --                 pcall(function() e.hasResourceToDeliver = seu:HasResourceToDeliver(ctx(), x) end)
    --                 pcall(function()
    --                     local f = seu.GetResponseTimeAndProgress
    --                     reflect.assertSafeCall(f, "GetResponseTimeAndProgress", false)
    --                     local p, t = {}, {}
    --                     seu:GetResponseTimeAndProgress(ctx(), x, p, t)
    --                     e.responseProgress = r1(p.outProgress)
    --                     if type(t.ScaledTicks) == "number" then e.responseWeeks = r1(t.ScaledTicks / 1680) end
    --                 end)
    --                 pcall(function()
    --                     local q = x:GetQuest()
    --                     if valid(q) then e.quest = reflect.path(q) end
    --                 end)
    --                 list[#list + 1] = e
    --             end
    --         end
    --         local tiers = json.array()
    --         pcall(function()
    --             local n = seu:GetStockpileExchangeTiersNum()
    --             for i = 0, math.min(n or 0, 20) - 1 do tiers[#tiers + 1] = seu:GetStockpileExchangeTierValue(i) end
    --         end)
    --         return { unrest = unrest, exchanges = list, tierValues = tiers }
    --     end,
    -- })
end

return M
