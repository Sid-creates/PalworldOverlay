--[[
  PalworldAssistBridge
  Reads live player position + Relic/effigy state from game memory and writes:
    %LOCALAPPDATA%\PalworldAssist\live.json

  Collected detection:
    - Actor property flags (bPickedInClient / bIsPicked / similar) on loaded relics
    - Disappearance of a nearby previously-seen relic (pickup)
]]

local PLAYER_INTERVAL_MS = 300
local SCAN_INTERVAL_MS = 1500

local lastWarn = 0
local outPath = nil
local dirReady = false
local seenCollected = {}
local previousPresent = {}

local latestPlayer = nil
local latestPresent = {}
local pendingCollected = {}
local relicPossessNum = nil

local PICKED_PROPS = {
    "bPickedInClient",
    "bIsPicked",
    "bPicked",
    "bObtained",
    "bAlreadyPicked",
    "PickedInClient",
}

local RELIC_CLASS_CANDIDATES = {
    "BP_LevelObject_Relic_C",
    "BP_RelicObject_C",
    "PalLevelObjectRelic",
    "PalMapObjectRelicModel",
}

local function log(msg)
    print(string.format("[PalworldAssistBridge] %s", msg))
end

local function resolveOutPath()
    if outPath then
        return outPath
    end
    local localApp = os.getenv("LOCALAPPDATA")
    if localApp and localApp ~= "" then
        outPath = localApp .. "\\PalworldAssist\\live.json"
    else
        outPath = "PalworldAssist_live.json"
    end
    return outPath
end

-- NEVER use os.execute here — on Windows it flashes a console every call.
-- Companion creates %LOCALAPPDATA%\PalworldAssist on startup.
local function canWrite(path)
    local f = io.open(path, "a")
    if not f then
        return false
    end
    f:close()
    return true
end

local function roundKey(x, y, z)
    return string.format(
        "%d:%d:%d",
        math.floor(x / 200 + 0.5),
        math.floor(y / 200 + 0.5),
        math.floor(z / 200 + 0.5)
    )
end

local function jsonNumber(n)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return "0"
    end
    return string.format("%.3f", n)
end

local function flush()
    local path = resolveOutPath()
    if not dirReady then
        if canWrite(path) then
            dirReady = true
        else
            local now = os.time()
            if now - lastWarn > 20 then
                log("cannot write " .. path .. " — start the companion once so it creates the folder")
                lastWarn = now
            end
            return
        end
    end

    local presentParts = {}
    for i = 1, #latestPresent do
        local it = latestPresent[i]
        presentParts[#presentParts + 1] = string.format(
            '{"x":%s,"y":%s,"z":%s,"picked":%s}',
            jsonNumber(it.x),
            jsonNumber(it.y),
            jsonNumber(it.z),
            it.picked and "true" or "false"
        )
    end

    if #pendingCollected > 128 then
        local trimmed = {}
        for i = #pendingCollected - 127, #pendingCollected do
            trimmed[#trimmed + 1] = pendingCollected[i]
        end
        pendingCollected = trimmed
    end

    local collectedParts = {}
    for i = 1, #pendingCollected do
        local it = pendingCollected[i]
        collectedParts[#collectedParts + 1] = string.format(
            '{"x":%s,"y":%s,"z":%s}',
            jsonNumber(it.x),
            jsonNumber(it.y),
            jsonNumber(it.z)
        )
    end

    local playerJson = "null"
    if latestPlayer then
        playerJson = string.format(
            '{"x":%s,"y":%s,"z":%s}',
            jsonNumber(latestPlayer.x),
            jsonNumber(latestPlayer.y),
            jsonNumber(latestPlayer.z)
        )
    end

    local possessJson = "null"
    if relicPossessNum ~= nil then
        possessJson = tostring(relicPossessNum)
    end

    local body = string.format(
        '{"version":2,"updatedAt":%d,"player":%s,"relicPossessNum":%s,"present":[%s],"collected":[%s]}',
        os.time(),
        playerJson,
        possessJson,
        table.concat(presentParts, ","),
        table.concat(collectedParts, ",")
    )

    local ok, err = pcall(function()
        local f = io.open(path, "w")
        if not f then
            error("open failed: " .. path)
        end
        f:write(body)
        f:close()
    end)

    if not ok then
        local now = os.time()
        if now - lastWarn > 15 then
            log("write failed: " .. tostring(err))
            lastWarn = now
        end
    end
end

local function getPlayerCharacter()
    local player = FindFirstOf("PalPlayerCharacter")
    if player and player:IsValid() then
        return player
    end
    return nil
end

local function getPlayerLocation()
    local player = getPlayerCharacter()
    if not player then
        return nil
    end

    local ok, loc = pcall(function()
        return player:K2_GetActorLocation()
    end)
    if ok and loc and loc.X ~= nil then
        return loc.X, loc.Y, loc.Z
    end

    ok, loc = pcall(function()
        return player.RootComponent.RelativeLocation
    end)
    if ok and loc and loc.X ~= nil then
        return loc.X, loc.Y, loc.Z
    end

    return nil
end

local function readRelicPossessNum()
    -- Best-effort: player state / parameter often exposes RelicPossessNum.
    local candidates = {
        function()
            local state = FindFirstOf("PalPlayerState")
            if state and state:IsValid() and state.RelicPossessNum ~= nil then
                return state.RelicPossessNum
            end
            return nil
        end,
        function()
            local player = getPlayerCharacter()
            if not player then
                return nil
            end
            if player.RelicPossessNum ~= nil then
                return player.RelicPossessNum
            end
            local ok, n = pcall(function()
                return player.CharacterParameterComponent.IndividualParameter.SaveParameter.RelicPossessNum
            end)
            if ok then
                return n
            end
            return nil
        end,
    }
    for _, fn in ipairs(candidates) do
        local ok, n = pcall(fn)
        if ok and type(n) == "number" then
            return n
        end
    end
    return nil
end

local function actorLooksLikeRelic(actor)
    if not actor or not actor:IsValid() then
        return false
    end
    local ok, name = pcall(function()
        return actor:GetFullName()
    end)
    if not ok or type(name) ~= "string" then
        return false
    end
    if name:find("Relic", 1, true) then
        return true
    end
    if name:find("Effigy", 1, true) then
        return true
    end
    if name:find("LevelObject_Relic", 1, true) then
        return true
    end
    return false
end

local function getActorLocation(actor)
    local ok, loc = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    if ok and loc and loc.X ~= nil then
        return loc.X, loc.Y, loc.Z
    end
    return nil
end

local function actorIsPicked(actor)
    for _, prop in ipairs(PICKED_PROPS) do
        local ok, val = pcall(function()
            return actor[prop]
        end)
        if ok and val == true then
            return true
        end
    end

    -- Some builds nest the flag under a model / stage object.
    local nested = {
        function()
            return actor.Model.bPickedInClient
        end,
        function()
            return actor.MapObjectModel.bPickedInClient
        end,
        function()
            return actor.Stage.bPickedInClient
        end,
    }
    for _, fn in ipairs(nested) do
        local ok, val = pcall(fn)
        if ok and val == true then
            return true
        end
    end
    return false
end

local function markCollected(x, y, z)
    local key = roundKey(x, y, z)
    if seenCollected[key] then
        return
    end
    seenCollected[key] = true
    pendingCollected[#pendingCollected + 1] = { x = x, y = y, z = z or 0 }
end

local function gatherRelicActors()
    local found = {}
    local seen = {}

    local function addActor(actor)
        if not actor or not actor:IsValid() then
            return
        end
        local ok, addr = pcall(function()
            return tostring(actor:GetAddress())
        end)
        local id = ok and addr or tostring(actor)
        if seen[id] then
            return
        end
        seen[id] = true
        if actorLooksLikeRelic(actor) then
            found[#found + 1] = actor
        end
    end

    for _, className in ipairs(RELIC_CLASS_CANDIDATES) do
        local ok, list = pcall(function()
            return FindAllOf(className)
        end)
        if ok and list ~= nil then
            for _, actor in pairs(list) do
                addActor(actor)
            end
        end
    end

    -- Fallback wide scan if class names shifted this patch.
    if #found == 0 then
        local ok, actors = pcall(function()
            return FindAllOf("Actor")
        end)
        if ok and actors ~= nil then
            for _, actor in pairs(actors) do
                addActor(actor)
            end
        end
    end

    return found
end

local function scanRelics()
    local present = {}
    local actors = gatherRelicActors()

    for _, actor in ipairs(actors) do
        local x, y, z = getActorLocation(actor)
        if x ~= nil then
            local picked = actorIsPicked(actor)
            present[#present + 1] = {
                x = x,
                y = y,
                z = z or 0,
                picked = picked,
            }
            if picked then
                markCollected(x, y, z or 0)
            end
        end
    end

    return present
end

local function tickPlayer()
    local x, y, z = getPlayerLocation()
    if x == nil then
        return
    end
    latestPlayer = { x = x, y = y, z = z or 0 }

    local n = readRelicPossessNum()
    if n ~= nil then
        relicPossessNum = n
    end

    flush()
end

local function tickScan()
    local present = scanRelics()
    latestPresent = present

    local currentKeys = {}
    for i = 1, #present do
        local it = present[i]
        currentKeys[roundKey(it.x, it.y, it.z)] = it
        if it.picked then
            markCollected(it.x, it.y, it.z)
        end
    end

    -- Nearby disappearance ⇒ collected (covers builds without a picked flag).
    for key, it in pairs(previousPresent) do
        if currentKeys[key] == nil and seenCollected[key] == nil then
            local px, py = getPlayerLocation()
            if px ~= nil then
                local dx = px - it.x
                local dy = py - it.y
                if (dx * dx + dy * dy) < (30000 * 30000) then
                    markCollected(it.x, it.y, it.z)
                end
            end
        end
    end

    previousPresent = currentKeys
    flush()
end

log("starting → " .. resolveOutPath() .. " (no console spawn; companion must create the folder)")
flush()

LoopAsync(PLAYER_INTERVAL_MS, function()
    local ok, err = pcall(tickPlayer)
    if not ok then
        local now = os.time()
        if now - lastWarn > 15 then
            log("player tick error: " .. tostring(err))
            lastWarn = now
        end
    end
    return false
end)

LoopAsync(SCAN_INTERVAL_MS, function()
    local ok, err = pcall(tickScan)
    if not ok then
        local now = os.time()
        if now - lastWarn > 15 then
            log("scan tick error: " .. tostring(err))
            lastWarn = now
        end
    end
    return false
end)
