-- FP2AgentBridge: file-based request/response bridge between agents and Frostpunk 2.
--
-- Bridge dir: mod/FP2AgentBridge/bridge in the repo (see `base` below)
--   request.json   client -> mod  (client creates atomically; mod deletes after reading)
--   response.json  mod -> client  (written via .tmp + rename; client deletes after reading)
--   status.json    heartbeat, rewritten every second
--   bridge.log     errors and lifecycle events
-- One request is in flight at a time; clients serialize with client.lock.

local VERSION = "0.1.0"
local json = require("json")
local commands = require("commands")

-- Hot-reload every module except this file without any keypress (UE4SS's Ctrl+R collides with
-- the game's R = Research hotkey). Returns the module list that was reloaded.
-- UE4SS's require caches outside package.loaded, so load each file directly (dependency order)
-- and seed package.loaded before the next module requires it.
local MODULES = { "json", "reflect", "geo", "fp2_extractors", "extractors", "actions", "commands" }
local function reloadModules()
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)[\\/][^\\/]+$") or "."
    for _, m in ipairs(MODULES) do
        local chunk, err = loadfile(dir .. "\\" .. m .. ".lua")
        if not chunk then error("reload " .. m .. ": " .. tostring(err), 0) end
        package.loaded[m] = chunk(m)
    end
    commands = package.loaded["commands"]
    commands.VERSION = VERSION
    return MODULES
end

commands.VERSION = VERSION

-- Default: <mod dir>\bridge, which the install junction maps into the repo so the CLI finds it
-- without configuration. FP2_BRIDGE_DIR overrides; the directory must already exist
-- (os.execute mkdir would flash a console window over the game).
local function modDir()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.+)[\\/]Scripts[\\/][^\\/]+$")
    return dir or "ue4ss\\Mods\\FP2AgentBridge"
end
local base = os.getenv("FP2_BRIDGE_DIR") or (modDir() .. "\\bridge")

local REQ = base .. "\\request.json"
local RESP = base .. "\\response.json"
local STATUS = base .. "\\status.json"
local LOG = base .. "\\bridge.log"

local state = {
    busy = false,
    started = os.time(),
    handled = 0,
    lastGameThread = 0,
    lastCommand = nil,
}

local function log(msg)
    local f = io.open(LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
        f:close()
    end
    print("[FP2AgentBridge] " .. msg .. "\n")
end

local function writeAtomic(path, text)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then log("write failed " .. tmp .. ": " .. tostring(err)); return false end
    f:write(text)
    f:close()
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then log("rename failed " .. path .. ": " .. tostring(rerr)) end
    return ok
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function respond(id, okFlag, payload, elapsed)
    local env = { id = id, ok = okFlag, elapsedMs = elapsed, bridge = VERSION }
    if okFlag then env.result = payload else env.error = payload end
    local ok, text = pcall(json.encode, env)
    if not ok then
        text = json.encode({ id = id, ok = false, error = "encode failed: " .. tostring(text) })
    end
    writeAtomic(RESP, text)
end

local function handle(raw)
    local okD, req = pcall(json.decode, raw)
    if not okD or type(req) ~= "table" then
        respond(nil, false, "bad request json: " .. tostring(req), 0)
        state.busy = false
        return
    end
    state.lastCommand = req.command
    ExecuteInGameThread(function()
        local t0 = os.clock()
        state.lastGameThread = os.time()
        local ok, result
        if req.command == "bridge.reload" then
            ok, result = pcall(function() return { reloaded = reloadModules() } end)
        else
            ok, result = pcall(commands.dispatch, req.command, req.args or {})
        end
        local elapsed = math.floor((os.clock() - t0) * 1000)
        if not ok then log("command " .. tostring(req.command) .. " failed: " .. tostring(result)) end
        respond(req.id, ok, ok and result or tostring(result), elapsed)
        state.handled = state.handled + 1
        state.busy = false
    end)
end

local lastStatus = 0
LoopAsync(50, function()
    local now = os.time()
    if now ~= lastStatus then
        lastStatus = now
        writeAtomic(STATUS, json.encode({
            bridge = VERSION, pid = nil, time = now, started = state.started,
            busy = state.busy, handled = state.handled,
            lastGameThread = state.lastGameThread, lastCommand = state.lastCommand,
        }))
    end
    if state.busy then return false end
    local raw = readFile(REQ)
    if raw and #raw > 0 then
        os.remove(REQ)
        state.busy = true
        local ok, err = pcall(handle, raw)
        if not ok then
            log("dispatch error: " .. tostring(err))
            respond(nil, false, tostring(err), 0)
            state.busy = false
        end
    end
    return false
end)

-- Clear stale request from a previous game run.
os.remove(REQ)
os.remove(RESP)
log("FP2AgentBridge " .. VERSION .. " loaded; bridge dir " .. base)
