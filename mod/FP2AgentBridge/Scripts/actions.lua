-- Gameplay actions through the game's own command layer (PXInstructionUtils, PXTimeUtils,
-- PX*Utils validators). Every mutating action supports dryRun=true, which only validates
-- and prices. Actions use the Leader ActionOrigin (= the player).

local json = require("json")
local reflect = require("reflect")
local geo = require("geo")

local A = {}

local function cdo(name)
    local o = StaticFindObject("/Script/Frostpunk2.Default__" .. name)
    if not reflect.isValid(o) then error("missing " .. name, 0) end
    return o
end

local function assetId(obj)
    local n = reflect.shortName(obj)
    return n and (n:gsub("^DA_", "")) or nil
end

local function ctx()
    local pc = FindFirstOf("PlayerController")
    if not reflect.isValid(pc) then error("no PlayerController (not in a game?)", 0) end
    return pc
end

local function world() return ctx():GetWorld() end

function A.leaderOrigin()
    local cfg = cdo("PXGameplayUtils"):GetActionOriginConfig()
    return cfg.LeaderOrigin
end

function A.cities()
    local list = {}
    for _, c in ipairs(FindAllOf("PXCityComponent") or {}) do
        if reflect.isValid(c) and not (reflect.path(c) or ""):find("Default__", 1, true) then list[#list + 1] = c end
    end
    return list
end

-- args.city: index (1-based) or cityType substring; default = first city.
function A.city(args)
    local list = A.cities()
    local sel = args and args.city
    if sel == nil then
        if not list[1] then error("no city", 0) end
        return list[1]
    end
    if tonumber(sel) then return list[tonumber(sel)] or error("no city #" .. sel, 0) end
    for _, c in ipairs(list) do
        if (assetId(c.CityType) or ""):lower():find(tostring(sel):lower(), 1, true) then return c end
    end
    error("no city matching " .. tostring(sel), 0)
end

local function cityId(city) return city.CityOfTypeId end

-- invoke that reports guard/runtime errors as data instead of failing the whole action.
local function try(obj, fn, params)
    local ok, v = pcall(reflect.invoke, obj, fn, params)
    if ok then return v end
    return { error = tostring(v) }
end


-- Pause reasons currently active (e.g. "UserPaused", "WBP_Modal_C", "Cutscene active - ...").
function A.pauseReasons()
    local out = {}
    pcall(function()
        local t = FindFirstOf("PXTimeSubsystem")
        t.PauseState.PauseReasons:ForEach(function(_, r) out[#out + 1] = r:get():ToString() end)
    end)
    return out
end

-- Measured: Council/decision input issued while a cutscene (e.g. the chamber intro) is still
-- playing left the UI unresponsive. Block choice-type actions until the cutscene is skipped.
function A.assertNoCutscene(what)
    for _, r in ipairs(A.pauseReasons()) do
        if r:find("Cutscene", 1, true) then
            error(what .. " blocked: cutscene still active (" .. r .. "). Skip it first (fp2 keys e@3000 or fp2 council-open).", 0)
        end
    end
end

---------------------------------------------------------------------------
-- Time

function A.setPaused(paused)
    cdo("PXTimeUtils"):SetPausedByPlayer(ctx(), paused and true or false)
    return { pausedByPlayer = cdo("PXTimeUtils"):IsPausedByPlayer(ctx()) }
end

-- level: 0 = normal, 1 = fast, 2 = fastest (EPXGameSpeedLevel)
function A.setSpeed(level)
    cdo("PXTimeUtils"):SetGameSpeedLevel(ctx(), tonumber(level) or 0, true)
    return { speedLevel = cdo("PXTimeUtils"):GetGameSpeedLevel(ctx()) }
end

function A.date()
    local u = cdo("PXTimeUtils")
    local now = u:GetCurrentGameTime(ctx())
    local out = { ticks = now.ScaledTicks }
    pcall(function()
        local d = u:ConvertGameTimeToDate(ctx(), now)
        out.dateDays = d.Days
        out.date = u:DateTimeToString(ctx(), d, "%d %B %Y"):ToString()
    end)
    out.week = math.floor(now.ScaledTicks / 1680) -- matches HUD "WEEK" (game starts at tick 1680 = week 1)
    out.hours = now.ScaledTicks / 10
    return out
end

---------------------------------------------------------------------------
-- Cells

local function cellInfo(c, center, withNeighbors, withRef)
    local e = { i = c.Index }
    if withRef then e.ref = reflect.path(c) end
    pcall(function()
        local p = c.CenterPosition
        e.x, e.y = math.floor(p.X), math.floor(p.Y)
        if center then e.d = math.floor(math.sqrt((p.X - center.X) ^ 2 + (p.Y - center.Y) ^ 2)) end
    end)
    pcall(function() e.frozen = c.OutOfBuildArea and true or false end)
    pcall(function() e.outside = c.Outside and true or false end)
    pcall(function()
        local d = c.DistrictOwner
        if reflect.isValid(d) then
            e.district = reflect.shortName(d)
            pcall(function() e.district = assetId(d.DistrictType) or e.district end)
        end
    end)
    pcall(function()
        local n = 0
        c.Blockages:ForEach(function() n = n + 1 end)
        if n > 0 then e.blocked = n end
    end)
    pcall(function() e.preview = reflect.get(c, "PreviewMode").name:gsub("^.*::", "") end)
    pcall(function() if reflect.isValid(c.Construction) then e.construction = true end end)
    pcall(function()
        if cdo("PXAreaExpanderUtils"):IsCellUnderExpansion(c) then e.expanding = true end
    end)
    pcall(function()
        local deps = {}
        c.Deposits:ForEach(function(_, d)
            local dep = d:get()
            deps[#deps + 1] = assetId(dep.depositType)
        end)
        if #deps > 0 then e.deposits = deps end
    end)
    if withNeighbors then
        pcall(function()
            local nb = {}
            c.Neighbors:ForEach(function(_, n) nb[#nb + 1] = n:get().Index end)
            e.nb = nb
        end)
    end
    return e
end

function A.cellMap(city)
    local map = {}
    for _, cell in ipairs(city:GetCityCells()) do  -- TArray returns arrive as Lua tables
        if type(cell) == "userdata" and not reflect.isValid(cell) then pcall(function() cell = cell:get() end) end
        local idx = cell.Index or cell.VoronoiCellIndex
        if idx ~= nil then map[idx] = cell end
    end
    return map
end

-- Filters: free (in build area, no district/construction), frozen, deposit (type substring),
-- maxDistance (from city center), near=x,y (sort by distance to that world point), limit.
function A.cells(args)
    local city = A.city(args)
    local center = geo.location(city)
    local sortFrom = center
    if args.nearX and args.nearY then sortFrom = { X = tonumber(args.nearX), Y = tonumber(args.nearY) } end
    local depFilter = args.deposit and tostring(args.deposit):lower() or nil
    local list = {}
    for _, c in pairs(A.cellMap(city)) do
        local e = cellInfo(c, center, args.neighbors ~= false, args.refs)
        local keep = true
        if args.free and (e.frozen or e.outside or e.district or e.construction or e.blocked) then keep = false end
        if args.frozen ~= nil and (e.frozen or false) ~= (args.frozen and true or false) then keep = false end
        if depFilter then
            keep = false
            for _, d in ipairs(e.deposits or {}) do if d:lower():find(depFilter, 1, true) then keep = true end end
        end
        if args.maxDistance and e.d and e.d > tonumber(args.maxDistance) then keep = false end
        if keep then
            e.sd = math.sqrt(((e.x or 0) - sortFrom.X) ^ 2 + ((e.y or 0) - sortFrom.Y) ^ 2)
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b) return a.sd < b.sd end)
    local out = json.array()
    local limit = tonumber(args.limit) or 60
    for i = 1, math.min(limit, #list) do
        local e = list[i]
        e.sd = nil
        if args.screen then
            local s = geo.project({ X = e.x, Y = e.y, Z = center and center.Z or 0 })
            if s then e.sx, e.sy = s.x, s.y end
        end
        out[#out + 1] = e
    end
    return { city = assetId(city.CityType), total = #list, cells = out }
end

local function resolveCells(city, indices)
    local map = A.cellMap(city)
    local objs = {}
    for _, i in ipairs(indices or {}) do
        local c = map[tonumber(i)]
        if not c then error("no cell index " .. tostring(i) .. " in this city", 0) end
        objs[#objs + 1] = c
    end
    if #objs == 0 then error("cells=[...] required", 0) end
    return objs
end

---------------------------------------------------------------------------
-- Area expansion (frostbreaking)

function A.expanders(args)
    local city = A.city(args)
    local u = cdo("PXAreaExpanderUtils")
    local out = json.array()
    local list = reflect.invoke(u, "GetSupportedAreaExpanders", { city })
    for _, t in ipairs(list or {}) do
        local obj = reflect.find(t.ref)
        local e = { id = assetId(obj), ref = t.ref }
        pcall(function() e.requiredCells = u:GetAreaExpanderRequiredCellCount(obj) end)
        out[#out + 1] = e
    end
    return out
end

local function findTyped(list, want, what)
    for _, t in ipairs(list or {}) do
        local id = (t.ref or ""):match("%.([^%.]+)$") or ""
        if not want or id:lower():find(tostring(want):lower(), 1, true) then return reflect.find(t.ref) end
    end
    error("no " .. what .. " matching " .. tostring(want), 0)
end

-- args: cells=[indices], type (expander id substring, default first), dryRun
function A.expand(args)
    local city = A.city(args)
    local u = cdo("PXAreaExpanderUtils")
    local typ = findTyped(reflect.invoke(u, "GetSupportedAreaExpanders", { city }), args.type, "area expander")
    local cells = resolveCells(city, args.cells)
    local out = { type = assetId(typ), cells = args.cells }
    out.check = try(u, "CanConstructAreaExpander", { city, typ, cells })
    out.cost = try(u, "GetAreaExpanderConstructionCost", { city, typ, cells })
    out.duration = try(u, "GetAreaExpanderConstructionDuration", { city, typ, cells })
    if args.dryRun then return out end
    local ints = {}
    for i, c in ipairs(cells) do ints[i] = c.Index end
    out.ok = cdo("PXInstructionUtils"):ExpandArea(cityId(city), typ, ints, A.leaderOrigin())
    return out
end

---------------------------------------------------------------------------
-- Districts

function A.districtTypes(args)
    local city = A.city(args)
    local u = cdo("PXDistrictUtils")
    local out = json.array()
    local nation = city.Nation
    for _, t in ipairs(reflect.invoke(u, "GetSupportedDistricts", { city }) or {}) do
        local obj = reflect.find(t.ref)
        local e = { id = assetId(obj), ref = t.ref }
        pcall(function() e.canConstruct = u:CanConstructDistrict(city, obj) end)
        pcall(function() e.needsDeposit = u:IsDistrictRequiringDeposits(obj) end)
        e.cost = try(u, "GetDistrictConstructionCost", { nation, obj, true })
        out[#out + 1] = e
    end
    return out
end

-- args: type (district id substring), cells=[6 indices], dryRun
function A.placeDistrict(args)
    local city = A.city(args)
    local u = cdo("PXDistrictUtils")
    local typ = findTyped(reflect.invoke(u, "GetSupportedDistricts", { city }), args.type, "district type")
    local cells = resolveCells(city, args.cells)
    local out = { type = assetId(typ), cells = args.cells }
    out.canConstruct = u:CanConstructDistrict(city, typ)
    out.cost = try(u, "GetDistrictConstructionCost", { city.Nation, typ, true })
    local problems = {}
    for _, c in ipairs(cells) do
        local e = cellInfo(c, nil, false)
        if e.frozen or e.outside then problems[#problems + 1] = "cell " .. e.i .. " is frozen/outside" end
        if e.district or e.construction then problems[#problems + 1] = "cell " .. e.i .. " is occupied" end
    end
    out.problems = problems
    if args.dryRun then return out end
    if #problems > 0 and not args.force then error("cell problems: " .. table.concat(problems, "; ") .. " (dryRun to inspect)", 0) end
    local ints = {}
    for i, c in ipairs(cells) do ints[i] = c.Index end
    local res = cdo("PXInstructionUtils"):PlaceDistrict(world(), cityId(city), typ, ints, {}, A.leaderOrigin())
    out.result = reflect.ref(res)
    return out
end

-- Pick a connected cluster of `count` cells by growing from a seed.
-- args: count=6, deposit (seed must hold this deposit type), frozen=true (pick frozen cells
-- adjacent to the build area, for frostbreaking), nearX/nearY (prefer seeds near a point).
function A.pickCells(args)
    local city = A.city(args)
    local center = geo.location(city)
    local count = tonumber(args.count) or 6
    local map = A.cellMap(city)
    local info = {}
    for idx, c in pairs(map) do info[idx] = cellInfo(c, center, true) end
    local wantFrozen = args.frozen and true or false
    local function usable(e)
        if not e or e.district or e.construction or e.blocked or e.expanding then return false end
        if wantFrozen then return e.frozen and true or false end
        return not e.frozen and not e.outside
    end
    local function touchesCity(e)
        for _, n in ipairs(e.nb or {}) do
            local ne = info[n]
            if ne and (ne.district or (wantFrozen and not ne.frozen)) then return true end
        end
        return false
    end
    local depFilter = args.deposit and tostring(args.deposit):lower() or nil
    local function hasDeposit(e)
        for _, d in ipairs(e.deposits or {}) do if d:lower():find(depFilter, 1, true) then return true end end
        return false
    end
    local ref = center
    if args.nearX and args.nearY then ref = { X = tonumber(args.nearX), Y = tonumber(args.nearY) } end
    local function dist(e) return ((e.x or 0) - ref.X) ^ 2 + ((e.y or 0) - ref.Y) ^ 2 end
    local seeds = {}
    for _, e in pairs(info) do
        if usable(e) and (not depFilter or hasDeposit(e)) and (depFilter or touchesCity(e)) then seeds[#seeds + 1] = e end
    end
    table.sort(seeds, function(a, b) return dist(a) < dist(b) end)
    for si = 1, math.min(#seeds, 40) do
        local seed = seeds[si]
        local chosen, inSet = { seed.i }, { [seed.i] = true }
        local frontier = {}
        local function addFrontier(e)
            for _, n in ipairs(e.nb or {}) do
                if not inSet[n] and usable(info[n]) then frontier[n] = true end
            end
        end
        addFrontier(seed)
        while #chosen < count do
            local best, bestD
            for n in pairs(frontier) do
                local d = ((info[n].x - seed.x) ^ 2 + (info[n].y - seed.y) ^ 2)
                if not best or d < bestD then best, bestD = n, d end
            end
            if not best then break end
            frontier[best] = nil
            inSet[best] = true
            chosen[#chosen + 1] = best
            addFrontier(info[best])
        end
        if #chosen >= count then
            local cells = json.array()
            for _, i in ipairs(chosen) do cells[#cells + 1] = i end
            return { cells = cells, seed = seed.i, seedDeposits = seed.deposits, distanceFromCity = seed.d }
        end
    end
    error("no connected cluster of " .. count .. " usable cells found (" .. #seeds .. " seeds)", 0)
end

---------------------------------------------------------------------------
-- Modals / communication channels (event popups, decisions, tutorials)

local function textOf(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s ~= "" then return s end
    return nil
end

function A.openModals()
    local list = {}
    for _, w in ipairs(FindAllOf("PXCommunicationChannelWidget") or {}) do
        if reflect.isValid(w) and not (reflect.path(w) or ""):find("Default__", 1, true) then
            local okO, opened = pcall(function() return w:GetIsOpened() end)
            if okO and opened then list[#list + 1] = w end
        end
    end
    return list
end

function A.modals()
    local out = json.array()
    for _, w in ipairs(A.openModals()) do
        local e = { ref = reflect.path(w), class = reflect.className(w) }
        pcall(function()
            local mp = w.messageParams
            e.title = textOf(mp.TitleText)
            e.subtitle = textOf(mp.SubtitleText)
            e.description = textOf(mp.DescriptionText)
            e.info = textOf(mp.GameplayInfo)
            e.speaker = textOf(mp.Speaker)
            if reflect.isValid(mp.Decision) then e.decision = reflect.ref(mp.Decision) end
        end)
        out[#out + 1] = e
    end
    return out
end

-- args: index (choice, default 0), ref (modal; default first open), close=true
function A.choose(args)
    A.assertNoCutscene("choose")
    local w
    if args.ref then w = reflect.find(args.ref) else w = A.openModals()[1] end
    if not reflect.isValid(w) then error("no open modal", 0) end
    local decision
    pcall(function() decision = w.messageParams.Decision end)
    if not reflect.isValid(decision) then decision = nil end
    local idx = tonumber(args.index) or 0
    w:OnChoiceButtonClicked(decision, idx, args.close ~= false)
    return { chose = idx, modal = reflect.className(w), decision = decision and reflect.ref(decision) or nil }
end

---------------------------------------------------------------------------
-- Research (Idea Tree)

local function nationOf(args)
    local city = A.city(args or {})
    return city.Nation, city
end

local function objList(v)
    -- UFunction TArray<UObject*> returns arrive as Lua tables
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do
            if type(x) == "userdata" and not reflect.isValid(x) then pcall(function() x = x:get() end) end
            if reflect.isValid(x) then out[#out + 1] = x end
        end
    end
    return out
end

local function communityLabel(c)
    local id = reflect.shortName(c)
    pcall(function() id = assetId(c.Type) or id end)
    return id
end

local function costMap(v)
    local out = json.object()
    for _, e in ipairs(reflect.plain(v, 2) or {}) do
        if type(e) == "table" and e.key then
            local k = type(e.key) == "table" and e.key.ref and e.key.ref:match("%.DA_([^%.]+)$") or tostring(e.key)
            out[k] = e.value
        end
    end
    return out
end

function A.researchStatus(args)
    local u = cdo("PXResearchUtils")
    local nation = nationOf(args)
    local out = {}
    pcall(function() out.supported = u:IsResearchSupported(ctx(), nation) end)
    pcall(function() out.active = u:IsResearchActive(ctx(), nation) end)
    pcall(function() out.anyInProgress = u:IsAnyResearchTopicInProgress(nation) end)
    pcall(function()
        local t = u:GetResearchTopicInProgress(nation)
        if reflect.isValid(t) then out.topic = assetId(t) end
    end)
    pcall(function()
        local o = u:GetResearchOutcomeInProgress(nation)
        if reflect.isValid(o) then out.outcome = assetId(o) end
    end)
    pcall(function() out.speed = u:GetResearchSpeed(ctx(), nation) end)
    return out
end

-- args: all=true to include locked/unavailable topics, contains (id substring), limit
function A.researchTopics(args)
    local u = cdo("PXResearchUtils")
    local nation = nationOf(args)
    local out = json.array()
    local filter = args.contains and tostring(args.contains):lower() or nil
    for _, t in ipairs(objList(u:GetAllResearchTopics(ctx()))) do
        local id = assetId(t) or "?"
        local e = { id = id }
        pcall(function() e.available = u:IsResearchTopicAvailable(ctx(), nation, t) end)
        pcall(function() e.unlocked = u:IsResearchTopicUnlocked(ctx(), nation, t) end)
        pcall(function() e.researched = u:GetResearchedOutcomesCount(nation, t) end)
        local keep = (args.all or (e.available and e.unlocked)) and (not filter or id:lower():find(filter, 1, true))
        if keep then
            pcall(function() e.radical = u:IsResearchTopicRadical(ctx(), t) end)
            pcall(function() e.cost = costMap(u:GetResearchTopicStockpileCost(ctx(), t)) end)
            pcall(function()
                local comms = json.array()
                for _, c in ipairs(objList(u:GetCommunitiesAvailableForResearchTopic(ctx(), nation, t))) do
                    local ce = { community = communityLabel(c) }
                    pcall(function() ce.outcome = assetId(u:GetMatchingOutcome(ctx(), nation, t, c)) end)
                    comms[#comms + 1] = ce
                end
                e.communities = comms
            end)
            out[#out + 1] = e
            if args.limit and #out >= tonumber(args.limit) then break end
        end
    end
    return out
end

-- args: topic (exact id or substring), community (type id substring; default first available)
function A.researchStart(args)
    local u = cdo("PXResearchUtils")
    local nation = nationOf(args)
    local want = tostring(args.topic or ""):lower()
    if want == "" then error("topic required", 0) end
    local topic
    for _, t in ipairs(objList(u:GetAllResearchTopics(ctx()))) do
        local id = (assetId(t) or ""):lower()
        if id == want then topic = t; break end
        if not topic and id:find(want, 1, true) then topic = t end
    end
    if not topic then error("no research topic matching " .. want, 0) end
    if not u:IsResearchTopicAvailable(ctx(), nation, topic) then error(assetId(topic) .. " is not available", 0) end
    local comms = objList(u:GetCommunitiesAvailableForResearchTopic(ctx(), nation, topic))
    local community
    for _, c in ipairs(comms) do
        if not args.community or communityLabel(c):lower():find(tostring(args.community):lower(), 1, true) then community = c; break end
    end
    if not community then error("no community available for " .. assetId(topic), 0) end
    local outcome = u:GetMatchingOutcome(ctx(), nation, topic, community)
    local out = { topic = assetId(topic), community = communityLabel(community), outcome = assetId(outcome) }
    if args.dryRun then return out end
    cdo("PXInstructionUtils"):InstructStartResearch(ctx(), nation, community, topic, outcome)
    out.status = A.researchStatus(args)
    return out
end

---------------------------------------------------------------------------
-- Buildings

local function compactCost(c)
    if type(c) ~= "table" then return c end
    local out = { weeks = c.Duration and c.Duration.ScaledTicks and c.Duration.ScaledTicks / 1680 or nil, workforce = c.Workforce }
    out.stockpile = costMap(c.StockpileCost or {})
    out.upkeep = costMap(c.Resources or {})
    return out
end
A.compactCost = compactCost

function A.districts(args)
    local city = A.city(args)
    local out = json.array()
    for _, d in ipairs(objList(city:GetDistricts())) do
        local e = { ref = reflect.path(d), type = assetId(d.DistrictType), id = d.DistrictId }
        pcall(function()
            local b = json.array()
            for _, bld in ipairs(objList(cdo("PXBuildingUtils"):GetBuildingsFromCity(city))) do
                local okD, dist = pcall(function() return bld.OwningDistrict end)
                if okD and reflect.isValid(dist) and reflect.path(dist) == e.ref then b[#b + 1] = assetId(bld.Type) end
            end
            e.buildings = b
        end)
        pcall(function() e.underConstruction = cdo("PXConstructionUtils"):IsUnderConstruction(d) end)
        out[#out + 1] = e
    end
    return out
end

-- args: district (type id substring to show only buildings it supports), contains
function A.buildingTypes(args)
    local city = A.city(args)
    local nation = city.Nation
    local bu, du = cdo("PXBuildingUtils"), cdo("PXDistrictUtils")
    local dtypes = objList(du:GetSupportedDistricts(city))
    local out = json.array()
    for _, bt in ipairs(objList(bu:GetUnlockedBuildings(ctx()))) do
        local id = assetId(bt) or "?"
        if not args.contains or id:lower():find(tostring(args.contains):lower(), 1, true) then
            local e = { id = id, districts = json.array() }
            for _, dt in ipairs(dtypes) do
                local ok, sup = pcall(function() return du:IsDistrictSupportingBuilding(nation, dt, bt) end)
                if ok and sup then e.districts[#e.districts + 1] = assetId(dt) end
            end
            local keep = not args.district
            for _, d in ipairs(e.districts) do
                if args.district and d:lower():find(tostring(args.district):lower(), 1, true) then keep = true end
            end
            if keep and #e.districts > 0 then
                local okC, c = pcall(reflect.invoke, bu, "GetBuildingTypeConstructionCost", { nation, bt, true })
                e.cost = okC and compactCost(c) or { error = tostring(c) }
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- args: type (building id substring), district (district ref, or district type id substring), dryRun
function A.placeBuilding(args)
    local city = A.city(args)
    local bu = cdo("PXBuildingUtils")
    local want = tostring(args.type or ""):lower()
    local btype
    for _, bt in ipairs(objList(bu:GetUnlockedBuildings(ctx()))) do
        local id = (assetId(bt) or ""):lower()
        if id == want then btype = bt; break end
        if not btype and want ~= "" and id:find(want, 1, true) then btype = bt end
    end
    if not btype then error("no unlocked building matching " .. want, 0) end
    local district
    if args.district and tostring(args.district):sub(1, 1) == "/" then
        district = reflect.find(args.district)
    else
        local du = cdo("PXDistrictUtils")
        for _, d in ipairs(objList(city:GetDistricts())) do
            local okS, sup = pcall(function() return du:IsDistrictSupportingBuilding(city.Nation, d.DistrictType, btype) end)
            local typeOk = not args.district or (assetId(d.DistrictType) or ""):lower():find(tostring(args.district):lower(), 1, true)
            if okS and sup and typeOk then district = d; break end
        end
    end
    if not reflect.isValid(district) then error("no district supports " .. assetId(btype), 0) end
    local out = { type = assetId(btype), district = assetId(district.DistrictType), districtRef = reflect.path(district) }
    local okC, c = pcall(reflect.invoke, bu, "GetBuildingTypeConstructionCost", { city.Nation, btype, true })
    out.cost = okC and compactCost(c) or nil
    if args.dryRun then return out end
    local res = bu:CreateBuilding(ctx(), district, btype, A.leaderOrigin())
    out.result = reflect.ref(res)
    return out
end

---------------------------------------------------------------------------
-- Council (parliament, laws/policies)

local function enumName(v)
    -- UFunction enum returns are plain numbers in UE4SS; keep the number.
    return v
end

local function playerPolicyComponent()
    local pc = cdo("PXPolicyUtils"):GetPlayerPolicy(ctx())
    if not reflect.isValid(pc) then error("no player policy component", 0) end
    return pc
end

local function parliament()
    local p = cdo("PXParliamentUtils"):GetCurrentParliament(ctx())
    if reflect.isValid(p) then return p end
    return nil
end

local function parliamentCommunityTypes(parl)
    local types = {}
    if not parl then return types end
    pcall(function()
        for _, t in ipairs(objList(cdo("PXParliamentUtils"):GetAllCommunitiesInParliment(parl))) do types[#types + 1] = t end
    end)
    return types
end

function A.council(args)
    local pu = cdo("PXParliamentUtils")
    local nation = nationOf(args)
    local out = {}
    pcall(function() out.active = pu:IsParliamentActive(nation) end)
    pcall(function() out.inParliament = pu:IsInParliament(ctx()) end)
    for _, r in ipairs(A.pauseReasons()) do
        if r:find("Cutscene", 1, true) then out.cutscene = r end
    end
    pcall(function() out.phase = pu:GetCurrentParliamentPhase(ctx()) end)
    pcall(function() out.minTicksToNextSession = pu:GetMinTimeToNextSession(ctx()).ScaledTicks end)
    pcall(function() out.ticksToForcedVote = pu:GetTimeToForcedVote(ctx()).ScaledTicks end)
    pcall(function()
        local p = pu:GetCurrentPolicyFromAgenda(ctx())
        if reflect.isValid(p) then out.agendaPolicy = assetId(p) end
    end)
    local parl = parliament()
    if parl then
        out.parliament = reflect.path(parl)
        local seats = json.object()
        for _, t in ipairs(parliamentCommunityTypes(parl)) do
            pcall(function() seats[assetId(t)] = pu:GetRepresentativesCountFromCommunityType(parl, t) end)
        end
        out.seats = seats
    end
    pcall(function()
        local active = json.array()
        for _, e in ipairs(reflect.plain(cdo("PXPolicyUtils"):GetActivePoliciesMap(playerPolicyComponent()), 1) or {}) do
            local v = e.value
            active[#active + 1] = (type(v) == "table" and v.ref and v.ref:match("%.DA_([^%.]+)$")) or v
        end
        out.activePolicies = active
    end)
    return out
end

-- Inactive unlocked policies with each council faction's support (enum value: higher = more support).
function A.laws(args)
    local pol, pu = cdo("PXPolicyUtils"), cdo("PXParliamentUtils")
    local comp = playerPolicyComponent()
    local parl = parliament()
    local types = parliamentCommunityTypes(parl)
    local filter = args.contains and tostring(args.contains):lower() or nil
    local out = json.array()
    for _, p in ipairs(objList(pol:GetAllInactivePolicies(comp, true))) do
        local id = assetId(p) or "?"
        if not filter or id:lower():find(filter, 1, true) then
            local e = { id = id }
            pcall(function() e.law = assetId(pol:GetLaw(comp, p)) end)
            if parl then
                local sup = json.object()
                for _, t in ipairs(types) do
                    pcall(function()
                        local v = pu:GetCommunitySupportToPolicy(ctx(), t, p)
                        sup[assetId(t)] = reflect.enumNames("EPXVoteAttitude")[v] or v
                    end)
                end
                e.support = sup
                local tally = { For = 0, Against = 0, Hesitant = 0 }
                for _, t in ipairs(types) do
                    local okS, n = pcall(function() return pu:GetRepresentativesCountFromCommunityType(parl, t) end)
                    local att = sup[assetId(t)]
                    if okS and tally[att] then tally[att] = tally[att] + n end
                end
                e.seats = tally
            end
            out[#out + 1] = e
            if args.limit and #out >= tonumber(args.limit) then break end
        end
    end
    return out
end

local function findPolicy(want)
    local pol = cdo("PXPolicyUtils")
    want = tostring(want or ""):lower()
    if want == "" then error("policy required", 0) end
    local found
    for _, p in ipairs(objList(pol:GetAllInactivePolicies(playerPolicyComponent(), true))) do
        local id = (assetId(p) or ""):lower()
        if id == want then return p end
        if not found and id:find(want, 1, true) then found = p end
    end
    if not found then error("no unlocked inactive policy matching " .. want, 0) end
    return found
end

-- Request a council session that votes on `policy` (the in-game "propose law" flow).
function A.propose(args)
    A.assertNoCutscene("propose")
    -- Measured: RequestSession from the bridge set the agenda but desynced the Council UI
    -- (Propose button dead, input stuck). Disabled until the UI flow is mapped.
    if not args.unsafe then
        error("propose disabled: bridge RequestSession desyncs the Council UI. Use the UI (key C -> Propose a law).", 0)
    end
    local p = findPolicy(args.policy)
    local out = { policy = assetId(p) }
    if args.dryRun then return out end
    out.requested = cdo("PXParliamentUtils"):RequestSession(ctx(), false, p, args.skipRecess and true or false, nil)
    out.council = A.council(args)
    return out
end

-- Cast the player's vote on a policy in the current session.
function A.vote(args)
    A.assertNoCutscene("vote")
    -- Measured: InstructVote outside the Council scene locked all game input (no recovery
    -- short of reloading). Only allow it while the player is in the parliament view.
    local inParl = false
    pcall(function() inParl = cdo("PXParliamentUtils"):IsInParliament(ctx()) end)
    if not inParl and not args.unsafe then
        error("vote refused: Council scene not open (InstructVote outside it locks game input). Open the Council in the UI first.", 0)
    end
    local p = findPolicy(args.policy)
    local res = cdo("PXInstructionUtils"):InstructVote(ctx(), p)
    return { policy = assetId(p), result = reflect.plain(res, 2) }
end

return A
