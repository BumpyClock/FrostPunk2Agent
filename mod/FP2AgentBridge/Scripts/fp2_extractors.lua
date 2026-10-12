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
                    pcall(function() e.temperatureC = temp.CurrentTemperatureLevel.Degrees end)
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
        name = "districtDeposits",
        help = "Deposits worked by deposit-requiring districts (Extraction, ...): district label, deposit ref, type, amount. Used by the turn watcher for deposit.depleting (trend between snapshots).",
        run = function()
            local out = json.array()
            local du = StaticFindObject("/Script/Frostpunk2.Default__PXDistrictUtils")
            local depu = StaticFindObject("/Script/Frostpunk2.Default__PXDepositUtils")
            local c = cities()[1]
            if not c or not reflect.isValid(du) or not reflect.isValid(depu) then return out end
            for _, d in ipairs(c:GetDistricts() or {}) do
                if type(d) == "userdata" and not reflect.isValid(d) then pcall(function() d = d:get() end) end
                pcall(function()
                    if not reflect.isValid(d) or not du:IsDistrictRequiringDeposits(d.DistrictType) then return end
                    local label = (assetId(d.DistrictType) or "?") .. "#" .. tostring(d.DistrictId)
                    for _, dep in ipairs(depu:GetDepositsUsedByDistrict(d) or {}) do
                        if type(dep) == "userdata" and not reflect.isValid(dep) then pcall(function() dep = dep:get() end) end
                        if reflect.isValid(dep) then
                            out[#out + 1] = { district = label, ref = reflect.path(dep), type = assetId(dep.depositType) or "?", amount = dep.Amount }
                        end
                    end
                end)
            end
            return out
        end,
    })
    -- Weather: current temperature level and the HUD forecast strip (top right).
    -- Data path (static, from research/fp2_functions.txt and research/city/PXTemperatureComponent.json):
    --   current  PXTemperatureComponent.CurrentTemperatureLevel (PXTemperatureLevel asset; .Degrees measured in `population`)
    --   horizon  PXTemperatureComponent.PredictionInterval (PXGameTime; 168000 ticks in the research dump)
    --   forecast PXTemperatureUtils.GetTemperatureTimeline(WorldContextObject, Target:PXTemperatureComponent, From, To)
    --            -> TArray<PXTemperatureTimelineChangeInfo> {Timestamp:PXGameTime, TemperatureLevel:PXTemperatureLevel,
    --            TemperatureLevelChange:Int, Weather:PXWeatherSpawnInfo (nil unless a storm boundary),
    --            EnterWeatherIntersection:Bool} (measured). Elements arrive as wrappers: unwrap with `:get()`.
    --            The Target class and fields are still read by reflection and the call is refused when the entry struct
    --            holds FText or SoftObject fields.
    --   whiteout an entry with `Weather` set: EnterWeatherIntersection true = the storm reaches the city, false = it
    --            leaves (measured: the exit entry carried TemperatureLevelChange -3). Active while
    --            PXWeatherUtils.GetCityWeatherLevel(ctx, City) returns a PXWeatherLevel (measured: "Sun-Dimming Storm").
    -- TemperatureLevel numbers rise as it gets colder (DA_TemperatureLevel1 -> 4 was a whiteout, measured).
    local TICKS_WEEK = 1680
    local function hasSoft(prop, depth)
        if depth > 6 then return false end
        if reflect.unsafeRead(prop) then return true end
        local t = reflect.propType(prop)
        if t == "StructProperty" then
            local ok, sd = pcall(function() return prop:GetStruct() end)
            if not ok or not reflect.isValid(sd) then return false end
            local found = false
            reflect.forEachProperty(sd, function(p)
                if hasSoft(p, depth + 1) then found = true; return true end
            end)
            return found
        elseif t == "ArrayProperty" or t == "SetProperty" then
            local ok, inner = pcall(function() return prop:GetInner() end)
            return ok and inner ~= nil and hasSoft(inner, depth + 1)
        elseif t == "MapProperty" then
            local okK, k = pcall(function() return prop:GetKeyProp() end)
            local okV, v = pcall(function() return prop:GetValueProp() end)
            return (okK and k ~= nil and hasSoft(k, depth + 1)) or (okV and v ~= nil and hasSoft(v, depth + 1))
        end
        return false
    end

    X.register({
        name = "weather",
        help = "Temperature now and the forecast strip: current level/degrees, forecast [{weeksFromNow, level, degrees, whiteout (starts here), whiteoutEnds}], whiteout {known, active, startsInWeeks, endsInWeeks}, storm {id, name, level} while one covers the city. args: weeks=<horizon, default the game's prediction interval>, debug=true (entry schema, raw fields).",
        run = function(args)
            local debug = args.debug == true or args.debug == "true"
            local out = { forecast = json.array() }
            local wco = FindFirstOf("PlayerController")
            if not reflect.isValid(wco) then return { missing = "PlayerController" } end
            local city = cities()[1]
            if not city then return { missing = "city" } end
            local owner = (reflect.path(city) or ""):match("^(.*)%.[^%.]+$") or ""

            -- A component on the main city actor (path prefix), so no guessed object reaches a game call.
            local function cityComponent(className, allowOther)
                local other
                for _, c in ipairs(FindAllOf(className) or {}) do
                    if reflect.isValid(c) then
                        local p = reflect.path(c) or ""
                        if not p:find("Default__", 1, true) then
                            if owner ~= "" and p:sub(1, #owner + 1) == owner .. "." then return c end
                            other = other or c
                        end
                    end
                end
                if allowOther then return other end
                return nil
            end

            local function levelInfo(lv)
                if not reflect.isValid(lv) then return nil end
                local id = assetId(lv)
                local info = { id = id, level = tonumber((id or ""):match("(%d+)$")) }
                pcall(function() info.degrees = lv.Degrees end)
                pcall(function()
                    reflect.forEachProperty(lv:GetClass(), function(p)
                        local n = reflect.propName(p)
                        if n:lower():find("whiteout", 1, true) and reflect.propType(p) == "BoolProperty" then
                            pcall(function() info.whiteout = lv[n] == true end)
                        end
                    end)
                end)
                return info
            end

            local tc = cityComponent("PXTemperatureComponent", true)
            local predictionTicks
            if reflect.isValid(tc) then
                pcall(function() out.current = levelInfo(tc.CurrentTemperatureLevel) end)
                pcall(function() predictionTicks = tc.PredictionInterval.ScaledTicks end)
                if predictionTicks then out.predictionWeeks = math.floor(predictionTicks / 168 + 0.5) / 10 end
            end
            pcall(function()
                -- Call only when the City param is declared as PXCityComponent (a wrong-class object can crash natively).
                local wu = StaticFindObject("/Script/Frostpunk2.Default__PXWeatherUtils")
                if not reflect.isValid(wu) then return end
                local wf = wu.GetCityWeatherLevel
                if not reflect.isValid(wf) or #reflect.unsafeParams(wf) > 0 then return end
                local cityClass
                wf:ForEachProperty(function(p)
                    if reflect.propName(p) == "City" then cityClass = reflect.shortName(p:GetPropertyClass()) end
                end)
                if cityClass ~= "PXCityComponent" then out.stormSkipped = "City param class " .. tostring(cityClass); return end
                local lv = wu:GetCityWeatherLevel(wco, city)
                if reflect.isValid(lv) then
                    -- Always set: "Calm" (WeatherLevel_0, level 0) with no storm, "Sun-Dimming Storm" (level 1) mid-whiteout (measured).
                    local st = { id = assetId(lv) }
                    pcall(function() st.name = lv.IngameName:ToString() end)
                    pcall(function() st.level = lv.Level end)
                    out.storm = st
                end
            end)

            local now
            pcall(function() now = FindFirstOf("PXTimeSubsystem").currentGameTime.ScaledTicks end)
            if type(now) ~= "number" then out.timelineError = "no game time"; return out end
            out.nowTicks = now

            -- Signature check before the first call (FText/SoftObject in the entry struct crash UE4SS).
            local tu = StaticFindObject("/Script/Frostpunk2.Default__PXTemperatureUtils")
            if not reflect.isValid(tu) then out.timelineError = "no PXTemperatureUtils"; return out end
            local fn = tu.GetTemperatureTimeline
            if not reflect.isValid(fn) then out.timelineError = "no GetTemperatureTimeline"; return out end
            local sig = {}
            pcall(function() fn:ForEachProperty(function(p) sig[reflect.propName(p)] = p end) end)
            local bad = reflect.unsafeParams(fn)
            if #bad > 0 then out.timelineError = "FText in params " .. table.concat(bad, ","); return out end
            if not sig.Target or not sig.From or not sig.To or not sig.ReturnValue then out.timelineError = "unexpected signature"; return out end
            if reflect.paramTypeName(sig.From) ~= "Struct<PXGameTime>" or reflect.paramTypeName(sig.To) ~= "Struct<PXGameTime>" then
                out.timelineError = "From/To not PXGameTime: " .. reflect.paramTypeName(sig.From)
                return out
            end
            if hasSoft(sig.ReturnValue, 0) then out.timelineError = "SoftObject in timeline entries"; return out end
            local targetClass
            pcall(function() targetClass = reflect.shortName(sig.Target:GetPropertyClass()) end)
            local fields = {}
            pcall(function()
                local sd = sig.ReturnValue:GetInner():GetStruct()
                out.entryStruct = reflect.shortName(sd)
                reflect.forEachProperty(sd, function(p)
                    fields[#fields + 1] = { name = reflect.propName(p), type = reflect.paramTypeName(p) }
                end)
            end)
            if debug then
                out.targetClass = targetClass
                local schema = json.array()
                for _, f in ipairs(fields) do schema[#schema + 1] = f.name .. ":" .. f.type end
                out.entrySchema = schema
            end
            if #fields == 0 then out.timelineError = "timeline entry struct not readable"; return out end

            local target
            if targetClass == "PXCityComponent" then
                target = city
            elseif targetClass == "PXTemperatureComponent" then
                target = tc
            elseif targetClass and targetClass:match("^PX.+Component$") then
                target = cityComponent(targetClass, false)
            end
            if not reflect.isValid(target) then
                out.timelineError = "no safe Target for class " .. tostring(targetClass)
                return out
            end

            -- Default to the game's whole prediction interval: the whiteout story warning came 73 weeks ahead
            -- (measured), so a short cap would hide the one forecast entry that matters most.
            local horizon = predictionTicks and predictionTicks > 0 and predictionTicks or 104 * TICKS_WEEK
            if tonumber(args.weeks) then horizon = math.min(horizon, tonumber(args.weeks) * TICKS_WEEK)
            else horizon = math.min(horizon, 104 * TICKS_WEEK) end
            -- Start 4 weeks back so an ongoing segment (e.g. an active whiteout) is in the list.
            local from = math.max(0, now - 4 * TICKS_WEEK)
            local raw = tu:GetTemperatureTimeline(wco, target, { ScaledTicks = from }, { ScaledTicks = now + horizon })
            local items = {}
            if type(raw) == "table" then
                for _, e in ipairs(raw) do items[#items + 1] = e end
            elseif type(raw) == "userdata" then
                pcall(function() raw:ForEach(function(_, e) items[#items + 1] = e:get() end) end)
            end
            out.horizonWeeks = math.floor(horizon / 168 + 0.5) / 10

            local entries = {}
            local parsedAll = {}
            local sawWhiteoutField = (out.current and out.current.whiteout ~= nil) or false
            for _, item in ipairs(items) do
                local e = { other = {}, errors = {} }
                -- Array elements of a UFunction return may arrive as element wrappers: unwrap when `get` exists.
                pcall(function()
                    if type(item) == "userdata" and item.get then
                        local g = item:get()
                        if g ~= nil then item = g end
                    end
                end)
                if debug then e.itemType = type(item); pcall(function() e.itemStr = tostring(item) end) end
                for _, f in ipairs(fields) do
                    local name, ty = f.name, f.type
                    local isWo = name:lower():find("whiteout", 1, true) ~= nil
                    local okF, errF = pcall(function()
                        local v = item[name]
                        if debug and v == nil then e.errors[name] = "nil" end
                        if ty == "Struct<PXGameTime>" then
                            local ticks = v.ScaledTicks
                            if isWo then
                                sawWhiteoutField = true
                                e.whiteoutTicks = ticks
                                if ticks > 0 then e.whiteout = true end
                            elseif e.at == nil then
                                e.at = ticks
                                e.atField = name
                            else
                                e.other[name] = ticks
                            end
                        elseif ty:find("^Object") then
                            if reflect.isValid(v) then
                                local cls = reflect.className(v) or ""
                                if cls:find("TemperatureLevel", 1, true) and not e.levelInfo then
                                    e.levelInfo = levelInfo(v)
                                    if e.levelInfo and e.levelInfo.whiteout ~= nil then sawWhiteoutField = true end
                                elseif isWo then
                                    sawWhiteoutField = true
                                    e.whiteout = true
                                else
                                    e.other[name] = assetId(v)
                                end
                            elseif isWo then
                                sawWhiteoutField = true
                            end
                        elseif ty == "Bool" then
                            if isWo then
                                sawWhiteoutField = true
                                if v == true then e.whiteout = true end
                            else
                                e.other[name] = v
                            end
                        elseif type(v) == "number" or type(v) == "boolean" then
                            e.other[name] = v
                            if ty == "Int" and name:lower():find("change", 1, true) then e.change = v end
                        end
                    end)
                    if not okF and debug then e.errors[name] = tostring(errF) end
                end
                if e.levelInfo and e.levelInfo.whiteout then e.whiteout = true end
                parsedAll[#parsedAll + 1] = e
                if type(e.at) == "number" then entries[#entries + 1] = e end
            end
            table.sort(entries, function(a, b) return a.at < b.at end)

            local function weeks(ticks) return math.floor((ticks - now) / 168 + 0.5) / 10 end
            -- Whiteout representation (measured mid-whiteout, week 226): a timeline entry whose `Weather` field holds a
            -- PXWeatherSpawnInfo marks the storm reaching (EnterWeatherIntersection true) or leaving (false) the city;
            -- the exit entry carried TemperatureLevelChange -3 (level 4 -> 1). While the storm is over the city,
            -- PXWeatherUtils.GetCityWeatherLevel returns its PXWeatherLevel ("Sun-Dimming Storm", level 1); otherwise
            -- "Calm" (level 0). At week 129 the strip already held the whiteout 70.6 weeks ahead (measured).
            local wo = { known = true, active = (out.storm ~= nil and tonumber(out.storm.level) or 0) >= 1 }
            -- Entries that hold a relative Change (SetTemperatureLevelChangeAt) instead of a level: accumulate from now.
            local running = out.current and out.current.level
            for _, e in ipairs(entries) do
                local weather = e.other.Weather ~= nil
                local enter = weather and e.other.EnterWeatherIntersection == true
                local exit = weather and e.other.EnterWeatherIntersection == false
                if e.at > now then
                    local li = e.levelInfo or {}
                    local level, derived = li.level, nil
                    if level == nil and running and e.change then level = running + e.change; derived = true end
                    if level then running = level end
                    local item = { atTicks = e.at, weeksFromNow = weeks(e.at), level = level, levelId = li.id, degrees = li.degrees, whiteout = enter, derivedLevel = derived }
                    if exit then item.whiteoutEnds = true end
                    if debug then item.atField = e.atField; item.fields = e.other end
                    out.forecast[#out.forecast + 1] = item
                    if enter and wo.startsInWeeks == nil and not wo.active then
                        wo.startsInWeeks = weeks(e.at)
                        wo.startsAtTicks = e.at
                    elseif exit and wo.endsInWeeks == nil and (wo.active or wo.startsInWeeks ~= nil) then
                        wo.endsInWeeks = weeks(e.at)
                        wo.endsAtTicks = e.at
                    end
                end
            end
            out.whiteout = wo
            if debug then
                local dump = json.array()
                for i, e in ipairs(entries) do
                    if i > 6 then break end
                    dump[#dump + 1] = { at = e.at, atField = e.atField, level = e.levelInfo, whiteout = e.whiteout, whiteoutTicks = e.whiteoutTicks, fields = e.other }
                end
                out.entries = dump
                out.entryCount = #items
                -- Entries that failed to parse: their per-field errors (debug only).
                local failed = json.array()
                for _, e in ipairs(parsedAll) do
                    if type(e.at) ~= "number" and #failed < 3 then failed[#failed + 1] = { itemType = e.itemType, itemStr = e.itemStr, errors = e.errors, fields = e.other } end
                end
                out.unparsed = failed
            end
            return out
        end,
    })

    X.register({
        name = "construction",
        help = "Active constructions: what, state, progress 0..1, weeks left.",
        inState = true,
        run = function()
            local out = json.array()
            -- Building actors under construction: owner actor path -> building type.
            local buildingTypeByOwner = {}
            for _, b in ipairs(FindAllOf("PXBuildingComponent") or {}) do
                pcall(function()
                    if reflect.isValid(b) then buildingTypeByOwner[reflect.path(b:GetOwner())] = b.Type end
                end)
            end
            for _, c in ipairs(FindAllOf("PXConstructionComponent") or {}) do
                if reflect.isValid(c) and not (reflect.path(c) or ""):find("Default__", 1, true) then
                    local state = "?"
                    pcall(function() state = reflect.get(c, "State").name:gsub("^.*::", "") end)
                    if state ~= "Finished" then
                        local e = { state = state }
                        pcall(function()
                            local owner = c:GetOwner()
                            e.target = reflect.className(owner)
                            local bt = buildingTypeByOwner[reflect.path(owner)]
                            if bt and reflect.isValid(bt) then
                                e.building = (reflect.shortName(bt) or ""):gsub("^DA_", "")
                                pcall(function() e.name = bt.IngameName:ToString() end)
                            end
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
    X.register({
        name = "society",
        help = "Total trust, population, and per-community size/standing (HUD faction bar).",
        inState = true,
        run = function()
            local wco = FindFirstOf("PlayerController")
            local tu = StaticFindObject("/Script/Frostpunk2.Default__PXTrustUtils")
            local cu = StaticFindObject("/Script/Frostpunk2.Default__PXCommunityUtils")
            return forEachCity(function(city, e)
                local nation = city.Nation
                pcall(function() e.totalTrust = tu:GetTotalTrust(wco, nation) end)
                pcall(function() e.population = cu:GetScaledCityPopulationSize(city) end)
                pcall(function() e.communitiesSize = cu:GetCityCommunitiesSize(city) end)
                local comms = json.array()
                pcall(function()
                    for _, c in ipairs(list(cu:GetCommunitiesSortedBySize(city))) do
                        local ce = { community = assetId(c.Type) or reflect.shortName(c) }
                        pcall(function() ce.size = c.Size end)
                        pcall(function() ce.standing = math.floor(tu:GetCommunityStanding(wco, nation, c) * 10 + 0.5) / 10 end)
                        pcall(function() ce.fervor = c.Fervor end)
                        comms[#comms + 1] = ce
                    end
                end)
                e.communities = comms
                -- HUD "Death toll" counter (WBP_UnnaturalDeathCounterWidget_C) and its death-meter script.
                pcall(function()
                    local w = FindFirstOf("WBP_UnnaturalDeathCounterWidget_C")
                    e.deathToll = w.TargetDeathCount
                    local script = w.DeathMeterScript
                    local causes = json.object()
                    script["Special Cause Deaths"]:ForEach(function(k, v)
                        local key = k:get()
                        local val = v:get()
                        causes[(reflect.shortName(key) or "?"):gsub("^DA_S2F_", ""):gsub("_DeathCause$", "")] = type(val) == "number" and val or reflect.plain(val, 1)
                    end)
                    e.deathsByCause = causes
                end)
            end)
        end,
    })
end
