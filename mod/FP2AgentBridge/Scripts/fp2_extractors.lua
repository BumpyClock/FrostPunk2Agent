-- Frostpunk 2 specific extractors. Populated from live discovery; see
-- .agents/skills/play-frostpunk2/references/DATA_MAP.md for provenance and units.

local json = require("json")
local reflect = require("reflect")
local geo = require("geo")

-- Data-asset path -> short id: ".../DA_Core_FoodResource.DA_Core_FoodResource" -> "Core_FoodResource"
local function assetId(obj)
    local n = reflect.shortName(obj)
    if not n then return nil end
    return (n:gsub("^DA_", ""))
end

-- TMap<UObject*, number> -> { id = value }
local function assetMap(map)
    local out = json.object()
    if map == nil then return out end
    pcall(function()
        map:ForEach(function(k, v)
            local key = k.get and k:get() or k
            local val = v.get and v:get() or v
            local id = assetId(key) or tostring(key)
            if type(val) == "userdata" then val = reflect.plain(val, 1) end
            out[id] = val
        end)
    end)
    return out
end

local function cities()
    local list = {}
    for _, c in ipairs(FindAllOf("PXCityComponent") or {}) do
        if reflect.isValid(c) and not (reflect.path(c) or ""):find("Default__", 1, true) then
            list[#list + 1] = c
        end
    end
    return list
end

local function cityLabel(city)
    local label = { ref = reflect.path(city) }
    pcall(function() label.cityType = assetId(city.CityType) end)
    return label
end

local function forEachCity(fn)
    local out = json.array()
    for _, city in ipairs(cities()) do
        local entry = cityLabel(city)
        local ok, err = pcall(fn, city, entry)
        if not ok then entry.error = tostring(err) end
        out[#out + 1] = entry
    end
    return out
end

local stockpileUtils
local function utils()
    if not reflect.isValid(stockpileUtils) then
        stockpileUtils = StaticFindObject("/Script/Frostpunk2.Default__PXStockpileUtils")
    end
    return stockpileUtils
end

return function(X)
    X.register({
        name = "time",
        help = "Game clock: pause state + reasons, speed level, raw game time ticks, start date.",
        inState = true,
        run = function()
            local t = FindFirstOf("PXTimeSubsystem")
            if not reflect.isValid(t) then return { missing = "PXTimeSubsystem" } end
            local out = {}
            pcall(function() out.speed = reflect.get(t, "CurrentGameSpeedLevel").name end)
            pcall(function() out.pause = reflect.get(t, "PauseState") end)
            pcall(function() out.speedLock = reflect.get(t, "LockTimeSpeedState") end)
            pcall(function() out.gameplayBegan = t.GameplayBegan end)
            pcall(function() out.gameTimeTicks = t.currentGameTime.ScaledTicks end)
            pcall(function() out.startDateDays = t.StartDate.Days end)
            pcall(function() out.logicTicks = t.LogicTicksPassedCount end)
            if out.pause then
                out.paused = out.pause.paused
                out.pauseReasons = out.pause.PauseReasons
                out.pause = nil
            end
            return out
        end,
    })

    X.register({
        name = "resources",
        help = "Per city: stock, stock limits, weekly supply/demand targets, and per-update change (via PXStockpileUtils).",
        inState = true,
        run = function()
            return forEachCity(function(city, e)
                local sp = city.stockpile
                e.stock = assetMap(sp.Stock)
                e.limits = assetMap(sp.StockLimits)
                local eh = city.EconomyHolder
                e.supply = assetMap(eh.TargetSupply)
                e.demand = assetMap(eh.TargetDemand)
                local u = utils()
                if reflect.isValid(u) then
                    local change = json.object()
                    pcall(function()
                        sp.Stock:ForEach(function(k)
                            local res = k.get and k:get() or k
                            local ok, v = pcall(function() return u:GetCityStockpileChangeOfResource(city, res) end)
                            if ok then change[assetId(res)] = v end
                        end)
                    end)
                    e.change = change
                end
            end)
        end,
    })

    X.register({
        name = "needs",
        help = "Per city: needs required vs fulfilled (Shelter, Warmth/Heating, Nourishment, Possession, Maintenance) and balance.",
        inState = true,
        run = function()
            return forEachCity(function(city, e)
                local nh = city.NeedHolder
                local req = assetMap(nh.NeedsRequired)
                local ful = assetMap(nh.NeedsFulfilled)
                local needs = json.object()
                for id, r in pairs(req) do
                    local f = ful[id] or 0
                    needs[id] = { required = r, fulfilled = f, balance = f - r }
                end
                e.needs = needs
            end)
        end,
    })

    X.register({
        name = "statistics",
        help = "Per city: current vs target statistics (Cold, Hunger, Sickliness, Crime, Squalor, Tension, Homelessness, ...). Higher = worse.",
        inState = true,
        run = function()
            return forEachCity(function(city, e)
                local sh = city.statisticHolder
                e.current = assetMap(sh.CurrentStatistics)
                e.target = assetMap(sh.TargetStatistics)
            end)
        end,
    })

    X.register({
        name = "population",
        help = "Per city: workforce total, homeless count, community sizes, temperature level, generator power.",
        inState = true,
        run = function()
            return forEachCity(function(city, e)
                pcall(function() e.totalWorkforce = city.WorkforceHolder.TotalWorkforce end)
                pcall(function() e.homeless = city.peopleAllocationHolderComponent.HomelessCount end)
                pcall(function()
                    local sizes = json.object()
                    local total = 0
                    city.peopleAllocationHolderComponent.UnassignedCommunitySizes:ForEach(function(k, v)
                        local comm = k.get and k:get() or k
                        local size = v.get and v:get() or v
                        local name = reflect.shortName(comm)
                        pcall(function() name = assetId(comm.Type) or name end)
                        sizes[name] = (sizes[name] or 0) + size
                        total = total + size
                    end)
                    e.communitySizes = sizes
                    e.population = total
                end)
                pcall(function()
                    local temp = FindFirstOf("PXTemperatureComponent")
                    e.temperatureLevel = assetId(temp.CurrentTemperatureLevel)
                end)
                pcall(function()
                    local g = city.Generator
                    if reflect.isValid(g) then
                        e.generator = {
                            power = g:GetPowerProduction(),
                            potentialPower = g:GetPotentialPowerProduction(),
                            fuel = g:GetFuelProduction(),
                            mode = assetId(g:GetCurrentMode()),
                        }
                    end
                end)
            end)
        end,
    })

    X.register({
        name = "districts",
        help = "Per city: district list with type ids (args: limit=100).",
        run = function(args)
            local limit = tonumber(args.limit) or 100
            return forEachCity(function(city, e)
                local list = json.array()
                city.districtHolder.Districts:ForEach(function(i, d)
                    if i > limit then return true end
                    local dc = d:get()
                    local item = { ref = reflect.path(dc) }
                    pcall(function() item.type = assetId(dc.DistrictType or dc.Type) end)
                    list[#list + 1] = item
                end)
                e.districts = list
            end)
        end,
    })
    X.register({
        name = "deposits",
        help = "Resource deposits sorted by distance to the main city: type, amount, world + screen position. args: limit=30, type (substring), maxDistance",
        run = function(args)
            local limit = tonumber(args.limit) or 30
            local filter = args.type and tostring(args.type):lower() or nil
            local center
            local c = cities()[1]
            if c then center = geo.location(c) end
            local list = {}
            for _, d in ipairs(FindAllOf("PXDepositComponent") or {}) do
                if reflect.isValid(d) and not (reflect.path(d) or ""):find("Default__", 1, true) then
                    local t = assetId(d.depositType) or "?"
                    if not filter or t:lower():find(filter, 1, true) then
                        local loc = geo.location(d)
                        local dist = (loc and center) and math.sqrt((loc.X - center.X) ^ 2 + (loc.Y - center.Y) ^ 2) or nil
                        if not args.maxDistance or (dist and dist <= tonumber(args.maxDistance)) then
                            list[#list + 1] = { ref = reflect.path(d), type = t, amount = d.Amount, location = loc, distance = dist and math.floor(dist) or nil }
                        end
                    end
                end
            end
            table.sort(list, function(a, b) return (a.distance or 1e18) < (b.distance or 1e18) end)
            local out = json.array()
            for i = 1, math.min(limit, #list) do
                local e = list[i]
                e.screen = e.location and geo.project(e.location) or nil
                out[#out + 1] = e
            end
            return { total = #list, cityCenter = center, items = out }
        end,
    })
    X.register({
        name = "construction",
        help = "Active constructions: what, state, progress 0..1, weeks left.",
        inState = true,
        run = function()
            local out = json.array()
            for _, c in ipairs(FindAllOf("PXConstructionComponent") or {}) do
                if reflect.isValid(c) and not (reflect.path(c) or ""):find("Default__", 1, true) then
                    local state = "?"
                    pcall(function() state = reflect.get(c, "State").name:gsub("^.*::", "") end)
                    if state ~= "Finished" then
                        local e = { state = state }
                        pcall(function()
                            local owner = c:GetOwner()
                            e.target = reflect.className(owner)
                            pcall(function()
                                for _, comp in ipairs({ "PXDistrictComponent" }) do end
                            end)
                        end)
                        pcall(function()
                            local d = c.ParentComponent
                            if reflect.isValid(d) and d.DistrictType then e.district = assetId(d.DistrictType) end
                        end)
                        pcall(function()
                            local op = c.Operation
                            if reflect.isValid(op) then
                                e.progress = math.floor(op.Progress * 1000 + 0.5) / 1000
                                local dur = op.Cost.Duration.ScaledTicks
                                e.weeksLeft = math.floor((1 - op.Progress) * dur / 1680 * 10 + 0.5) / 10
                            end
                        end)
                        e.ref = reflect.path(c)
                        out[#out + 1] = e
                    end
                end
            end
            return out
        end,
    })
    local function txt(v)
        if v == nil then return nil end
        local ok, s = pcall(function() return v:ToString() end)
        if ok and s ~= "" then return s end
        return nil
    end

    local function list(v)
        local out = {}
        if type(v) == "table" then
            for _, x in ipairs(v) do
                if type(x) == "userdata" and not reflect.isValid(x) then pcall(function() x = x:get() end) end
                if reflect.isValid(x) then out[#out + 1] = x end
            end
        end
        return out
    end

    X.register({
        name = "quests",
        help = "Active quests/ambitions with objectives (name, progress/max) and time left.",
        inState = true,
        run = function()
            local qu = StaticFindObject("/Script/Frostpunk2.Default__PXQuestUtils")
            local wco = FindFirstOf("PlayerController")
            local out = json.array()
            for _, q in ipairs(list(qu:GetActiveQuests(wco))) do
                local e = { class = reflect.className(q) }
                pcall(function() e.name = txt(q:GetQuestName()) end)
                pcall(function() e.description = txt(q:GetQuestDescription()) end)
                pcall(function()
                    if not q:HasEndlessDuration() then
                        e.weeksLeft = math.floor(qu:GetQuestTimeLeft(wco, q).ScaledTicks / 168 + 0.5) / 10
                    end
                end)
                local objs = json.array()
                pcall(function()
                    for _, o in ipairs(list(q:GetQuestObjectives())) do
                        local oe = {}
                        pcall(function() oe.name = txt(o:GetObjectiveName()) end)
                        pcall(function() oe.progress = o:GetObjectiveProgress() end)
                        pcall(function() oe.max = o:GetObjectiveMaxProgress() end)
                        if not oe.name then pcall(function() oe.debug = o:GetObjectiveDebugName():ToString() end) end
                        objs[#objs + 1] = oe
                    end
                end)
                e.objectives = objs
                out[#out + 1] = e
            end
            return out
        end,
    })

    X.register({
        name = "icons",
        help = "On-map tracker icons (events, community actions, warnings, frostland pins): kind, target, world + screen position. args: all=true includes hidden",
        inState = true,
        run = function(args)
            local out = json.array()
            for _, w in ipairs(FindAllOf("PXTrackerPanel") or {}) do
                if reflect.isValid(w) and not (reflect.path(w) or ""):find("Default__", 1, true) then
                    local visible = true
                    pcall(function() visible = w:IsVisible() end)
                    if visible or (args and args.all) then
                        local e = { kind = (reflect.className(w) or "?"):gsub("^WBP_", ""):gsub("_C$", ""), ref = reflect.path(w) }
                        pcall(function()
                            local tc = w:GetTrackerComponent()
                            if reflect.isValid(tc) then
                                local owner = tc:GetOwner()
                                e.target = reflect.className(owner)
                                local loc = geo.location(owner)
                                if loc then
                                    e.location = { X = math.floor(loc.X), Y = math.floor(loc.Y) }
                                    local sc = geo.project(loc)
                                    if sc then e.screen = { sc.x, sc.y } end
                                end
                            end
                        end)
                        pcall(function()
                            local d = w:TryGetOwningDistrict()
                            if reflect.isValid(d) then e.district = assetId(d.DistrictType) end
                        end)
                        out[#out + 1] = e
                    end
                end
            end
            return out
        end,
    })
end
