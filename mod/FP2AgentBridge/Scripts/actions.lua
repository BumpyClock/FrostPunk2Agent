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
        if args.free and (e.frozen or e.district or e.construction or e.blocked) then keep = false end
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
        if e.frozen then problems[#problems + 1] = "cell " .. e.i .. " is frozen" end
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
        -- Outside cells are buildable (measured: Logistics district on an Outside deposit cell).
        return not e.frozen
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

local function uarray(v)
    if type(v) == "table" then return v end
    local out = {}
    -- TArray ForEach passes (index, elem); TSet passes (elem).
    pcall(function()
        v:ForEach(function(a, b)
            local e = b ~= nil and b or a
            local ok, x = pcall(function() return e:get() end)
            out[#out + 1] = ok and x or e
        end)
    end)
    return out
end

-- Game rich text to plain text: <img id="FoodPositive"></> -> [Food+], style tags dropped.
function A.plainText(v)
    if type(v) ~= "string" then return v end
    v = v:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("\r", "")
    v = v:gsub('<img id="(%a-)Positive">', "[%1+]"):gsub('<img id="(%a-)Negative">', "[%1-]")
    v = v:gsub('<img id="(.-)">', "[%1]"):gsub("</>", ""):gsub("<%a+>", ""):gsub("  +", " ")
    return v
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
            if reflect.isValid(mp.Decision) then
                e.decision = reflect.ref(mp.Decision)
                local choices = json.array()
                pcall(function()
                    mp.Decision.Choices:ForEach(function(i, ch)
                        local c = ch:get()
                        local ce = { index = i - 1 }
                        pcall(function() ce.name = c.Name:ToString() end)
                        pcall(function() ce.description = c.Description:ToString() end)
                        pcall(function() ce.effects = A.plainText(c.GameplayInfo:ToString()) end)
                        -- Hidden consequences the UI text may not mention.
                        pcall(function()
                            local acts = json.array()
                            for _, a in ipairs(uarray(c.ImmediateActions)) do
                                if reflect.isValid(a) then acts[#acts + 1] = (reflect.className(a) or "?"):gsub("^PX", "") end
                            end
                            if #acts > 0 then ce.actions = acts end
                        end)
                        pcall(function()
                            local aff = reflect.plain(c.AffinitiesChange, 3)
                            if type(aff) == "table" and next(aff) ~= nil then ce.affinities = aff end
                        end)
                        choices[#choices + 1] = ce
                    end)
                end)
                e.choices = choices
            end
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
    -- Out-params: UE4SS fills the tables passed in their place (prog.outProgress, left.ScaledTicks; measured).
    pcall(function()
        local t = u:GetResearchTopicInProgress(nation)
        if not reflect.isValid(t) then return end
        local prog, left = {}, {}
        u:GetResearchProgress(nation, t, prog, left)
        if prog.outProgress then out.progress = math.floor(prog.outProgress * 1000 + 0.5) / 1000 end
        if left.ScaledTicks then out.weeksLeft = math.floor(left.ScaledTicks / 168 + 0.5) / 10 end
    end)
    return out
end

-- args: all=true to include locked/unavailable topics, contains (id substring), limit
local function textOf(v)
    if v == nil then return nil end
    local ok, sv = pcall(function() return v:ToString() end)
    if not ok then sv = tostring(v) end
    if sv == nil or sv == "" or sv:find("BLANK_ON_PURPOSE", 1, true) then return nil end
    return A.plainText(sv)
end

-- Outcome details: player-facing name, description, and the city problems (statistics) it solves.
local function outcomeInfo(o, ce)
    if not reflect.isValid(o) then return end
    pcall(function() ce.name = textOf(o.IngameName) or textOf(o.EditorName) end)
    pcall(function() ce.description = textOf(o.Description) or textOf(o.EditorDescription) end)
    pcall(function()
        local solves = json.array()
        for _, st in ipairs(uarray(o.StatisticProblemsSolved)) do
            if reflect.isValid(st) then solves[#solves + 1] = assetId(st) end
        end
        if #solves > 0 then ce.solves = solves end
    end)
end

-- args: contains, all, limit, solves (statistic name, e.g. Squalor: only topics with an outcome solving it)
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
            pcall(function() e.name = textOf(t.IngameName) end)
            pcall(function() e.question = textOf(t.QuestionText) end)
            local solvesAny = {}
            pcall(function()
                local comms = json.array()
                for _, c in ipairs(objList(u:GetCommunitiesAvailableForResearchTopic(ctx(), nation, t))) do
                    local ce = { community = communityLabel(c) }
                    pcall(function()
                        local o = u:GetMatchingOutcome(ctx(), nation, t, c)
                        ce.outcome = assetId(o)
                        if not args.brief then outcomeInfo(o, ce) end
                    end)
                    for _, st in ipairs(ce.solves or {}) do solvesAny[st:lower()] = true end
                    comms[#comms + 1] = ce
                end
                e.communities = comms
            end)
            if not e.communities or #e.communities == 0 then
                -- Locked topics have no available communities; list their outcomes directly for planning.
                pcall(function()
                    local outs = json.array()
                    for _, o in ipairs(uarray(t.Outcomes)) do
                        local ce = { outcome = assetId(o) }
                        if not args.brief then outcomeInfo(o, ce) end
                        for _, st in ipairs(ce.solves or {}) do solvesAny[st:lower()] = true end
                        outs[#outs + 1] = ce
                    end
                    e.outcomes = outs
                end)
            end
            if not e.unlocked or args.requires then
                pcall(function()
                    local pre, reqs = {}, json.array()
                    for _, r in ipairs(uarray(t.Requirements)) do
                        local d = A.describeRequirement(r, 6, pre)
                        if d then reqs[#reqs + 1] = d end
                    end
                    if #reqs > 0 then e.requires = reqs end
                    local list = json.array()
                    for k in pairs(pre) do list[#list + 1] = k end
                    table.sort(list)
                    if #list > 0 then e.prereqTopics = list end
                end)
            end
            pcall(function() e.weeks = math.floor(t.ResearchTime.ScaledTicks / 168 + 0.5) / 10 end)
            if not args.solves or solvesAny[tostring(args.solves):lower()] then out[#out + 1] = e end
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
        local owner = d:GetOwner()
        if reflect.isValid(owner) then
            e.label = (e.type or "?") .. "#" .. tostring(e.id)
            pcall(function() e.workforce = cdo("PXWorkforceUtils"):GetActorTotalWorkforce(owner) end)
            pcall(function()
                local reasons = json.array()
                for _, r in ipairs(objList(cdo("PXActivityUtils"):GetDeactivationReasons(owner))) do
                    if reflect.isValid(r) then reasons[#reasons + 1] = (assetId(r) or "?"):gsub("^DeactivationReason_", "") end
                end
                e.active = #reasons == 0
                if #reasons > 0 then e.inactiveReasons = reasons end
            end)
        end
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
            -- district accepts a type substring ("MainQuarter") or a label from `districts` ("MainQuarter#0").
            local wantD = args.district and tostring(args.district):lower() or nil
            local label = ((assetId(d.DistrictType) or "") .. "#" .. tostring(d.DistrictId)):lower()
            local typeOk = not wantD or label == wantD or (not wantD:find("#", 1, true) and (assetId(d.DistrictType) or ""):lower():find(wantD, 1, true))
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
-- Law effects as data: Modifiers[].Effects[] dumped and simplified (object refs -> asset names).
-- Example: Mass-Produced Goods -> { kind = "EconomyResourceRatio", Ratios = { Core_GoodsResource = 0.25 }, ... }
local EFFECT_NOISE = { VisibilityMode = true, CustomRecievingFactorNameText = true, bIsMultipliable = true }


local function simplify(v, depth)
    if type(v) ~= "table" then
        if v == "" then return nil end
        if type(v) == "string" and v:match("^/%a+/") then
            local n = (v:match("([^%.:/]+)$") or v):gsub("^DA_", ""):gsub("^AttributeType_", ""):gsub("_EffectTemplate$", "")
            return n
        end
        return v
    end
    if v.ref and v.class then return simplify(v.ref, depth) end
    if v["$null"] then return nil end
    if v.name and v.value ~= nil and next(v, nil) and v.name:find("::", 1, true) then return (v.name:gsub("^.*::", "")) end
    if depth <= 0 then return nil end
    -- {key=..., value=...} pairs (maps) -> keyed object
    if #v > 0 and type(v[1]) == "table" and v[1].key ~= nil and v[1].value ~= nil then
        local o = json.object()
        for _, kv in ipairs(v) do
            local k = simplify(kv.key, depth - 1)
            if type(k) == "string" then k = k:gsub("^Core_", ""):gsub("Resource$", "") end
            if type(k) ~= "string" then k = tostring(k) end
            o[k] = simplify(kv.value, depth - 1)
        end
        return o
    end
    if #v > 0 then
        local a = json.array()
        for _, x in ipairs(v) do local y = simplify(x, depth - 1); if y ~= nil then a[#a + 1] = y end end
        return #a > 0 and a or nil
    end
    local o, any = json.object(), false
    for k, x in pairs(v) do
        if not EFFECT_NOISE[k] and k ~= "$struct" then
            local y = simplify(x, depth - 1)
            if y ~= nil and not (type(y) == "table" and next(y) == nil) then o[k] = y; any = true end
        end
    end
    return any and o or nil
end

local function policyEffects(p)
    local out = json.array()
    for _, prop in ipairs({ "Modifiers", "ModifiersWithRequirements" }) do
        local okM, mods = pcall(function() return uarray(p[prop]) end)
        for _, m in ipairs(okM and mods or {}) do
            if reflect.isValid(m) then
                local okE, effects = pcall(function() return uarray(m.Effects) end)
                for _, ef in ipairs(okE and effects or {}) do
                    if reflect.isValid(ef) then
                        local e = simplify(reflect.dump(ef, { depth = 3, gameOnly = true }), 4) or json.object()
                        e.kind = (reflect.className(ef) or "?"):gsub("^PX", ""):gsub("ModifierEffect$", "")
                        if prop == "ModifiersWithRequirements" then e.conditional = true end
                        out[#out + 1] = e
                    end
                end
            end
        end
    end
    return out
end

-- Requirement trees (research topics, laws, buildings): composite all/any nodes and typed leaves.
-- prereqTopics collects every ResearchTopic leaf for planning.
local REQ_NOISE = { CustomRequirementNotMetText = true, MarkDeprecated = true, Requirements = true, Mode = true }
function A.describeRequirement(r, depth, prereqTopics)
    depth = depth or 6
    if not reflect.isValid(r) or depth <= 0 then return nil end
    local cls = reflect.className(r) or "?"
    local e = json.object()
    pcall(function()
        local hint = r.CustomRequirementNotMetText:ToString()
        if hint and hint ~= "" then e.hint = A.plainText(hint) end
    end)
    if cls:find("CompositeRequirement", 1, true) then
        local mode = "all"
        pcall(function() if tostring(reflect.enumNames("EPXCompositeRequirementMode")[r.Mode] or r.Mode):find("Any") then mode = "any" end end)
        local kids = json.array()
        for _, c in ipairs(uarray(r.Requirements)) do
            local d = A.describeRequirement(c, depth - 1, prereqTopics)
            if d then kids[#kids + 1] = d end
        end
        if #kids == 1 and not e.hint then return kids[1] end
        e[mode] = kids
        return e
    end
    e.kind = cls:gsub("^PX", ""):gsub("Requirement$", "")
    local fields = simplify(reflect.dump(r, { depth = 2, gameOnly = true }), 3) or {}
    for k, v in pairs(fields) do if not REQ_NOISE[k] then e[k] = v end end
    if prereqTopics and e.kind == "ResearchTopic" and type(e.ResearchTopic) == "string" then prereqTopics[e.ResearchTopic] = true end
    return e
end

function A.laws(args)
    local pol, pu = cdo("PXPolicyUtils"), cdo("PXParliamentUtils")
    local comp = playerPolicyComponent()
    local parl = parliament()
    local types = parliamentCommunityTypes(parl)
    local filter = args.contains and tostring(args.contains):lower() or nil
    local out = json.array()
    -- true = only laws proposable now (empty between sessions, measured); all=true lists every inactive law.
    for _, p in ipairs(objList(pol:GetAllInactivePolicies(comp, args.all ~= true))) do
        local id = assetId(p) or "?"
        if not filter or id:lower():find(filter, 1, true) then
            local e = { id = id }
            pcall(function() e.law = assetId(pol:GetLaw(comp, p)) end)
            -- Player-facing text so a vote is made on what the law does, not on its asset id.
            local function text(prop)
                local ok, v = pcall(function() return p[prop]:ToString() end)
                if ok and v and v ~= "" and not v:find("BLANK_ON_PURPOSE", 1, true) then
                    return A.plainText(v)
                end
            end
            e.name = text("IngameName")
            if not args.brief then
                e.description = text("Description")
                e.effect = text("CustomGameplayEffect")
                e.otherEffects = text("CustomOtherGameplayEffectsText")
                local okF, fx = pcall(policyEffects, p)
                if okF and #fx > 0 then e.effects = fx end
            end
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
    -- Measured 2026-10-11: RequestSession inside the Council (after council-open, no cutscene)
    -- followed by InstructVote passed a law with the UI following along. An earlier attempt
    -- outside those conditions left the UI unresponsive, so require them.
    local inParl = false
    pcall(function() inParl = cdo("PXParliamentUtils"):IsInParliament(ctx()) end)
    if not inParl and not args.unsafe then
        error("propose refused: Council scene not open (fp2 council-open first)", 0)
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

---------------------------------------------------------------------------
-- Abilities (district/city/generator actions such as overtime, martial law, ...)

-- Actors that can own abilities: the city actor, its generator actor, and district actors.
local function abilityActors(city)
    local out = {}
    local function add(label, actor)
        if reflect.isValid(actor) then out[#out + 1] = { label = label, actor = actor } end
    end
    pcall(function() add("City", city:GetOwner()) end)
    pcall(function() add("Generator", city.Generator:GetOwner()) end)
    for _, d in ipairs(objList(city:GetDistricts())) do
        pcall(function() add((assetId(d.DistrictType) or "District") .. "#" .. tostring(d.DistrictId), d:GetOwner()) end)
    end
    return out
end

function A.abilities(args)
    local city = A.city(args)
    local au = cdo("PXAbilityUtils")
    local out = json.array()
    for _, a in ipairs(abilityActors(city)) do
        local list = json.array()
        pcall(function()
            for _, ab in ipairs(objList(au:GetActorVisibleAbilities(ctx(), a.actor))) do
                local e = { id = assetId(ab) }
                if args.describe then
                    e.ref = reflect.path(ab)
                    for _, f in ipairs({ "IngameName", "Name", "DisplayName" }) do
                        if not e.name then pcall(function() e.name = textOf(ab[f]) end) end
                    end
                    for _, f in ipairs({ "Description", "GameplayDescription", "CustomGameplayEffect" }) do
                        if not e.description then pcall(function() e.description = textOf(ab[f]) end) end
                    end
                end
                pcall(function() e.active = au:IsActorAbilityActive(ctx(), a.actor, ab) end)
                pcall(function() e.everUsed = au:WasAbilityEverUsedInActor(a.actor, ab) end)
                list[#list + 1] = e
            end
        end)
        if #list > 0 or args.all then
            out[#out + 1] = { owner = a.label, ref = reflect.path(a.actor), abilities = list }
        end
    end
    return out
end

-- args: owner (label from `abilities`, e.g. "Generator" or "Housing#1"), id (ability id substring), active=true|false
function A.setAbility(args)
    A.assertNoCutscene("ability")
    local city = A.city(args)
    local au = cdo("PXAbilityUtils")
    local want = tostring(args.id or ""):lower()
    for _, a in ipairs(abilityActors(city)) do
        if not args.owner or a.label:lower():find(tostring(args.owner):lower(), 1, true) then
            for _, ab in ipairs(objList(au:GetActorVisibleAbilities(ctx(), a.actor))) do
                if (assetId(ab) or ""):lower():find(want, 1, true) then
                    local active = args.active ~= false
                    cdo("PXInstructionUtils"):InstructSetActorAbilityActive(ctx(), a.actor, ab, active, A.leaderOrigin())
                    local now
                    pcall(function() now = au:IsActorAbilityActive(ctx(), a.actor, ab) end)
                    return { owner = a.label, ability = assetId(ab), requested = active, activeNow = now }
                end
            end
        end
    end
    error("no visible ability matching " .. want, 0)
end

---------------------------------------------------------------------------
-- Generator

function A.generator(args)
    local city = A.city(args)
    local gu = cdo("PXGeneratorUtils")
    local g = city.Generator
    if not reflect.isValid(g) then error("city has no generator", 0) end
    local out = {}
    pcall(function() out.power = g:GetPowerProduction() end)
    pcall(function() out.potentialPower = g:GetPotentialPowerProduction() end)
    pcall(function() out.fuel = g:GetFuelProduction() end)
    pcall(function() out.mode = assetId(g:GetCurrentMode()) end)
    pcall(function() out.capacity = gu:GetGeneratorCapacity(g) end)
    pcall(function() out.capacityPct = gu:GetGeneratorCapacityPercentage(g) end)
    pcall(function() out.powerLimit = gu:GetGeneratorPowerLimit(g) end)
    pcall(function() out.overdriveSupported = gu:IsGeneratorOverdriveSupported(g) end)
    pcall(function() out.overdriveActive = gu:IsGeneratorOverdriveActive(g) end)
    pcall(function() out.canOverdrive = gu:CanActivateOverdrive(g) end)
    pcall(function() out.changingMode = gu:IsGeneratorChangingMode(g) end)
    pcall(function()
        local modes = json.array()
        for _, m in ipairs(objList(gu:GetVisibleGeneratorModes(ctx(), g))) do modes[#modes + 1] = assetId(m) end
        out.visibleModes = modes
    end)
    pcall(function() out.fuelPerResource = costMap(gu:GetGeneratorCurrentPowerPerResources(g)) end)
    return out
end

-- args: active=true|false
function A.overdrive(args)
    A.assertNoCutscene("overdrive")
    local city = A.city(args)
    local gu = cdo("PXGeneratorUtils")
    local g = city.Generator
    local active = args.active ~= false
    if active and not gu:CanActivateOverdrive(g) then error("overdrive not available now", 0) end
    gu:SetGeneratorOverdriveActive(ctx(), g, active, A.leaderOrigin())
    return { overdriveActive = gu:IsGeneratorOverdriveActive(g) }
end

---------------------------------------------------------------------------
-- Heat allocation (generator heat is allocated per district; unallocated heat is wasted)

local function heatHolder(city)
    local h
    pcall(function() h = city.Generator:GetOwner().PXHeatAllocationHolderComponent end)
    if not reflect.isValid(h) then h = FindFirstOf("PXHeatAllocationHolderComponent") end
    if not reflect.isValid(h) then error("no heat allocation holder", 0) end
    return h
end

function A.heat(args)
    local city = A.city(args)
    local h = heatHolder(city)
    local hu = cdo("PXHeatManagementUtils")
    local out = {}
    pcall(function() out.autoAllocate = h.AutoAllocate end)
    pcall(function() out.heatAllocated = h.HeatAllocated end)
    pcall(function() out.powerAllocated = h.PowerAllocated end)
    pcall(function() out.unallocatedHeatBatches = h.HeatBatchesLeftover end)
    pcall(function() out.totalPowerNeeded = hu:GetTotalPowerNeeded(h, true) end)
    pcall(function() out.totalPowerAllocated = hu:GetTotalPowerAllocated(h, true) end)
    -- Label allocations by their district (same owning actor).
    local labels = {}
    for _, d in ipairs(objList(city:GetDistricts())) do
        pcall(function() labels[reflect.path(d:GetOwner())] = assetId(d.DistrictType) .. "#" .. tostring(d.DistrictId) end)
    end
    local list = json.array()
    pcall(function()
        h.AllocationComponents:ForEach(function(_, a)
            local comp = a:get()
            local e = {}
            pcall(function() e.district = labels[reflect.path(comp:GetOwner())] or reflect.className(comp:GetOwner()) end)
            pcall(function() e.allocation = comp.Allocation end)
            pcall(function() e.needed = comp.AllocationsNeeded end)
            pcall(function() e.heat = comp.HeatAllocated end)
            pcall(function() e.maxLevel = hu:GetMaxPossibleAllocationLevel(ctx(), comp) end)
            pcall(function() e.adjustment = comp.setup.Adjustment end)
            e.ref = reflect.path(comp)
            list[#list + 1] = e
        end)
    end)
    out.allocations = list
    return out
end

-- Raise/lower one district's heat level relative to what it needs (game's adjustment setting).
-- args: district (label like Housing#1), adjustment (int, e.g. 1)
function A.heatAdjust(args)
    local city = A.city(args)
    local h = heatHolder(city)
    local want = tostring(args.district or ""):lower()
    local labels = {}
    for _, d in ipairs(objList(city:GetDistricts())) do
        pcall(function() labels[reflect.path(d:GetOwner())] = assetId(d.DistrictType) .. "#" .. tostring(d.DistrictId) end)
    end
    local target, label
    h.AllocationComponents:ForEach(function(_, a)
        local comp = a:get()
        local l = labels[reflect.path(comp:GetOwner())] or ""
        if l:lower() == want then target, label = comp, l; return true end
    end)
    if not target then error("no heat allocation for district " .. tostring(args.district), 0) end
    cdo("PXHeatManagementUtils"):SetHeatAllocationAdjustmentLevel(ctx(), target, tonumber(args.adjustment) or 1)
    return { district = label, allocation = target.Allocation, needed = target.AllocationsNeeded, heat = target.HeatAllocated }
end

function A.heatDistribute(args)
    local city = A.city(args)
    local h = heatHolder(city)
    cdo("PXHeatManagementUtils"):DistributeAvailableHeat(ctx(), h)
    return A.heat(args)
end

function A.heatAuto(args)
    local city = A.city(args)
    local h = heatHolder(city)
    cdo("PXHeatManagementUtils"):SetHeatAutoAllocation(ctx(), h, args.active ~= false)
    return A.heat(args)
end

---------------------------------------------------------------------------
-- District on/off (frees or reclaims workforce). Uses the player's own deactivation reason.

local function findDistrict(city, label)
    local want = tostring(label or ""):lower()
    for _, d in ipairs(objList(city:GetDistricts())) do
        local l = (assetId(d.DistrictType) or "District") .. "#" .. tostring(d.DistrictId)
        if l:lower() == want or (want ~= "" and l:lower():find(want, 1, true)) then return d, l end
    end
    error("no district matching " .. tostring(label) .. " (labels look like Production#2; see fp2 heat or abilities)", 0)
end

-- args: district (label, e.g. Production#2), active=true|false
function A.setDistrictActive(args)
    A.assertNoCutscene("district_active")
    local city = A.city(args)
    local d, label = findDistrict(city, args.district)
    local owner = d:GetOwner()
    local au = cdo("PXActivityUtils")
    local reason = StaticFindObject("/Game/Scenarios/Shared/Configs/Activity/DeactivationReasons/DA_DeactivationReason_PlayerChoice.DA_DeactivationReason_PlayerChoice")
    if not reflect.isValid(reason) then
        for _, r in ipairs(FindAllOf("PXDeactivationReasonType") or {}) do
            if (reflect.shortName(r) or "") == "DA_DeactivationReason_PlayerChoice" then reason = r end
        end
    end
    if not reflect.isValid(reason) then error("PlayerChoice deactivation reason not found", 0) end
    local active = args.active ~= false
    if active then
        cdo("PXInstructionUtils"):InstructActivateLogic(ctx(), owner)
    else
        cdo("PXInstructionUtils"):InstructDeactivateLogic(ctx(), owner, reason)
    end
    local reasons = json.array()
    pcall(function()
        for _, r in ipairs(objList(au:GetDeactivationReasons(owner))) do reasons[#reasons + 1] = assetId(r) end
    end)
    return { district = label, requested = active, deactivationReasons = reasons }
end

---------------------------------------------------------------------------
-- Frostland territories and exploration

local TERRITORY_STATE = { hidden = 1, revealed = 2, explored = 4, charted = 8 }

local function territoryInfo(t, nation, center)
    if not reflect.isValid(t) then return { invalid = true } end
    local e = { ref = reflect.path(t) }
    pcall(function() e.name = t.ExploredName:ToString() end)
    pcall(function() if not e.name or e.name == "" then e.name = t.UnexploredName:ToString() end end)
    pcall(function() e.type = assetId(t.TerritoryType) end)
    pcall(function()
        local p = t:GetMiddlePosition()
        e.x, e.y = math.floor(p.X), math.floor(p.Y)
        if center then e.d = math.floor(math.sqrt((p.X - center.X) ^ 2 + (p.Y - center.Y) ^ 2)) end
    end)
    pcall(function()
        local ex = t:GetExplorationComponent(nation)
        if reflect.isValid(ex) then
            pcall(function() e.explored = ex:IsExplored() end)
            pcall(function() e.charted = ex:IsCharted() end)
            pcall(function() e.inProgress = ex:IsExplorationInProgress() end)
            pcall(function() e.progress = math.floor(ex:GetExplorationPercentage() * 10 + 0.5) / 1000 end) -- game returns percent; report 0..1
            pcall(function() e.objective = ex:IsMarkedAsObjective() end)
        end
    end)
    pcall(function() e.difficulty = assetId(cdo("PXTerritoryUtils"):GetTerritoryDifficulty(ctx(), t)) end)
    pcall(function() e.sites = #objList(t:GetSites()) end)
    return e
end

-- args: state=revealed|explored|charted|hidden (default revealed = explorable frontier), limit=30
function A.territories(args)
    local city = A.city(args)
    local nation = city.Nation
    local center = geo.location(city)
    local tu = cdo("PXTerritoryUtils")
    local stateName = tostring(args.state or "revealed"):lower()
    local state = TERRITORY_STATE[stateName]
    if not state then error("state must be hidden|revealed|explored|charted", 0) end
    local list = {}
    for _, t in ipairs(objList(tu:GetTerritoriesByState(ctx(), state))) do list[#list + 1] = territoryInfo(t, nation, center) end
    table.sort(list, function(a, b) return (a.d or 1e18) < (b.d or 1e18) end)
    local out = json.array()
    for i = 1, math.min(tonumber(args.limit) or 30, #list) do out[#out + 1] = list[i] end
    -- Derived from the revealed list. GetAllCurrentlyExploringTerritories plus a
    -- GetComponentByClass resolve crashed the game (access violation in HasAnyInternalFlags).
    local exploring = json.array()
    for _, e in ipairs(list) do
        if e.inProgress then exploring[#exploring + 1] = e end
    end
    return { state = stateName, total = #list, territories = out, exploring = exploring }
end

-- args: territory (ref, or name substring), dryRun
function A.explore(args)
    A.assertNoCutscene("explore")
    local city = A.city(args)
    local nation = city.Nation
    local tu = cdo("PXTerritoryUtils")
    local target
    if args.territory and tostring(args.territory):sub(1, 1) == "/" then
        target = reflect.find(args.territory)
    else
        local want = tostring(args.territory or ""):lower()
        for _, t in ipairs(objList(tu:GetTerritoriesByState(ctx(), TERRITORY_STATE.revealed))) do
            local info = territoryInfo(t, nation, nil)
            if want ~= "" and (info.name or ""):lower():find(want, 1, true) then target = t; break end
        end
    end
    if not reflect.isValid(target) then error("territory not found: " .. tostring(args.territory), 0) end
    local ex = target:GetExplorationComponent(nation)
    if not reflect.isValid(ex) then error("territory has no exploration component for this nation", 0) end
    local out = territoryInfo(target, nation, geo.location(city))
    pcall(function() out.preparationWeeks = tu:GetExplorationPreparationTime(ctx(), target, city).ScaledTicks / 1680 end)
    if args.dryRun then return out end
    cdo("PXInstructionUtils"):InstructStartTerritoryExploration(ctx(), ex, city, city)
    pcall(function() out.inProgressNow = ex:IsExplorationInProgress() end)
    return out
end

function A.explorationSummary(args)
    local r = A.territories({ state = "revealed", limit = 0, city = args and args.city or nil })
    local out = json.array()
    for _, t in ipairs(r.exploring or {}) do
        out[#out + 1] = { name = t.name, progress = t.progress, explored = t.explored }
    end
    return { exploring = out, revealed = r.total }
end

-- Plan frostbreaking toward a target cell: shortest route through frozen cells from thawed land
-- (or land being expanded), split into expander-sized batches in build order.
-- args: target (cell index) or deposit (type substring, nearest frozen match), batch=8,
--       go=true to start the first batch through A.expand (only if it touches thawed land now).
function A.frostbreakPath(args)
    local city = A.city(args)
    local center = geo.location(city)
    local map = A.cellMap(city)
    local info = {}
    for idx, c in pairs(map) do info[idx] = cellInfo(c, center, true) end
    local size = tonumber(args.batch) or 8
    local target = tonumber(args.target)
    if not target and args.deposit then
        local want, best = tostring(args.deposit):lower(), nil
        for i, e in pairs(info) do
            for _, d in ipairs(e.deposits or {}) do
                if d:lower():find(want, 1, true) and (not best or (e.d or 1e18) < (info[best].d or 1e18)) then best = i end
            end
        end
        target = best
    end
    if not target or not info[target] then error("target cell or deposit required (no match)", 0) end
    if not info[target].frozen then return { target = target, frozen = false, batches = json.array(), note = "target is not frozen" } end
    local function thawed(e) return e and (not e.frozen or e.expanding) end
    local function passable(e) return e and e.frozen and not e.expanding and not e.blocked end
    -- Multi-source BFS from frozen cells touching thawed land.
    local prev, queue, head, seen = {}, {}, 1, {}
    for i, e in pairs(info) do
        if passable(e) then
            for _, n in ipairs(e.nb or {}) do
                if thawed(info[n]) then queue[#queue + 1] = i; seen[i] = true; break end
            end
        end
    end
    local found = false
    while head <= #queue do
        local i = queue[head]; head = head + 1
        if i == target then found = true; break end
        for _, n in ipairs(info[i].nb or {}) do
            if not seen[n] and passable(info[n]) then seen[n] = true; prev[n] = i; queue[#queue + 1] = n end
        end
    end
    if not found then error("no frozen route to cell " .. target, 0) end
    local path = {}
    local cur = target
    while cur do table.insert(path, 1, cur); cur = prev[cur] end
    local used, batches = {}, json.array()
    for _, i in ipairs(path) do used[i] = true end
    -- Thaw room around the target too (a district needs 6 cells): default 5 extra when a deposit is the goal.
    local around = tonumber(args.around) or (args.deposit and 5 or 0)
    if around > 0 then
        local q, h, extra = { target }, 1, 0
        local vis = { [target] = true }
        while h <= #q and extra < around do
            local i = q[h]; h = h + 1
            for _, n in ipairs(info[i].nb or {}) do
                if not vis[n] then
                    vis[n] = true
                    local e = info[n]
                    if e and not e.blocked then q[#q + 1] = n end
                    if extra < around and passable(e) and not used[n] then used[n] = true; path[#path + 1] = n; extra = extra + 1 end
                end
            end
        end
    end
    -- Batches along the path; pad short batches with frozen neighbours of the batch.
    local k = 1
    while k <= #path do
        local b = json.array()
        for j = k, math.min(k + size - 1, #path) do b[#b + 1] = path[j] end
        k = k + size
        local guard = 0
        while #b < size and guard < 50 do
            guard = guard + 1
            local added = false
            for _, i in ipairs(b) do
                for _, n in ipairs(info[i].nb or {}) do
                    if #b < size and not used[n] and passable(info[n]) then used[n] = true; b[#b + 1] = n; added = true end
                end
            end
            if not added then break end
        end
        batches[#batches + 1] = b
    end
    local out = { target = target, deposits = info[target].deposits, distance = info[target].d, pathLength = #path, batches = batches, steps = #batches }
    if args.go then out.started = A.expand({ cells = batches[1], type = args.type, city = args.city }) end
    return out
end

---------------------------------------------------------------------------
-- Utopia Tree (faction trees): read-only. Assigning points has no reflected command path;
-- the game does it through UI widget handlers (PXUtopiaNodeDetailsPanel.AssignPoint).

local function tagName(t)
    local ok, v = pcall(function() return t.TagName:ToString() end)
    return ok and v or nil
end

-- args: faction (community type or utopia name substring), brief=true (no descriptions)
function A.utopia(args)
    local out = json.array()
    local want = args.faction and tostring(args.faction):lower() or nil
    for _, comp in ipairs(FindAllOf("PXUtopiaToolComponent") or {}) do
        if reflect.isValid(comp) then
            local e = {}
            pcall(function() e.utopia = comp.UtopiaName:ToString() end)
            pcall(function()
                local owner = comp:GetOwner()
                local cc = owner:GetComponentByClass(StaticFindObject("/Script/Frostpunk2.PXCommunityComponent"))
                if reflect.isValid(cc) then e.faction = assetId(cc.Type) end
            end)
            pcall(function()
                local st = comp.ScoreTracker
                e.points = st.Points
                e.pointsEarned = st.PointsEarned
                e.pointsCap = st.PointsCap
                e.assigned = st.AssignedNonBonusPoints
                e.nextThreshold = st.Threshold
            end)
            local nodes = json.array()
            for _, inst in ipairs(uarray(comp.NodeInstances)) do
                if reflect.isValid(inst) then
                    local n = {}
                    pcall(function() n.tag = tagName(inst.GameplayTag) end)
                    pcall(function() n.state = (inst.State and tostring(reflect.enumNames("EPXUtopiaToolNodeState")[inst.State] or inst.State)) end)
                    pcall(function()
                        local def = inst.Node
                        local setup = def.setup
                        n.name = textOf(setup.IngameName)
                        n.type = textOf(setup.Type) or tostring(setup.Type)
                        if not args.brief then n.description = textOf(setup.Description) end
                        local unlocks = json.array()
                        for _, b in ipairs(uarray(def.Blocking)) do
                            if reflect.isValid(b) then unlocks[#unlocks + 1] = tagName(b.GameplayTag) end
                        end
                        if #unlocks > 0 then n.unlocks = unlocks end
                        local req = json.array()
                        for _, b in ipairs(uarray(def.BlockedBy)) do
                            if reflect.isValid(b) then req[#req + 1] = tagName(b.GameplayTag) end
                        end
                        if #req > 0 then n.requires = req end
                    end)
                    nodes[#nodes + 1] = n
                end
            end
            e.nodes = nodes
            local hay = ((e.faction or "") .. " " .. (e.utopia or "")):lower()
            if not want or hay:find(want, 1, true) then out[#out + 1] = e end
        end
    end
    return out
end

local function liveWidget(className)
    for _, w in ipairs(FindAllOf(className) or {}) do
        if reflect.isValid(w) and (reflect.path(w) or ""):find("^/Engine/Transient") then
            local ok, vis = pcall(function() return w:IsVisible() end)
            if not ok or vis then return w end
        end
    end
end

-- Spend a Utopia Tree point through the panel's own handlers (needs the Utopia panel open: key U).
-- args: node (tag suffix or name substring)
function A.utopiaAssign(args)
    local want = tostring(args.node or ""):lower()
    if want == "" then error("node required (tag or name)", 0) end
    local panel = liveWidget("PXUtopiaToolNodesPanel")
    if not panel then error("Utopia panel not open (press U, or use the CLI utopia-assign)", 0) end
    local target, inst
    for _, w in ipairs(FindAllOf("PXUtopiaToolNodeWidget") or {}) do
        if reflect.isValid(w) and (reflect.path(w) or ""):find("^/Engine/Transient") then
            local okI, ni = pcall(function() return w["Node Instance"] end)
            if okI and reflect.isValid(ni) then
                local tag = (tagName(ni.GameplayTag) or ""):lower()
                local name = ""
                pcall(function() name = (textOf(ni.Node.setup.IngameName) or ""):lower() end)
                if tag == want or tag:sub(-#want) == want or name:find(want, 1, true) then target, inst = w, ni; break end
            end
        end
    end
    if not target then error("no node widget matching " .. want .. " (is the right faction's tree shown?)", 0) end
    local before = inst.State
    panel:HandleUtopiaToolNodeClicked(target)
    local details = liveWidget("PXUtopiaNodeDetailsPanel")
    if not details then error("node details panel did not open", 0) end
    details:AssignPoint()
    local names = reflect.enumNames("EPXUtopiaToolNodeState")
    return { node = tagName(inst.GameplayTag), before = names[before] or before, after = names[inst.State] or inst.State }
end

-- Long-term planning: ordered research path to a topic (prerequisites first), with the
-- non-research requirements (buildings, laws, ...) each step needs. args: topic (id substring)
function A.researchPlan(args)
    local want = tostring(args.topic or ""):lower()
    if want == "" then error("topic required", 0) end
    local all = A.researchTopics({ all = true, requires = true, brief = true, city = args.city })
    local byId, target = {}, nil
    for _, t in ipairs(all) do
        byId[t.id] = t
        if not target and (t.id:lower() == want or t.id:lower():find(want, 1, true) or (t.name or ""):lower():find(want, 1, true)) then target = t end
    end
    if not target then error("no research topic matching " .. want, 0) end
    local order, seen = json.array(), {}
    local function otherReqs(node, acc)
        if type(node) ~= "table" then return end
        if node.kind and node.kind ~= "ResearchTopic" then
            local copy = json.object()
            for k, v in pairs(node) do copy[k] = v end
            acc[#acc + 1] = copy
        end
        for _, key in ipairs({ "all", "any" }) do
            if node[key] then
                if key == "any" then
                    local alt = json.object(); alt.anyOf = json.array()
                    for _, c in ipairs(node[key]) do local sub = json.array(); otherReqs(c, sub); for _, x in ipairs(sub) do alt.anyOf[#alt.anyOf + 1] = x end end
                    if #alt.anyOf > 0 then acc[#acc + 1] = alt end
                else
                    for _, c in ipairs(node[key]) do otherReqs(c, acc) end
                end
            end
        end
    end
    local function visit(id, depth)
        if seen[id] or depth > 30 then return end
        seen[id] = true
        local t = byId[id]
        if not t then return end
        for _, pre in ipairs(t.prereqTopics or {}) do visit(pre, depth + 1) end
        local step = { id = t.id, name = t.name, researched = (t.researched or 0) > 0, unlocked = t.unlocked, cost = t.cost, weeks = t.weeks }
        local other = json.array()
        for _, r in ipairs(t.requires or {}) do otherReqs(r, other) end
        if #other > 0 then step.alsoNeeds = other end
        order[#order + 1] = step
    end
    visit(target.id, 0)
    local todo, weeks = 0, 0
    for _, st in ipairs(order) do if not st.researched then todo = todo + 1; weeks = weeks + (st.weeks or 0) end end
    return { topic = target.id, steps = order, remaining = todo, researchWeeksAtSpeed1 = weeks }
end

---------------------------------------------------------------------------
-- Frostland sites: outposts (settlement chain) and colony sites, with territory and state.

local function siteInfo(site, e)
    if not reflect.isValid(site) then return end
    pcall(function() e.site = assetId(site.SiteType) end)
    pcall(function()
        local t = site.TerritoryComponent
        if reflect.isValid(t) then
            local n = textOf(t.ExploredName)
            if not n then n = textOf(t.UnexploredName) end
            e.territory = n
        end
    end)
    pcall(function()
        local names = reflect.enumNames("EPXSiteState")
        site.States:ForEach(function(_, v)
            local st = v:get()
            if reflect.isValid(st) and not e.state then
                local raw = st.State
                e.state = tostring(names[raw] or raw):gsub("^EPXSiteState::", "")
            end
        end)
    end)
end

-- args: kind=outpost|colony, state (substring, e.g. Hidden), territory (substring), limit=60
function A.frostSites(args)
    local out, counts = json.array(), json.object()
    local wantState = args.state and tostring(args.state):lower() or nil
    local wantTerr = args.territory and tostring(args.territory):lower() or nil
    local function keep(e)
        if wantState and not (e.state or ""):lower():find(wantState, 1, true) then return false end
        if wantTerr and not (e.territory or ""):lower():find(wantTerr, 1, true) then return false end
        return true
    end
    local function add(e)
        local key = e.kind .. ":" .. (e.state or "?")
        counts[key] = (counts[key] or 0) + 1
        if keep(e) and #out < (tonumber(args.limit) or 60) then out[#out + 1] = e end
    end
    if args.kind ~= "colony" then
        for _, o in ipairs(FindAllOf("PXOutpostComponent") or {}) do
            if reflect.isValid(o) then
                local e = { kind = "outpost", ref = reflect.path(o) }
                pcall(function() e.type = assetId(o.Type) end)
                pcall(function()
                    local up = o.Type.UpgradedOutpostType
                    if reflect.isValid(up) then e.upgradesTo = assetId(up) end
                end)
                pcall(function() e.built = reflect.isValid(o.City) end)
                pcall(function() e.population = o.CommunitiesHolder:GetTotalCommunitiesSize() end)
                siteInfo(o.Site, e)
                add(e)
            end
        end
    end
    if args.kind ~= "outpost" then
        for _, sp in ipairs(FindAllOf("PXCityAreaSpawnerComponent") or {}) do
            if reflect.isValid(sp) then
                local e = { kind = "colony", ref = reflect.path(sp) }
                pcall(function() e.area = assetId(sp.CityAreaType) end)
                pcall(function() e.cityType = assetId(sp.CityType) end)
                siteInfo(sp.SiteComponent, e)
                add(e)
            end
        end
    end
    return { counts = counts, sites = out }
end

return A
