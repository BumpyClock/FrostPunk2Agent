-- Society: factions overview, Council vote prediction and negotiation, promises, community actions, sway.
--
-- Crash rules (MOD_DEVELOPMENT.md, measured): FText inside a struct or container param or return value
-- crashes the game, and pcall does not catch it. So:
--   * Functions whose research/describe dump shows `!text` are never called here (desire getters,
--     IsNegotiationAvailable, IsSwayAvailable, IsActionPossible, trust factor groups, gameplay descriptions).
--   * Functions known only from research/fp2_functions.txt (it has no !text marks) go through safeCall,
--     which runs reflect.assertSafeCall's runtime FText guard before the call.
--   * New struct-returning or container out-param reads are opt-in stages (`detail=`), so a crash on the
--     first live run can be bisected to one stage.
-- Object identity (inferred from naming in the dumps, matched by measured precedents): params named
-- `communityType` take the community type asset (c.Type); params named `Community`/`actingCommunity` take the
-- PXCommunityComponent (as PXTrustUtils.GetCommunityStanding in the society extractor).

local M = {}

function M.register(def, env)
    local A, reflect, json, h = env.actions, env.reflect, env.json, env.h
    local cdo, assetId, ctx, try, fresh = h.cdo, h.assetId, h.ctx, h.try, h.fresh
    local textOf, objList, simplify = h.textOf, h.objList, h.simplify

    ---------------------------------------------------------------------------
    -- Helpers

    -- Call a UFunction after the runtime FText guard; returns the raw result (objects stay userdata).
    local function safeCall(obj, fn, ...)
        local f = obj[fn]
        if not reflect.isValid(f) then error("function not found: " .. fn, 0) end
        reflect.assertSafeCall(f, fn, false)
        return f(obj, ...)
    end

    local function round(v, n)
        if type(v) ~= "number" then return v end
        local m = 10 ^ (n or 1)
        return math.floor(v * m + 0.5) / m
    end

    local function weeks(t)
        local ok, ticks = pcall(function() return t.ScaledTicks end)
        if ok and type(ticks) == "number" then return math.floor(ticks / 168 + 0.5) / 10 end
        return nil
    end

    -- Weeks until a cooldown ends. The game returns the end time (measured), so subtract now; an end in the past
    -- means no cooldown.
    local function cooldownWeeks(t)
        local okE, endTicks = pcall(function() return t.ScaledTicks end)
        if not okE or type(endTicks) ~= "number" then return nil end
        local okN, now = pcall(function() return cdo("PXTimeUtils"):GetCurrentGameTime(ctx()).ScaledTicks end)
        if not okN or type(now) ~= "number" then return nil end
        if endTicks <= now then return 0 end
        return math.floor((endTicks - now) / 168 + 0.5) / 10
    end

    local function lower(s) return s ~= nil and tostring(s):lower() or nil end

    -- detail=true|all -> every stage; detail="a,b" -> those stages.
    local function stages(v)
        local s = {}
        if v == true or v == "all" then
            setmetatable(s, { __index = function() return true end })
        elseif type(v) == "string" then
            for w in v:gmatch("[^,%s]+") do s[w:lower()] = true end
        end
        return s
    end

    local function enumName(enum, v)
        if v == nil then return nil end
        return reflect.enumNames(enum)[v] or v
    end

    -- Enum used by a UFunction param, resolved from the function's own property (paramTypeName shows
    -- Enum<EPXSwayMode> in the describe dumps, so GetEnum works on these params).
    local function paramEnum(obj, fnName, paramName)
        local f = obj[fnName]
        if not reflect.isValid(f) then return nil end
        local name
        pcall(function()
            f:ForEachProperty(function(p)
                if reflect.propName(p) == paramName then
                    local e = p:GetEnum()
                    if reflect.isValid(e) then name = reflect.path(e) end
                    return true
                end
            end)
        end)
        return name
    end

    local function enumValue(enumPath, want)
        want = lower(want)
        local exact, partial
        for v, n in pairs(reflect.enumNames(enumPath)) do
            local l = tostring(n):lower()
            if l == want then exact = v end
            if not partial and l:find(want, 1, true) then partial = v end
        end
        return exact or partial
    end

    local function pu() return cdo("PXParliamentUtils") end

    local function subsystem()
        for _, s in ipairs(FindAllOf("PXParliamentSubsystem") or {}) do
            if reflect.isValid(s) and not (reflect.path(s) or ""):find("Default__", 1, true) then return s end
        end
        return nil
    end

    local function inParliament()
        local v = false
        pcall(function() v = pu():IsInParliament(ctx()) end)
        return v
    end

    local function phaseName()
        local ok, v = pcall(function() return pu():GetCurrentParliamentPhase(ctx()) end)
        if not ok then return nil end
        return enumName("EPXSessionPhase", v)
    end

    local function cutscene()
        for _, r in ipairs(A.pauseReasons()) do
            if r:find("Cutscene", 1, true) then return r end
        end
        return nil
    end

    -- Council-scene discipline copied from A.propose/A.vote: InstructVote outside the scene locked all
    -- input (measured). needPhase: substring of the EPXSessionPhase name the step needs.
    local function councilGate(what, needPhase)
        A.assertNoCutscene(what)
        if not inParliament() then
            error(what .. " refused: Council scene not open (fp2 council-open first)", 0)
        end
        if needPhase then
            local ph = phaseName()
            if not (ph and tostring(ph):lower():find(needPhase:lower(), 1, true)) then
                error(what .. " refused: council phase is " .. tostring(ph) .. ", needs " .. needPhase, 0)
            end
        end
    end

    local function cityCommunities(city)
        local ok, list = pcall(function() return objList(cdo("PXCommunityUtils"):GetCommunitiesSortedBySize(city)) end)
        return ok and list or {}
    end

    local function communityId(c)
        local id
        pcall(function() id = assetId(c.Type) end)
        return id or reflect.shortName(c)
    end

    local function communityName(c)
        local ok, v = pcall(function()
            return textOf(safeCall(cdo("PXFactionUtils"), "GetFactionOrCommunityInGameNameText", c))
        end)
        return ok and v or nil
    end

    local function findCommunity(city, want, what)
        want = lower(want)
        if not want or want == "" then error((what or "community") .. " required (id substring; see fp2 factions)", 0) end
        local list, partial = cityCommunities(city), nil
        local ids = {}
        for _, c in ipairs(list) do
            local id = (communityId(c) or ""):lower()
            ids[#ids + 1] = id
            if id == want then return c end
            if not partial and (id:find(want, 1, true) or (lower(communityName(c)) or ""):find(want, 1, true)) then partial = c end
        end
        if partial then return partial end
        error("no community matching " .. want .. " (have: " .. table.concat(ids, ", ") .. ")", 0)
    end

    local function samePath(a, b)
        local pa, pb = reflect.path(a), reflect.path(b)
        return pa ~= nil and pa == pb
    end

    -- First non-empty FText property among candidate names. Each name is resolved on the class first and read
    -- only when it is a TextProperty: a guessed name that is a SoftObject property would crash on read
    -- (push_softobjectproperty, measured class; pcall does not catch it).
    local function textProp(o, names)
        if not reflect.isValid(o) then return nil end
        local okC, cls = pcall(function() return o:GetClass() end)
        if not okC then return nil end
        for _, name in ipairs(names) do
            local p = reflect.findProperty(cls, name)
            if p and reflect.propType(p) == "TextProperty" then
                local ok, v = pcall(function() return textOf(o[name]) end)
                if ok and type(v) == "string" and v ~= "" then return v end
            end
        end
        return nil
    end

    local NAME_PROPS = { "IngameName", "InGameName", "Name", "DisplayName", "Title" }
    local DESC_PROPS = { "Description", "CustomGameplayEffect", "ShortDescription" }

    -- Trait/asset display name: IngameName text when present, else the asset id.
    local function displayName(o)
        if not reflect.isValid(o) then return nil end
        return textProp(o, NAME_PROPS) or assetId(o)
    end

    local function resolvePolicy(want)
        if want == nil or want == "" then
            local p
            pcall(function() p = pu():GetCurrentPolicyFromAgenda(ctx()) end)
            if reflect.isValid(p) then return p end
            error("policy required (no policy on the agenda)", 0)
        end
        want = lower(want)
        local pol, comp = cdo("PXPolicyUtils"), h.playerPolicyComponent()
        local partial
        for _, onlyNow in ipairs({ true, false }) do
            for _, p in ipairs(objList(pol:GetAllInactivePolicies(comp, onlyNow))) do
                local id = (assetId(p) or ""):lower()
                if id == want then return p end
                if not partial and id:find(want, 1, true) then partial = p end
            end
            if partial then return partial end
        end
        error("no inactive policy matching " .. want, 0)
    end

    -- Native widgets live under /Engine/Transient (A.utopiaAssign pattern). visibleOnly=false also
    -- returns hidden instances.
    local function transientWidget(className, visibleOnly)
        for _, w in ipairs(FindAllOf(className) or {}) do
            if reflect.isValid(w) and (reflect.path(w) or ""):find("^/Engine/Transient")
                and not (reflect.className(w) or ""):find("PAD_", 1, true) then
                local ok, vis = pcall(function() return w:IsVisible() end)
                if not visibleOnly or not ok or vis then return w end
            end
        end
        return nil
    end

    local function widgetVisible(className)
        local w = transientWidget(className, false)
        if not w then return nil end
        local ok, vis = pcall(function() return w:IsVisible() end)
        return ok and vis or false
    end

    local function dumpFiltered(obj, filters, depth, limit)
        local out = json.object()
        for _, f in ipairs(filters) do
            local ok, d = pcall(reflect.dump, obj, { depth = depth or 2, gameOnly = true, filter = f, arrayLimit = limit or 8 })
            if ok and type(d) == "table" then
                for k, v in pairs(d) do
                    if out[k] == nil then out[k] = simplify(v, (depth or 2) + 1) end
                end
            end
        end
        return out
    end

    ---------------------------------------------------------------------------
    -- Promises (PXPromiseQuest objects; read like the quests extractor, measured getters)

    local function promiseInfo(q, withDesire)
        local e = { ref = reflect.path(q) }
        pcall(function() e.name = textOf(q:GetQuestName()) end)
        pcall(function() e.description = textOf(q:GetQuestDescription()) end)
        pcall(function()
            if not q:HasEndlessDuration() then e.weeksLeft = weeks(cdo("PXQuestUtils"):GetQuestTimeLeft(ctx(), q)) end
        end)
        local objs = json.array()
        pcall(function()
            for _, o in ipairs(objList(q:GetQuestObjectives())) do
                local oe = {}
                pcall(function() oe.name = textOf(o:GetObjectiveName()) end)
                pcall(function() oe.progress = o:GetObjectiveProgress() end)
                pcall(function() oe.max = o:GetObjectiveMaxProgress() end)
                objs[#objs + 1] = oe
            end
        end)
        if #objs > 0 then e.objectives = objs end
        -- Stage `desires`: the Desire struct property (contains FText) read as properties, never passed to a call.
        if withDesire then e.desire = dumpFiltered(q, { "Desire" }, 3, 6) end
        return e
    end

    local function communityPromises(c)
        local list = {}
        pcall(function() list = objList(cdo("PXDesireUtils"):GetCommunityPromises(ctx(), c.Type)) end)
        return list
    end

    ---------------------------------------------------------------------------
    -- Trust tiers (stage `tiers`). GetTraitTypeByTrustValue(Trust:PXTrustType, value) needs a trust type
    -- object; candidates come from PXGameplayUtils.GetTrustConfig() properties whose class name contains
    -- TrustType. Only objects of that class are passed (a wrong-class object could crash natively).

    local trustTypeCache
    local function trustTypes()
        if trustTypeCache then return trustTypeCache end
        local found = {}
        pcall(function()
            local cfg = safeCall(cdo("PXGameplayUtils"), "GetTrustConfig")
            if not reflect.isValid(cfg) then return end
            local d = reflect.dump(cfg, { depth = 2, gameOnly = true, arrayLimit = 10 })
            local function consider(name, v)
                if type(v) == "table" and type(v.class) == "string" and v.class:find("TrustType", 1, true) and v.ref then
                    local o = reflect.find(v.ref)
                    if reflect.isValid(o) and (reflect.className(o) or ""):find("TrustType", 1, true) then
                        found[#found + 1] = { name = name, obj = o }
                    end
                end
            end
            for k, v in pairs(d) do
                consider(k, v)
                if type(v) == "table" and #v > 0 then
                    for i, x in ipairs(v) do consider(k .. "[" .. i .. "]", x) end
                end
            end
        end)
        trustTypeCache = found
        return found
    end

    -- scope: "Overall" (city trust bar) or "Community" (relation tier). Measured 2026-10-11: the trust config
    -- has CommunityTrustType and OverallTrustType; CommunityTrustType maps a standing to the HUD relation tier.
    local function trustTier(value, scope)
        for _, tt in ipairs(trustTypes()) do
            if tt.name:find(scope, 1, true) then
                local ok, name = pcall(function()
                    if not reflect.isValid(tt.obj) then return nil end
                    local trait = cdo("PXTrustUtils"):GetTraitTypeByTrustValue(tt.obj, value)
                    if reflect.isValid(trait) then return displayName(trait) end
                end)
                if ok and name then return name end
            end
        end
        return nil
    end

    ---------------------------------------------------------------------------
    -- factions

    local function factions(args)
        local city = A.city(args)
        local nation = city.Nation
        local st = stages(args.detail)
        local tu, cu, du = cdo("PXTrustUtils"), cdo("PXCommunityUtils"), cdo("PXDesireUtils")
        local parl = h.parliament()
        local out = { city = assetId(city.CityType) }
        pcall(function() out.totalTrust = round(tu:GetTotalTrust(ctx(), nation), 1) end)
        pcall(function() out.population = cu:GetScaledCityPopulationSize(city) end)
        if st.tiers and out.totalTrust then out.trustTier = trustTier(out.totalTrust, "Overall") end
        -- Tension (PXCityUtils.GetCityTensionStatistic + PXStatisticUtils; clean in the describe dumps).
        pcall(function()
            local su = cdo("PXStatisticUtils")
            local ts = cdo("PXCityUtils"):GetCityTensionStatistic(city)
            if not reflect.isValid(ts) then return end
            local t = { id = assetId(ts) }
            pcall(function() t.value = round(su:GetCurrentStatisticValue(city, ts), 1) end)
            pcall(function() t.target = su:GetTargetStatisticValue(city, ts) end)
            pcall(function() t.progress = round(su:GetStatisticProgress(city, ts), 2) end)
            out.tension = t
        end)
        -- Tension contributors: the other city statistics (statisticHolder maps, as the statistics extractor).
        pcall(function()
            local contrib = json.object()
            city.statisticHolder.CurrentStatistics:ForEach(function(k, v)
                local key = k.get and k:get() or k
                local val = v.get and v:get() or v
                local id = assetId(key) or "?"
                if type(val) == "number" and val > 0 and not id:find("Tension", 1, true) then contrib[id] = round(val, 1) end
            end)
            out.contributors = contrib
        end)
        local want = lower(args.community)
        local list = json.array()
        local fervorTotal = 0
        for _, c in ipairs(cityCommunities(city)) do
            local e = { id = communityId(c) }
            local t
            pcall(function() t = c.Type end)
            local keep = not want or (e.id or ""):lower():find(want, 1, true)
            pcall(function() e.fervor = c.Fervor end)
            if type(e.fervor) == "number" then fervorTotal = fervorTotal + e.fervor end
            if keep and reflect.isValid(t) then
                e.name = communityName(c)
                pcall(function() e.typeClass = (reflect.className(t) or ""):gsub("^PX", "") end)
                pcall(function() e.factionMember = c:IsFactionMember() end)
                pcall(function()
                    local f = c:GetFaction()
                    if reflect.isValid(f) then
                        e.faction = assetId(f)
                        pcall(function() e.factionTrust = round(tu:GetFactionTrust(ctx(), nation, f), 1) end)
                    end
                end)
                pcall(function() e.size = c.Size end)
                pcall(function() e.percent = round(cu:GetCommunityPercentOfPopulation(nation, t), 3) end)
                if parl then pcall(function() e.seats = cdo("PXParliamentUtils"):GetRepresentativesCountFromCommunityType(parl, t) end) end
                pcall(function() e.standing = round(tu:GetCommunityStanding(ctx(), nation, c), 1) end)
                pcall(function() e.hideRelations = cu:ShouldHideCommunityRelationsWidgets(c) end)
                pcall(function() e.hasPromises = du:HasAnyMadePromises(ctx(), t) end)
                local proms = json.array()
                for _, q in ipairs(communityPromises(c)) do proms[#proms + 1] = promiseInfo(q, st.desires) end
                if #proms > 0 then e.promises = proms end
                if st.tiers then
                    if e.standing then e.standingTier = trustTier(e.standing, "Community") end
                    pcall(function()
                        local ft = safeCall(cdo("PXInfluenceUtils"), "GetFervorTraitType", ctx(), city, t)
                        if reflect.isValid(ft) then e.fervorTier = displayName(ft) end
                    end)
                end
                if st.affinities then
                    e.affinities = dumpFiltered(t, { "Affin" }, 3, 10)
                end
                if st.statuses then
                    pcall(function()
                        local act, inact = {}, {}
                        safeCall(cdo("PXCommunityStatusUtils"), "GetCommunityStatuses", ctx(), t, city, act, inact)
                        local function names(tbl, key)
                            local src = tbl[key] or tbl
                            local a = json.array()
                            for _, s in ipairs(objList(src)) do a[#a + 1] = assetId(s) end
                            return a
                        end
                        e.statuses = names(act, "activeStatuses")
                        e.inactiveStatuses = names(inact, "inactiveStatuses")
                    end)
                end
                if st.modifiers then
                    e.modifiers = dumpFiltered(c, { "TrustModifier", "FervorModifiers", "RepresentationModifiers" }, 3, 10)
                end
                if st.desirecomp then
                    pcall(function()
                        local owner = c:GetOwner()
                        if not reflect.isValid(owner) then return end
                        local dc = owner:GetComponentByClass(StaticFindObject("/Script/Frostpunk2.PXCommunityDesireComponent"))
                        if reflect.isValid(dc) then
                            e.desireComponent = simplify(reflect.dump(dc, { depth = 3, gameOnly = true, arrayLimit = 8 }), 4)
                        else
                            e.desireComponent = "none on community actor"
                        end
                    end)
                end
                e.ref = reflect.path(c)
                list[#list + 1] = e
            end
        end
        out.fervorTotal = fervorTotal
        out.communities = list
        if st.planned then out.plannedPromises = simplify(try(du, "GetPlannedPromises", { ctx() }), 4) end
        return out
    end

    ---------------------------------------------------------------------------
    -- vote_predict

    local function voteInfo(args)
        local city = A.city(args)
        local p = resolvePolicy(args.policy)
        local st = stages(args.detail)
        local parl = h.parliament()
        local sub = subsystem()
        local u = pu()
        local out = { policy = assetId(p), inParliament = inParliament(), phase = phaseName() }
        out.cutscene = cutscene()
        out.name = textProp(p, { "IngameName" })
        pcall(function()
            local ag = u:GetCurrentPolicyFromAgenda(ctx())
            if reflect.isValid(ag) then out.agendaPolicy = assetId(ag) end
        end)
        if sub and parl then
            pcall(function() out.requiredVotes = sub:GetRequiredVotesNumber(p, parl) end)
            pcall(function() out.promisedThisSession = sub:IsPolicyPromisedInCurrentParliament(p) end)
        end
        pcall(function() out.swayable = u:IsPolicySwayable(ctx(), p) end)
        pcall(function() out.swayMode = enumName("EPXSwayMode", u:GetSwayMode(ctx())) end)
        pcall(function() out.swayCost = round(u:GetSwayModifierCost(ctx()), 2) end)
        pcall(function() out.swayEffectiveness = round(u:GetPredictedSwayEffectivness(ctx()), 2) end)
        local tally = { For = 0, Against = 0, Hesitant = 0 }
        local per = json.array()
        local want = lower(args.community)
        for _, t in ipairs(h.parliamentCommunityTypes(parl)) do
            local e = { id = assetId(t) }
            pcall(function() e.seats = u:GetRepresentativesCountFromCommunityType(parl, t) end)
            pcall(function() e.support = enumName("EPXVoteAttitude", u:GetCommunitySupportToPolicy(ctx(), t, p)) end)
            if tally[e.support] and type(e.seats) == "number" then tally[e.support] = tally[e.support] + e.seats end
            if not want or (e.id or ""):lower():find(want, 1, true) then
                pcall(function() e.attitude = enumName("EPXCommunityPolicyAttitude", u:GetAttitudeToPolicy(ctx(), t, p)) end)
                if sub and parl then
                    pcall(function()
                        local r = {}
                        e.canNegotiate = sub:CanNegotiateWithCommunity(parl, t, p, r)
                        if not e.canNegotiate then e.reason = enumName("EPXNegotationNotAllowReason", r.outReason) end
                    end)
                    pcall(function() e.canBypass = sub:CanBypassVoteForCommunity(parl, t, p) end)
                end
                if st.predict and parl then
                    local r = {}
                    local res = try(u, "GetPredictedVoteResultForCommunityType", { ctx(), parl, p, t, r })
                    e.predicted = simplify(res, 3) or res
                    if r.outAttitude ~= nil then e.predictedAttitude = enumName("EPXVoteAttitude", r.outAttitude) end
                end
                per[#per + 1] = e
            end
        end
        out.communities = per
        out.seats = tally
        if type(out.requiredVotes) == "number" then
            out.margin = tally.For - out.requiredVotes
            out.passesIfHesitantAgainst = tally.For >= out.requiredVotes
            out.passesIfHesitantFor = tally.For + tally.Hesitant >= out.requiredVotes
        end
        if st.history and parl then
            local okD, d = pcall(reflect.dump, parl, { depth = 4, gameOnly = true, filter = "VotingHistory", arrayLimit = 200 })
            local items = okD and type(d) == "table" and d.VotingHistory or nil
            if type(items) == "table" and items.items then items = items.items end
            if type(items) == "table" then
                local n = tonumber(args.sessions) or 3
                local hist = json.array()
                for i = math.max(1, #items - n + 1), #items do hist[#hist + 1] = simplify(items[i], 4) end
                out.history = hist
            else
                out.history = { error = okD and "no VotingHistory property" or tostring(d) }
            end
        end
        return out, p, city
    end

    ---------------------------------------------------------------------------
    -- negotiate status. InstructNegotiate/BypassVote/Negotiate take PXVoteBypassData (FText) and SetDesire/MakePromise
    -- take PXDesire (FText): none of them are called. Negotiation runs through council_ui button events.

    local INTRO, GROUP = "PXHODNegotiationsIntroPanel", "PXHODGroupNegotiationsPanel"

    local function negotiationStatus(args, st)
        local info, p, city = voteInfo({ policy = args.policy, community = args.community, city = args.city, detail = args.detail })
        info.introPanelVisible = widgetVisible(INTRO)
        info.groupPanelVisible = widgetVisible(GROUP)
        if st.panel then
            local g = transientWidget(GROUP, false)
            if g then info.groupPanel = dumpFiltered(g, { "Desire", "Communit", "Policy", "Result", "Promise", "Vote" }, 2, 6) end
        end
        if st.widgets then
            local ws = json.array()
            for _, w in ipairs(FindAllOf("UserWidget") or {}) do
                if #ws >= 40 then break end
                local cls = reflect.className(w) or ""
                if cls:find("Negotiat") or cls:find("Desire") or cls:find("Promise") or cls:find("HOD") then
                    if reflect.isValid(w) and (reflect.path(w) or ""):find("^/Engine/Transient") then
                        local okV, vis = pcall(function() return w:IsVisible() end)
                        if okV and vis then ws[#ws + 1] = { class = cls, ref = reflect.path(w) } end
                    end
                end
            end
            info.widgets = ws
        end
        return info, p, city
    end

    -- Read after a mutation: an error becomes data, so a caller never retries a mutation that already ran.
    local function afterRead(fn)
        local ok, v = pcall(fn)
        if ok then return v end
        return { error = tostring(v) }
    end

    -- negotiate: read-only status for one community plus cancel (InstructBreakNegotiations). The negotiation itself
    -- runs through council_ui (panel button events; measured 2026-10-11): negotiate -> community -> side -> term -> accept.
    local function negotiate(args)
        local st = stages(args.detail)
        if args.cancel then
            local okG, why = pcall(councilGate, "negotiate cancel", nil)
            if args.dryRun then
                local r = { step = "cancel", dryRun = true, phase = phaseName() }
                if not okG then r.wouldRefuse = why end
                return r
            end
            if not okG then error(why, 0) end
            cdo("PXInstructionUtils"):InstructBreakNegotiations(ctx())
            return { step = "cancel", done = true, status = afterRead(function() return (negotiationStatus(args, {})) end) }
        end
        for _, k in ipairs({ "open", "side", "term", "confirm" }) do
            if args[k] ~= nil and args[k] ~= false then
                error("negotiate " .. k .. " moved to council_ui: step=negotiate, community community=<id>, side side=for|against, terms, term index=N, accept", 0)
            end
        end
        if not args.community then error("community required (id substring; see fp2 vote_predict)", 0) end
        local info = negotiationStatus(args, st)
        info.next = "fp2 council_ui step=negotiate -> step=community community=<id> -> step=side side=for -> step=terms -> step=term index=N -> step=accept -> step=vote"
        return info
    end

    ---------------------------------------------------------------------------
    -- Community actions (Fund projects, Promote, Condemn, Deradicalize, Round-up, Grant agenda, ...)

    local function actionText(a, props) return textProp(a, props) end

    local function actionsFor(c)
        local cau = cdo("PXCommunityActionUtils")
        local visible, possible = {}, {}
        pcall(function() visible = objList(cau:GetVisibleCommunityActions(ctx(), c.Type, false)) end)
        pcall(function()
            for _, a in ipairs(objList(cau:GetPossibleCommunityActions(ctx(), c.Type))) do possible[reflect.path(a) or "?"] = a end
        end)
        -- Possible actions that are not in the visible list still count.
        local seen = {}
        for _, a in ipairs(visible) do seen[reflect.path(a) or "?"] = true end
        for path, a in pairs(possible) do if not seen[path] then visible[#visible + 1] = a end end
        return visible, possible
    end

    local function actionInfo(a, c, possible, brief, details)
        local cau = cdo("PXCommunityActionUtils")
        local e = { id = assetId(a) }
        e.name = actionText(a, NAME_PROPS)
        if not brief then e.description = actionText(a, DESC_PROPS) end
        e.possible = possible[reflect.path(a) or "?"] ~= nil
        pcall(function()
            local w = cooldownWeeks(cau:GetCommunityActionCooldownTimeLeft(ctx(), a, c))
            if w and w > 0 then e.cooldownWeeks = w end
        end)
        pcall(function() e.everExecuted = cau:WasCommunityActionEverExecuted(ctx(), a, c) end)
        if details then
            local okD, d = pcall(reflect.dump, a, { depth = 3, gameOnly = true, arrayLimit = 8 })
            if okD then e.asset = simplify(d, 4) or d else e.asset = { error = tostring(d) } end
        end
        return e
    end

    local function communityActions(args)
        local city = A.city(args)
        local out = json.array()
        local result = { city = assetId(city.CityType), communities = out }
        local list = args.community and { findCommunity(city, args.community) } or cityCommunities(city)
        for _, c in ipairs(list) do
            local visible, possible = actionsFor(c)
            local acts = json.array()
            for _, a in ipairs(visible) do
                local id = (assetId(a) or ""):lower()
                if not args.contains or id:find(lower(args.contains), 1, true) then
                    acts[#acts + 1] = actionInfo(a, c, possible, args.brief, args.details)
                end
            end
            out[#out + 1] = { community = communityId(c), actions = acts }
        end
        return result
    end

    local function findAction(c, want)
        want = lower(want)
        if not want or want == "" then error("action required (id substring; see fp2 community_actions)", 0) end
        local visible, possible = actionsFor(c)
        local partial
        local ids = {}
        for _, a in ipairs(visible) do
            local id = (assetId(a) or ""):lower()
            ids[#ids + 1] = id
            if id == want then return a, possible end
            local name = (lower(actionText(a, NAME_PROPS)) or "")
            if not partial and (id:find(want, 1, true) or name:find(want, 1, true)) then partial = a end
        end
        if partial then return partial, possible end
        error("no community action matching " .. want .. " for " .. communityId(c) .. " (have: " .. table.concat(ids, ", ") .. ")", 0)
    end

    local function communityAction(args, a0, c0)
        A.assertNoCutscene("community_action")
        local city = A.city(args)
        local c = c0 or findCommunity(city, args.community)
        local a, possible
        if a0 then
            a = a0
            local _
            _, possible = actionsFor(c)
        else
            a, possible = findAction(c, args.action)
        end
        local info = actionInfo(a, c, possible, false, args.dryRun and args.details)
        info.community = communityId(c)
        local target, district
        if args.target then
            target = findCommunity(city, args.target, "target")
            info.target = communityId(target)
        end
        if args.district then
            local label
            district, label = h.findDistrict(city, args.district)
            info.district = label
        end
        pcall(function() info.standingBefore = round(cdo("PXTrustUtils"):GetCommunityStanding(ctx(), city.Nation, c), 1) end)
        pcall(function() info.fervorBefore = c.Fervor end)
        if args.dryRun then info.dryRun = true; return info end
        if not info.possible then
            error("community_action refused: " .. tostring(info.id) .. " is not possible now for " .. info.community ..
                (info.cooldownWeeks and (" (cooldown " .. info.cooldownWeeks .. " weeks)") or ""), 0)
        end
        local origin = A.leaderOrigin()
        for what, o in pairs({ action = a, community = c, origin = origin }) do
            if not reflect.isValid(o) then error("invalid " .. what, 0) end
        end
        if target ~= nil and not reflect.isValid(target) then error("invalid target", 0) end
        if district ~= nil and not reflect.isValid(district) then error("invalid district", 0) end
        local cPath, nation = reflect.path(c), city.Nation
        local nationPath = reflect.path(nation)
        cdo("PXInstructionUtils"):InstructCommunityAction(ctx(), a, origin, c, false, district, target)
        c, target, district, nation = nil, nil, nil, nil
        info.executed = true
        local now = fresh(cPath)
        if now then
            local n = fresh(nationPath)
            pcall(function() if n then info.standingAfter = round(cdo("PXTrustUtils"):GetCommunityStanding(ctx(), n, now), 1) end end)
            pcall(function() info.fervorAfter = now.Fervor end)
            pcall(function() info.sizeAfter = now.Size end)
            pcall(function() info.everExecutedAfter = cdo("PXCommunityActionUtils"):WasCommunityActionEverExecuted(ctx(), a, now) end)
            pcall(function()
                local w = cooldownWeeks(cdo("PXCommunityActionUtils"):GetCommunityActionCooldownTimeLeft(ctx(), a, now))
                info.cooldownWeeksAfter = w
            end)
        else
            info.communityGone = true
        end
        return info
    end

    ---------------------------------------------------------------------------
    -- Promises outside negotiation: a promise is a community action when the game lists one
    -- (trust category "Make promise"); there is no struct-free MakePromise path.

    local function promise(args)
        local city = A.city(args)
        local c = findCommunity(city, args.community)
        local visible, possible = actionsFor(c)
        local matches = {}
        local want = lower(args.action)
        for _, a in ipairs(visible) do
            local id = (assetId(a) or ""):lower()
            local name = (lower(actionText(a, NAME_PROPS)) or "")
            local isPromise = id:find("promise", 1, true) or name:find("promise", 1, true)
            if isPromise and (not want or id:find(want, 1, true) or name:find(want, 1, true)) then matches[#matches + 1] = a end
        end
        if #matches == 0 then
            local proms = json.array()
            for _, q in ipairs(communityPromises(c)) do proms[#proms + 1] = promiseInfo(q, false) end
            error("no promise-type community action for " .. communityId(c) .. ". Promises are made in the Council: " ..
                "fp2 council_ui step=negotiate, community, side, terms/term, accept, vote. Active promises: " .. json.encode(proms), 0)
        end
        if #matches > 1 and not args.dryRun then
            local ids = {}
            for _, a in ipairs(matches) do ids[#ids + 1] = assetId(a) end
            error("several promise actions match; pass action=<id>: " .. table.concat(ids, ", "), 0)
        end
        if args.dryRun then
            local out = json.array()
            for _, a in ipairs(matches) do out[#out + 1] = actionInfo(a, c, possible, false, args.details) end
            return { community = communityId(c), candidates = out, dryRun = true }
        end
        return communityAction(args, matches[1], c)
    end

    ---------------------------------------------------------------------------
    -- promise_abandon. Measured 2026-10-11: PXDesireUtils.AbandonPromise(ctx, <GetCommunityPromises element,
    -- BP_SimplePromise_Quest_C>) hung the game thread and the game died (UE4SS process_lua_function ->
    -- FAnsiString::operator= -> AK::WriteBytesMem::SetCount). That stack has so far meant a wrong argument class to a
    -- static Utils function (inferred). This version checks the element against the param's declared class first.
    -- path=quest instead fails the quest through PXQuestUtils.FinishQuest(ctx, quest, false), the generic quest
    -- failure path (a failed promise is a failed PXPromiseQuest; inferred from the observers'
    -- OnPromiseQuestFinished(promise, bSuccess) signatures).

    -- Declared class of an object param (ObjectProperty.GetPropertyClass), as a UClass and its name.
    local function paramClass(obj, fnName, paramName)
        local f = obj[fnName]
        if not reflect.isValid(f) then return nil end
        local cls
        pcall(function()
            f:ForEachProperty(function(p)
                if reflect.propName(p) == paramName then
                    local c = p:GetPropertyClass()
                    if reflect.isValid(c) then cls = c end
                    return true
                end
            end)
        end)
        return cls, cls and reflect.shortName(cls) or nil
    end

    local function isA(o, cls)
        if not (reflect.isValid(o) and reflect.isValid(cls)) then return nil end
        local ok, v = pcall(function() return o:IsA(cls) end)
        if ok then return v and true or false end
        return nil
    end

    local function classChain(o)
        local out = json.array()
        pcall(function()
            local c = o:GetClass()
            local guard = 0
            while reflect.isValid(c) and guard < 12 do
                out[#out + 1] = reflect.shortName(c)
                c = c:GetSuperStruct()
                guard = guard + 1
            end
        end)
        return out
    end

    local function promiseAbandon(args)
        A.assertNoCutscene("promise_abandon")
        if inParliament() then error("promise_abandon refused inside the Council scene", 0) end
        local path = lower(args.path) or "quest"
        if path ~= "abandon" and path ~= "quest" then error("path must be abandon (PXDesireUtils.AbandonPromise) or quest (PXQuestUtils.FinishQuest false)", 0) end
        local city = A.city(args)
        local c = findCommunity(city, args.community)
        local list = communityPromises(c)
        if #list == 0 then error("no active promise for " .. communityId(c), 0) end
        local q
        local sel = args.promise
        if sel == nil and #list == 1 then q = list[1]
        elseif tonumber(sel) then q = list[tonumber(sel)]
        elseif sel ~= nil then
            for _, x in ipairs(list) do
                local n = ""
                pcall(function() n = (textOf(x:GetQuestName()) or ""):lower() end)
                if n:find(lower(sel), 1, true) then q = x; break end
            end
        end
        local all = json.array()
        for i, x in ipairs(list) do
            local e = promiseInfo(x, false)
            e.index = i
            e.class = reflect.className(x)
            all[#all + 1] = e
        end
        if not reflect.isValid(q) then error("pick a promise: promise=<index|name substring>; active: " .. json.encode(all), 0) end
        local du, qu = cdo("PXDesireUtils"), cdo("PXQuestUtils")
        local out = { community = communityId(c), path = path, promise = promiseInfo(q, false) }
        out.promiseClass = classChain(q)
        local fn, fnObj, param = "AbandonPromise", du, "promise"
        if path == "quest" then fn, fnObj, param = "FinishQuest", qu, "Quest" end
        local declared, declaredName = paramClass(fnObj, fn, param)
        out.call = (path == "quest" and "PXQuestUtils.FinishQuest(ctx, quest, false)" or "PXDesireUtils.AbandonPromise(ctx, promise)")
        out.paramClass = declaredName or "unknown"
        out.matchesParam = isA(q, declared)
        if args.dryRun then out.dryRun = true; out.active = all; return out end
        if path == "abandon" and not args.force then
            error("promise_abandon path=abandon refused: PXDesireUtils.AbandonPromise crashed the game once with a valid " ..
                "PXPromiseQuest (measured). Use the default path=quest, or pass force=true", 0)
        end
        if out.matchesParam == false then
            error("promise_abandon refused: " .. tostring(reflect.className(q)) .. " is not a " .. tostring(declaredName) .. " (the " .. fn .. " param)", 0)
        end
        if out.matchesParam == nil and not args.force then
            error("promise_abandon refused: cannot read the declared class of " .. fn .. "." .. param .. "; pass force=true after checking dryRun", 0)
        end
        local qPath, cPath = reflect.path(q), reflect.path(c)
        if path == "quest" then qu:FinishQuest(ctx(), q, false) else du:AbandonPromise(ctx(), q) end
        q, c = nil, nil
        out.done = true
        local now = fresh(cPath)
        if now then
            local left = 0
            for _, x in ipairs(communityPromises(now)) do
                left = left + 1
                if reflect.path(x) == qPath then out.stillActive = true end
            end
            out.remaining = left
            pcall(function() out.standingAfter = round(cdo("PXTrustUtils"):GetCommunityStanding(ctx(), city.Nation, now), 1) end)
        end
        return out
    end

    ---------------------------------------------------------------------------
    -- sway (Council pressure modes). IsSwayAvailable/IsSwayVisible return PXCheckResult (FText): unreadable,
    -- so setting a mode requires the Council scene and a swayable policy; the game charges the cost at the vote.

    local function sway(args)
        local u = pu()
        local enumPath = paramEnum(u, "SetSwayMode", "swayMode") or "EPXSwayMode"
        local out = { inParliament = inParliament(), phase = phaseName() }
        pcall(function() out.mode = enumName(enumPath, u:GetSwayMode(ctx())) end)
        pcall(function() out.cost = round(u:GetSwayModifierCost(ctx()), 2) end)
        pcall(function() out.effectiveness = round(u:GetPredictedSwayEffectivness(ctx()), 2) end)
        local modes = json.array()
        for v, n in pairs(reflect.enumNames(enumPath)) do modes[#modes + 1] = { value = v, name = n } end
        table.sort(modes, function(x, y) return x.value < y.value end)
        out.modes = modes
        local okP, p = pcall(resolvePolicy, args.policy)
        if okP then
            out.policy = assetId(p)
            pcall(function() out.swayable = u:IsPolicySwayable(ctx(), p) end)
        end
        if args.mode == nil then return out end
        councilGate("sway")
        if not okP then error("sway refused: no policy (pass policy= or put one on the agenda)", 0) end
        if out.swayable ~= true then error("sway refused: " .. tostring(out.policy) .. " is not swayable", 0) end
        local reset = lower(args.mode) == "reset"
        local v
        if not reset then
            v = enumValue(enumPath, args.mode)
            if v == nil then error("unknown sway mode " .. tostring(args.mode) .. " (see modes)", 0) end
        end
        out.requested = reset and "reset" or reflect.enumNames(enumPath)[v]
        if args.dryRun then out.dryRun = true; return out end
        if reset then u:ResetSwayMode(ctx()) else u:SetSwayMode(ctx(), v) end
        pcall(function() out.modeAfter = enumName(enumPath, u:GetSwayMode(ctx())) end)
        pcall(function() out.costAfter = round(u:GetSwayModifierCost(ctx()), 2) end)
        return out
    end

    ---------------------------------------------------------------------------
    -- council_ui: Council (House of Delegates) panel state and the panels' own Blueprint handlers, so the UI stays
    -- in step with the Council. Measured 2026-10-11: `propose` moved the phase to Negotiations while the hub stayed
    -- on its lobby; a click on "PROPOSE A LAW" then crashed the game in UI rendering. Handlers come from the KBM
    -- describe dumps (research/describe/WBP_Parliament_*.json): button events take only the widget's own button
    -- (BndEvt__..._PXButtonEvent__DelegateSignature(Button)), so no FText struct crosses the Lua boundary. Calling
    -- those events from Lua is unmeasured: save before each first use.

    local HUB = "WBP_ParliamentHub_C"
    local HUB_PANELS = { "LobbyScreenPanel", "LawSelectionPanel", "NegotiationPanel", "ResultsScreenPanel" } -- measured property names
    local MAIN = "WBP_Parliament_MainScreen_C"
    local POLICY_CHOICE = "WBP_Parliament_PolicyChoicePanel_C"
    local POLICY_ENTRY = "WBP_ParliamentAdditionalPolicy_C"
    local INTRO_KBM = "WBP_Parliament_NegotiationsIntroPanel_C"
    local GROUP_KBM = "WBP_Parliament_GroupNegotiationsPanel_C"
    local UI_PANELS = { MAIN, "WBP_Parliament_LawCategoryList_C", "WBP_Parliament_LawListPanel_C", POLICY_CHOICE, INTRO_KBM, GROUP_KBM }

    local EV = {
        laws = "BndEvt__WBP_HOD_MainScreen_ExploreLawsButton_K2Node_ComponentBoundEvent_4_PXButtonEvent__DelegateSignature",
        negotiate = "BndEvt__WBP_HOD_MainScreen_NegotiateButton_K2Node_ComponentBoundEvent_2_PXButtonEvent__DelegateSignature",
        vote = "BndEvt__WBP_HOD_MainScreen_VoteButton_K2Node_ComponentBoundEvent_1_PXButtonEvent__DelegateSignature",
        changeProposal = "BndEvt__WBP_HOD_MainScreen_ChangeProposalButton_K2Node_ComponentBoundEvent_6_PXButtonEvent__DelegateSignature",
        propose = "BndEvt__WBP_HODAdditionalPolicy_ProposeButtonWidget_K2Node_ComponentBoundEvent_9_PXButtonEvent__DelegateSignature",
        accept = "BndEvt__WBP_HOD_GroupNegotiationsPanel_AcceptNegotiation_Button_K2Node_ComponentBoundEvent_1_PXButtonEvent__DelegateSignature",
        side = "BndEvt__WBP_HoD_Negotiationsingle_myterm_Widget_MyTermsDecisionButton_K2Node_ComponentBoundEvent_0_PXButtonEvent__DelegateSignature",
        term = "BndEvt__WBP_Parliament_Negotiation_option_Widget_TheirTermsCheckmarkButton_K2Node_ComponentBoundEvent_1_PXButtonEvent__DelegateSignature",
    }

    -- Live hub: the instance under /Engine/Transient.GameEngine_* (the other FindAllOf match is the class template).
    local function liveHub()
        for _, w in ipairs(FindAllOf(HUB) or {}) do
            if reflect.isValid(w) and (reflect.path(w) or ""):find("GameEngine", 1, true) then return w end
        end
        return nil
    end

    -- Object property of a widget, read only when the property is an object property (SoftObject reads crash).
    local function widgetProp(w, name)
        local okC, cls = pcall(function() return w:GetClass() end)
        if not okC then return nil end
        local p = reflect.findProperty(cls, name)
        local t = p and reflect.propType(p)
        if t ~= "ObjectProperty" and t ~= "ObjectPtrProperty" then return nil end
        local ok, v = pcall(function() return w[name] end)
        if ok and reflect.isValid(v) then return v end
        return nil
    end

    local function isVisible(w)
        local ok, vis = pcall(function() return w:IsVisible() end)
        return ok and vis or false
    end

    local function hubPanels()
        local hub = liveHub()
        if not hub then return nil end
        local out = json.object()
        for _, name in ipairs(HUB_PANELS) do
            local w = widgetProp(hub, name)
            if w then out[name] = isVisible(w) end
        end
        return out
    end

    local function lobbyVisible()
        local hp = hubPanels()
        return hp ~= nil and hp.LobbyScreenPanel == true
    end

    -- Up to `limit` texts from a widget's TextBlock/RichTextBlock members (GetText returns a plain FText).
    local function widgetTexts(w, limit)
        local out = json.array()
        local okC, cls = pcall(function() return w:GetClass() end)
        if not okC then return out end
        reflect.forEachProperty(cls, function(p)
            if #out >= (limit or 4) then return true end
            local t = reflect.propType(p)
            if t == "ObjectProperty" or t == "ObjectPtrProperty" then
                local name = reflect.propName(p)
                local ok, v = pcall(function() return w[name] end)
                if ok and reflect.isValid(v) and (reflect.className(v) or ""):find("TextBlock", 1, true) then
                    local okT, s = pcall(function() return textOf(v:GetText()) end)
                    if okT and s and s ~= "" then out[#out + 1] = s end
                end
            end
        end)
        return out
    end

    -- Children of a layout widget (UPanelWidget.GetAllChildren); nil when the layout is not a panel widget.
    local function children(layout)
        local ok, list = pcall(function() return objList(layout:GetAllChildren()) end)
        return ok and list or nil
    end

    local function ownerWidget(w)
        local path = reflect.path(w) or ""
        local ownerPath = path:match("^(.-)%.WidgetTree_[^%.]*%.[^%.]+$")
        return ownerPath and fresh(ownerPath) or nil
    end

    local function arrayProp(w, name)
        local okC, cls = pcall(function() return w:GetClass() end)
        if not okC then return {} end
        local p = reflect.findProperty(cls, name)
        if p and (reflect.propType(p) ~= "ArrayProperty" or reflect.unsafeRead(p)) then return {} end
        local ok, v = pcall(function() return w[name] end)
        return ok and v ~= nil and objList(h.uarray(v)) or {}
    end

    -- Visible texts of an option widget (only the PromiseTypeSwitcher page in use is visible).
    local function visibleTexts(w, limit)
        local out = json.array()
        local okC, cls = pcall(function() return w:GetClass() end)
        if not okC then return out end
        reflect.forEachProperty(cls, function(p)
            if #out >= (limit or 6) then return true end
            local t = reflect.propType(p)
            if t == "ObjectProperty" or t == "ObjectPtrProperty" then
                local name = reflect.propName(p)
                local ok, v = pcall(function() return w[name] end)
                if ok and reflect.isValid(v) and (reflect.className(v) or ""):find("TextBlock", 1, true) and isVisible(v) then
                    local okT, s = pcall(function() return textOf(v:GetText()) end)
                    if okT and s and s ~= "" then out[#out + 1] = s end
                end
            end
        end)
        return out
    end

    -- Their terms (faction demands) in screen order: { index, option (widget), text, promiseType }.
    local OPTION = "WBP_Parliament_Negotiation_option_Widget_C"
    local function termOptions(group)
        local out = {}
        local opts, source = {}, "TheirTermsRadioLayout.ChildButtons"
        local layout = widgetProp(group, "TheirTermsRadioLayout")
        for _, btn in ipairs(layout and arrayProp(layout, "ChildButtons") or {}) do
            local o = ownerWidget(btn)
            if o then opts[#opts + 1] = o end
        end
        if #opts == 0 then
            source = "visible " .. OPTION .. " instances, newest first"
            local found = {}
            for _, w in ipairs(FindAllOf(OPTION) or {}) do
                local path = reflect.path(w) or ""
                if reflect.isValid(w) and path:find("GameEngine", 1, true) and isVisible(w) then
                    found[#found + 1] = { w = w, n = tonumber(path:match("_(%d+)$")) or 0 }
                end
            end
            table.sort(found, function(a, b) return a.n > b.n end)
            for _, f in ipairs(found) do opts[#opts + 1] = f.w end
        end
        out.source = source
        for i, opt in ipairs(opts) do
            local e = { index = i, option = opt, ref = reflect.path(opt) }
            do
                e.text = visibleTexts(opt, 6)
                pcall(function()
                    local d = reflect.dump(opt, { depth = 1, filter = "PromiseType" })
                    local v = d and d.PromiseType
                    e.promiseType = type(v) == "table" and v.name and (v.name:gsub("^.*::", "")) or v
                end)
            end
            out[#out + 1] = e
        end
        return out
    end

    local function councilUiState()
        local out = { inParliament = inParliament(), phase = phaseName(), cutscene = cutscene(), pauseReasons = A.pauseReasons() }
        out.hub = hubPanels()
        out.lobbyVisible = lobbyVisible()
        local panels = json.object()
        for _, cls in ipairs(UI_PANELS) do
            if transientWidget(cls, true) then panels[cls] = true
            elseif transientWidget(cls, false) then panels[cls] = false end
        end
        out.panels = panels
        pcall(function()
            local ag = pu():GetCurrentPolicyFromAgenda(ctx())
            if reflect.isValid(ag) then out.agendaPolicy = assetId(ag) end
        end)
        pcall(function()
            local hub = liveHub()
            local dlg = hub and widgetProp(hub, "ParlimentHubDialog")
            if dlg then out.hubDialog = { class = reflect.className(dlg), visible = isVisible(dlg), ref = reflect.path(dlg) } end
        end)
        out.steps = json.array({ "laws", "law", "select", "negotiate", "community", "side", "terms", "term", "accept", "vote", "sway", "sync", "negotiate_open" })
        return out
    end

    -- Visible policy entries (WBP_ParliamentAdditionalPolicy_C) with their policy ids.
    local function policyEntries()
        local out = {}
        for _, w in ipairs(FindAllOf(POLICY_ENTRY) or {}) do
            if reflect.isValid(w) and (reflect.path(w) or ""):find("GameEngine", 1, true) and isVisible(w) then
                local pol = widgetProp(w, "Policy")
                out[#out + 1] = { widget = w, policy = pol and assetId(pol) or nil }
            end
        end
        return out
    end

    local PHASE_HANDLERS = {
        none = "OnOpenNonePhase", agenda = "OnOpenAgendaPhase", negotiations = "OnOpenNegotiationPhase",
        vote = "OnOpenVotingPhase", maintenance = "OnOpenMaintenancePhase",
    }

    local function councilUi(args)
        local step = lower(args.step)
        local state = councilUiState()
        if not step then return state end
        local out = { step = step, before = state }
        if not state.inParliament then error("council_ui " .. step .. " refused: Council scene not open", 0) end
        A.assertNoCutscene("council_ui " .. step)
        local function need(cls)
            if state.panels[cls] ~= true then error("council_ui " .. step .. " refused: " .. cls .. " not visible", 0) end
            return transientWidget(cls, true) or error(cls .. " not visible", 0)
        end
        local function needPhase(name)
            if not tostring(state.phase or ""):find(name, 1, true) then
                error("council_ui " .. step .. " refused: phase is " .. tostring(state.phase) .. ", needs " .. name, 0)
            end
        end
        -- Re-find the widget at run time (never reuse a reference across a handler) and fire `fn`.
        local function finish(describe, fire)
            out.call = describe
            if args.dryRun then out.dryRun = true; return out end
            fire()
            out.after = afterRead(councilUiState)
            return out
        end
        -- A button event: fn(ownButton). Resolves the button property first so dryRun shows the refs.
        local function buttonEvent(cls, fn, buttonProp)
            local w = need(cls)
            local btn = widgetProp(w, buttonProp)
            if not btn then error(cls .. "." .. buttonProp .. " not found", 0) end
            out.button = reflect.path(btn)
            return finish(cls .. "." .. fn .. "(" .. buttonProp .. ")", function()
                local w2 = transientWidget(cls, true)
                local b2 = w2 and widgetProp(w2, buttonProp)
                if not b2 then error(cls .. " gone before the call", 0) end
                safeCall(w2, fn, b2)
            end)
        end

        if step == "laws" then
            -- Lobby "PROPOSE A LAW" (ExploreLawsButton).
            return buttonEvent(MAIN, EV.laws, "ExploreLawsButton")
        end
        if step == "law" then
            -- Open a law's policy list: PXHODPolicyChoicePanel.OpenLawPoliciesPanel(law) (native).
            if state.lobbyVisible then error("council_ui law refused: the hub lobby is visible (step=laws first)", 0) end
            local p = resolvePolicy(args.policy)
            local law = cdo("PXPolicyUtils"):GetLaw(h.playerPolicyComponent(), p)
            if not reflect.isValid(law) then error("no law for policy " .. tostring(assetId(p)), 0) end
            if not transientWidget(POLICY_CHOICE, false) then error("council_ui law refused: " .. POLICY_CHOICE .. " not found", 0) end
            out.policy, out.law = assetId(p), assetId(law)
            return finish(POLICY_CHOICE .. ".OpenLawPoliciesPanel(" .. out.law .. ")", function()
                local panel = transientWidget(POLICY_CHOICE, false)
                if panel then safeCall(panel, "OpenLawPoliciesPanel", law) end
            end)
        end
        if step == "select" then
            -- Propose button of the visible policy entry whose Policy matches.
            local want = lower(args.policy)
            local entries = policyEntries()
            local ids = json.array()
            for _, e in ipairs(entries) do ids[#ids + 1] = e.policy end
            out.visiblePolicies = ids
            if not want then
                if args.dryRun then out.dryRun = true; return out end
                error("council_ui select needs policy=<id>; visible: " .. json.encode(ids), 0)
            end
            -- Exact asset id first; a substring only when it is unique (measured: a substring match picked
            -- Food_Adaptation_DrumhouseAdaptation for Food_Adaptation).
            want = want:gsub("^da_", "")
            local hit
            local partial = {}
            for _, e in ipairs(entries) do
                local id = lower(e.policy) or ""
                if id == want then hit = e; break end
                if id ~= "" and id:find(want, 1, true) then partial[#partial + 1] = e end
            end
            if not hit and #partial == 1 then hit = partial[1] end
            if not hit and #partial > 1 then
                local names = {}
                for _, e in ipairs(partial) do names[#names + 1] = e.policy end
                error("policy " .. want .. " matches several entries, pass the exact id: " .. table.concat(names, ", "), 0)
            end
            if not hit then error("no visible policy entry matching " .. want .. "; visible: " .. json.encode(ids) .. " (step=law first)", 0) end
            local btn = widgetProp(hit.widget, "ProposeButtonWidget")
            if not btn then error(POLICY_ENTRY .. ".ProposeButtonWidget not found", 0) end
            out.policy = hit.policy
            local entryPath = reflect.path(hit.widget)
            return finish(POLICY_ENTRY .. "." .. EV.propose .. "(ProposeButtonWidget)", function()
                local w2 = fresh(entryPath)
                local b2 = w2 and widgetProp(w2, "ProposeButtonWidget")
                if not b2 then error("policy entry gone before the call", 0) end
                safeCall(w2, EV.propose, b2)
            end)
        end
        if step == "negotiate" then
            needPhase("Negotiat")
            return buttonEvent(MAIN, EV.negotiate, "NegotiateButton")
        end
        if step == "vote" then
            return buttonEvent(MAIN, EV.vote, "VoteButton")
        end
        if step == "change_proposal" then
            return buttonEvent(MAIN, EV.changeProposal, "ChangeProposalButton")
        end
        if step == "community" then
            -- Pick a group in the intro panel: OnChoiceClickedFunc(communityType), the handler a group click reaches.
            needPhase("Negotiat")
            need(INTRO_KBM)
            local city = A.city(args)
            local c = findCommunity(city, args.community)
            local t = c.Type
            if not reflect.isValid(t) then error("community type invalid", 0) end
            out.community = communityId(c)
            return finish(INTRO_KBM .. ".OnChoiceClickedFunc(" .. tostring(assetId(t)) .. ")", function()
                local intro = transientWidget(INTRO_KBM, true)
                if intro then safeCall(intro, "OnChoiceClickedFunc", t) end
            end)
        end
        if step == "side" then
            -- Vote side we ask for (MY TERMS): the For/Against widget's own MyTermsDecisionButton event (measured).
            need(GROUP_KBM)
            local s = lower(args.side)
            if s ~= "for" and s ~= "against" then error("side must be for or against", 0) end
            local prop = s == "for" and "ProposeVotingFortheLawWidget" or "ProposeVotingAgainstTheLawWidget"
            local g = transientWidget(GROUP_KBM, true)
            local sideW = g and widgetProp(g, prop)
            local btn = sideW and widgetProp(sideW, "MyTermsDecisionButton")
            if not btn then error(GROUP_KBM .. "." .. prop .. ".MyTermsDecisionButton not found", 0) end
            local sidePath = reflect.path(sideW)
            out.button = reflect.path(btn)
            return finish(prop .. "." .. EV.side .. "(MyTermsDecisionButton)", function()
                local w2 = fresh(sidePath)
                local b2 = w2 and widgetProp(w2, "MyTermsDecisionButton")
                if not b2 then error(prop .. " gone before the call", 0) end
                safeCall(w2, EV.side, b2)
            end)
        end
        if step == "terms" or step == "term" then
            -- THEIR TERMS: option widgets in screen order. term index=N fires the option's TheirTermsCheckmarkButton
            -- event (measured); the game builds the PXDesire itself.
            local g = need(GROUP_KBM)
            local opts = termOptions(g)
            local list = json.array()
            for _, e in ipairs(opts) do list[#list + 1] = { index = e.index, promiseType = e.promiseType, text = e.text, ref = e.ref } end
            out.terms = list
            out.termsSource = opts.source
            out.before = nil
            if step == "terms" then out.call = "read only"; out.dryRun = true; return out end
            local n = tonumber(args.index)
            if n == 0 then error("term index is 1-based (step=terms lists them)", 0) end
            local pick = n and opts[n]
            if not pick or not pick.option then error("term index must be 1.." .. #opts .. " (see step=terms; source " .. tostring(opts.source) .. ")", 0) end
            local optPath = pick.ref
            out.index = n
            return finish("option[" .. n .. "]." .. EV.term .. "(TheirTermsCheckmarkButton)", function()
                local w2 = fresh(optPath)
                local b2 = w2 and widgetProp(w2, "TheirTermsCheckmarkButton")
                if not b2 then error("term option gone before the call", 0) end
                safeCall(w2, EV.term, b2)
            end)
        end
        if step == "accept" then
            return buttonEvent(GROUP_KBM, EV.accept, "AcceptNegotiation_Button")
        end
        if step == "sway" then
            -- "Handle sway the votes"(EPXSwayMode) on the main screen (experimental: BP function, extra listed
            -- params are locals).
            local w = need(MAIN)
            local enumPath = paramEnum(w, "Handle sway the votes", "sway") or "EPXSwayMode"
            local v = enumValue(enumPath, args.mode)
            if v == nil then error("unknown sway mode " .. tostring(args.mode) .. " (DoNotSway, SwayAye, SwayNay)", 0) end
            out.mode = reflect.enumNames(enumPath)[v]
            return finish(MAIN .. ".Handle sway the votes(" .. tostring(out.mode) .. ")", function()
                local w2 = transientWidget(MAIN, true)
                if w2 then safeCall(w2, "Handle sway the votes", v) end
            end)
        end
        if step == "negotiate_open" then
            -- Intro panel's own OpenPolicyNegotiationPanel(policy) (native event); prefer step=negotiate (the button).
            needPhase("Negotiat")
            if state.lobbyVisible then error("council_ui negotiate_open refused: the hub lobby is visible", 0) end
            local p = resolvePolicy(args.policy)
            if not transientWidget(INTRO_KBM, false) then error("council_ui negotiate_open refused: " .. INTRO_KBM .. " not found", 0) end
            out.policy = assetId(p)
            return finish(INTRO_KBM .. ".OpenPolicyNegotiationPanel(" .. out.policy .. ")", function()
                local intro = transientWidget(INTRO_KBM, false)
                if intro then safeCall(intro, "OpenPolicyNegotiationPanel", p) end
            end)
        end
        if step == "sync" then
            -- Experimental: re-run the hub's entry for the current phase (PXMainHODHub.OnOpen*Phase).
            local fn = PHASE_HANDLERS[lower(state.phase) or ""]
            if not fn then error("council_ui sync: no handler for phase " .. tostring(state.phase), 0) end
            if not liveHub() then error("council_ui sync refused: live " .. HUB .. " not found", 0) end
            return finish(HUB .. "." .. fn, function() local hub = liveHub(); if hub then safeCall(hub, fn) end end)
        end
        error("council_ui: unknown step " .. step .. " (steps: " .. table.concat(state.steps, ", ") .. ", change_proposal). " ..
            "Not wired: category, page", 0)
    end

    -- propose guard: refuse while the hub lobby is visible (measured crash path above). force=true skips it.
    -- The "?" tutorial widget in every hub panel is not a modal (measured) and does not block.
    local function proposeGuarded(args)
        if not args.force and lobbyVisible() then
            error("propose refused: the Council hub lobby is visible; use fp2 council_ui step=laws / law / select, or pass force=true", 0)
        end
        return A.propose(args)
    end

    ---------------------------------------------------------------------------
    -- Registration

    def("council_ui", {
        help = "Council hub UI: no step = state (hub sub-panels incl. lobby, panel visibility, phase, agenda, dialog). Steps fire the "
            .. "panels' own handlers and refuse unless the panel/phase fits: laws (lobby PROPOSE A LAW), law policy=<id> (policy list), "
            .. "select policy=<exact id> (propose it), negotiate (Negotiations phase), community community=<id>, side=for|against, "
            .. "terms (list their terms), term index=N, accept, vote, sway mode=<EPXSwayMode>, change_proposal, negotiate_open, sync. args: step, dryRun",
        mutation = true,
        run = councilUi,
    })
    -- Overrides the core propose (registered in commands.lua) with a lobby/tutorial guard; merge into actions.lua later.
    def("propose", {
        help = "Request a council session to vote on a policy (propose a law). Refuses while the Council hub lobby is visible "
            .. "(force=true skips that). args: policy (id substring), skipRecess, dryRun, force",
        mutation = true,
        run = proposeGuarded,
    })
    def("factions", {
        help = "Communities and factions: name, size, % of population, seats, standing, faction trust, fervor, promises "
            .. "(objectives, weeks left); city trust, tension (value/target/progress) and contributors. args: community, city, "
            .. "detail=tiers,affinities,statuses,modifiers,desires,desirecomp,planned|all (opt-in reads; run one stage at a time first)",
        run = factions,
    })
    def("vote_predict", {
        help = "Council vote prediction for a policy (default: agenda): required votes, seats by support, per-community support, "
            .. "attitude, canNegotiate + reason, canBypass, sway state. args: policy, community, detail=predict,history|all, sessions",
        run = function(args) return (voteInfo(args)) end,
    })
    def("negotiate", {
        help = "Negotiation status for one community and a policy (default agenda): canNegotiate + reason, seats, margin, panel "
            .. "visibility; cancel=true runs InstructBreakNegotiations (untested). The negotiation runs through council_ui steps. "
            .. "args: community, policy, cancel, dryRun, detail=panel,widgets",
        mutation = true,
        run = negotiate,
    })
    def("community_actions", {
        help = "Community/faction actions (Fund projects, Promote, Condemn, Deradicalize, Round-up, ...): possible, cooldown weeks, "
            .. "ever executed, name, description. args: community, contains, brief=true, details=true (asset dump with costs)",
        run = communityActions,
    })
    def("community_action", {
        help = "Execute a community action through InstructCommunityAction (Leader origin, isForced=false). "
            .. "args: community, action, target (community), district (label), dryRun, details",
        mutation = true,
        run = function(args) return communityAction(args) end,
    })
    def("promise", {
        help = "Make a promise through a promise-type community action when the game lists one; otherwise points to negotiate. "
            .. "args: community, action, dryRun, details",
        mutation = true,
        run = promise,
    })
    def("promise_abandon", {
        help = "Abandon an active promise. path=quest (default): PXQuestUtils.FinishQuest(quest, false) (measured: promise removed, "
            .. "game fine). path=abandon: PXDesireUtils.AbandonPromise, needs force=true (crashed the game once with a valid "
            .. "PXPromiseQuest). dryRun shows classes and the call. args: community, promise (index or name substring), path, dryRun, force",
        mutation = true,
        run = promiseAbandon,
    })
    def("sway", {
        help = "Council sway (pressure) mode: read mode, cost, effectiveness, modes, policy swayable. Set with mode=<name>|reset "
            .. "(Council scene only, swayable policy). args: policy, mode, dryRun",
        mutation = true,
        run = sway,
    })
end

return M
