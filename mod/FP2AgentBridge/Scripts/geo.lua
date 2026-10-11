-- World positions and world -> screen projection, so the CLI can click game objects.

local reflect = require("reflect")

local geo = {}

local function actorOf(obj)
    if not reflect.isValid(obj) then return nil end
    local ok, isActor = pcall(function() return obj:IsA("/Script/Engine.Actor") end)
    if ok and isActor then return obj end
    local okO, owner = pcall(function() return obj:GetOwner() end)
    if okO and reflect.isValid(owner) then return owner end
    local okP, outer = pcall(function() return obj:GetOuter() end)
    if okP and reflect.isValid(outer) then
        local okA, a = pcall(function() return outer:IsA("/Script/Engine.Actor") end)
        if okA and a then return outer end
    end
    return nil
end
geo.actorOf = actorOf

-- World location {X,Y,Z} of an actor or of a component's owning actor.
function geo.location(obj)
    local actor = actorOf(obj)
    if not actor then return nil end
    local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or v == nil then return nil end
    return { X = v.X, Y = v.Y, Z = v.Z }
end

local pcCache
local function playerController()
    if not reflect.isValid(pcCache) then pcCache = FindFirstOf("PlayerController") end
    return pcCache
end

-- Project a world location to viewport pixels (== game client-area pixels).
-- Returns {x, y, onScreen} or nil when the point is behind the camera.
function geo.project(loc)
    local pc = playerController()
    if not loc or not reflect.isValid(pc) then return nil end
    local out = {}
    local ok, visible = pcall(function()
        return pc:ProjectWorldLocationToScreen({ X = loc.X, Y = loc.Y, Z = loc.Z }, out, false)
    end)
    if not ok then return nil end
    local x, y = out.X, out.Y
    if x == nil and out.ScreenLocation then x, y = out.ScreenLocation.X, out.ScreenLocation.Y end
    if x == nil then return nil end
    -- onScreen only means "in front of the camera"; the CLI checks against the client size.
    return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), inFront = visible and true or false }
end

-- {location, screen} for any object reference.
function geo.locate(obj)
    local loc = geo.location(obj)
    return { location = loc, screen = loc and geo.project(loc) or nil }
end

return geo
