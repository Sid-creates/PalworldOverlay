--[[
  PalworldAssistBridge
  Reads live player position + Relic/effigy state from game memory and writes:
    %LOCALAPPDATA%\PalworldAssist\live.json

  Collected detection:
    - Actor property flags (bPickedInClient / bIsPicked / similar) on loaded relics
    - Disappearance of a nearby previously-seen relic (pickup)
]]

local PLAYER_INTERVAL_MS = 750
local SCAN_INTERVAL_MS = 2000

local lastWarn = 0
local outPath = nil
local dirReady = false
local seenCollected = {}
local previousPresent = {}

local latestPlayer = nil
local latestPlayers = {}
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

local function jsonString(s)
    if s == nil then
        return '""'
    end
    local t = tostring(s)
    t = t:gsub("\\", "\\\\")
    t = t:gsub('"', '\\"')
    t = t:gsub("\n", "\\n")
    t = t:gsub("\r", "\\r")
    t = t:gsub("\t", "\\t")
    return '"' .. t .. '"'
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

    local playersParts = {}
    for i = 1, #latestPlayers do
        local p = latestPlayers[i]
        local possess = "null"
        if p.relicPossessNum ~= nil then
            possess = tostring(p.relicPossessNum)
        end
        playersParts[#playersParts + 1] = string.format(
            '{"id":%s,"name":%s,"x":%s,"y":%s,"z":%s,"local":%s,"relicPossessNum":%s}',
            jsonString(p.id),
            jsonString(p.name),
            jsonNumber(p.x),
            jsonNumber(p.y),
            jsonNumber(p.z),
            p.isLocal and "true" or "false",
            possess
        )
    end

    local playerJson = "null"
    if latestPlayer then
        playerJson = string.format(
            '{"id":%s,"name":%s,"x":%s,"y":%s,"z":%s,"local":%s}',
            jsonString(latestPlayer.id or ""),
            jsonString(latestPlayer.name or ""),
            jsonNumber(latestPlayer.x),
            jsonNumber(latestPlayer.y),
            jsonNumber(latestPlayer.z),
            latestPlayer.isLocal and "true" or "false"
        )
    end

    local possessJson = "null"
    if relicPossessNum ~= nil then
        possessJson = tostring(relicPossessNum)
    end

    local body = string.format(
        '{"version":3,"bridgeRev":"0.3.2","updatedAt":%d,"player":%s,"players":[%s],"playerCount":%d,"relicPossessNum":%s,"present":[%s],"collected":[%s]}',
        os.time(),
        playerJson,
        table.concat(playersParts, ","),
        #latestPlayers,
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

local function isUselessName(name)
    if not name or name == "" then
        return true
    end
    local lower = string.lower(name)
    return lower == "none"
        or lower == "player"
        or lower == "playername"
        or lower == "default"
        or lower:find("^player%s*%d*$") ~= nil
        or lower:find("^userdata:") ~= nil
end

-- IMPORTANT: never call :ToString() / UFunctions on unknown userdata.
-- pcall does NOT catch native EXCEPTION_ACCESS_VIOLATION from UE4SS.
local function asLuaString(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        if isUselessName(value) then
            return nil
        end
        return value
    end
    return nil
end

local function readVec3(loc)
    if not loc then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return loc.X or loc.x, loc.Y or loc.y, loc.Z or loc.z
    end)
    if ok and type(x) == "number" and type(y) == "number" then
        return x, y, z or 0
    end
    return nil
end

local function objectAddress(obj)
    if not obj then
        return nil
    end
    local okValid, valid = pcall(function()
        return obj:IsValid()
    end)
    if not okValid or not valid then
        return nil
    end
    local ok, addr = pcall(function()
        return tostring(obj:GetAddress())
    end)
    if ok and type(addr) == "string" and addr ~= "" then
        return addr
    end
    return nil
end

local function getActorLocation(actor)
    if not actor then
        return nil
    end
    local okValid, valid = pcall(function()
        return actor:IsValid()
    end)
    if not okValid or not valid then
        return nil
    end

    local ok, loc = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    if ok then
        local x, y, z = readVec3(loc)
        if x ~= nil then
            return x, y, z
        end
    end

    ok, loc = pcall(function()
        local root = actor.RootComponent
        if root and root:IsValid() then
            return root.RelativeLocation
        end
        return nil
    end)
    if ok then
        return readVec3(loc)
    end
    return nil
end

-- Safe TArray / FindAllOf iteration: property index / pairs only.
-- Do NOT call :Num() / :GetArrayNum() — those can AV on bad arrays.
local function forEachCollection(arr, callback)
    if arr == nil then
        return
    end

    local okLen, n = pcall(function()
        return #arr
    end)
    if okLen and type(n) == "number" and n > 0 and n < 256 then
        for i = 1, n do
            local okItem, item = pcall(function()
                return arr[i]
            end)
            if okItem and item ~= nil then
                callback(item)
            end
        end
        return
    end

    local okPairs = pcall(function()
        for _, item in pairs(arr) do
            if item ~= nil then
                callback(item)
            end
        end
    end)
    if not okPairs then
        return
    end
end

local function collectOfClass(className, into)
    local ok, list = pcall(function()
        return FindAllOf(className)
    end)
    if not ok or list == nil then
        return
    end
    forEachCollection(list, function(item)
        into[#into + 1] = item
    end)
end

local function guidFieldsToString(guid)
    if guid == nil or type(guid) ~= "userdata" and type(guid) ~= "table" then
        return nil
    end
    -- Property fields only — never guid:ToString() (crashes on FGuid).
    local ok, a, b, c, d = pcall(function()
        return guid.A, guid.B, guid.C, guid.D
    end)
    if not ok then
        return nil
    end
    if type(a) ~= "number" or type(b) ~= "number" then
        return nil
    end
    return string.format(
        "%08X-%08X-%08X-%08X",
        a or 0,
        b or 0,
        c or 0,
        d or 0
    )
end

local function readPlayerId(playerState, character)
    -- Prefer cheap numeric / address ids. Avoid GetPlayerUId() UFunction.
    if playerState then
        local ok, playerId = pcall(function()
            return playerState.PlayerId
        end)
        if ok and type(playerId) == "number" then
            return "pid:" .. tostring(playerId)
        end

        local okUid, uid = pcall(function()
            return playerState.PlayerUId
        end)
        if okUid and uid ~= nil then
            local asGuid = guidFieldsToString(uid)
            if asGuid then
                return asGuid
            end
        end

        local addr = objectAddress(playerState)
        if addr then
            return "state:" .. addr
        end
    end

    local charAddr = objectAddress(character)
    if charAddr then
        return "char:" .. charAddr
    end
    return nil
end

local function tryFStringProperty(obj, propName)
    if not obj then
        return nil
    end
    local ok, value = pcall(function()
        return obj[propName]
    end)
    if not ok or value == nil then
        return nil
    end

    local asStr = asLuaString(value)
    if asStr then
        return asStr
    end

    -- Only call ToString on values that look like FString wrappers.
    -- Skip if A/B/C/D exist (that's an FGuid — ToString AV'd in crash dumps).
    if type(value) == "userdata" or type(value) == "table" then
        local okGuid, maybeA = pcall(function()
            return value.A
        end)
        if okGuid and type(maybeA) == "number" then
            return nil
        end
        local okTs, s = pcall(function()
            if value.ToString == nil then
                return nil
            end
            return value:ToString()
        end)
        if okTs then
            return asLuaString(s)
        end
    end
    return nil
end

local function readPlayerName(character, playerState)
    if playerState then
        local fromState = tryFStringProperty(playerState, "PlayerNamePrivate")
            or tryFStringProperty(playerState, "PlayerName")
            or tryFStringProperty(playerState, "NickName")
            or tryFStringProperty(playerState, "PlayerNameNickName")
        if fromState then
            return fromState
        end
    end

    if character then
        local fromChar = tryFStringProperty(character, "NickName")
        if fromChar then
            return fromChar
        end
        local ok, nick = pcall(function()
            return character.CharacterParameterComponent.IndividualParameter.SaveParameter.NickName
        end)
        if ok and nick ~= nil then
            local asStr = asLuaString(nick)
            if asStr then
                return asStr
            end
            if type(nick) == "userdata" then
                local okGuid, maybeA = pcall(function()
                    return nick.A
                end)
                if not (okGuid and type(maybeA) == "number") then
                    local okTs, s = pcall(function()
                        if nick.ToString == nil then
                            return nil
                        end
                        return nick:ToString()
                    end)
                    if okTs then
                        return asLuaString(s)
                    end
                end
            end
        end
    end
    return nil
end

local function readRelicPossessNumFrom(character, playerState)
    local ok, n = pcall(function()
        if playerState and type(playerState.RelicPossessNum) == "number" then
            return playerState.RelicPossessNum
        end
        if character and type(character.RelicPossessNum) == "number" then
            return character.RelicPossessNum
        end
        if character then
            return character.CharacterParameterComponent.IndividualParameter.SaveParameter.RelicPossessNum
        end
        return nil
    end)
    if ok and type(n) == "number" then
        return n
    end
    return nil
end

local function getPawnFromState(playerState)
    if not playerState then
        return nil
    end
    -- Property reads only — avoid GetPawn() / GetPlayerController() UFunctions.
    local props = { "PawnPrivate", "Pawn" }
    for _, prop in ipairs(props) do
        local ok, pawn = pcall(function()
            return playerState[prop]
        end)
        if ok and pawn then
            local okValid, valid = pcall(function()
                return pawn:IsValid()
            end)
            if okValid and valid then
                return pawn
            end
        end
    end

    local okOwner, owner = pcall(function()
        return playerState.Owner
    end)
    if okOwner and owner then
        local okValid, valid = pcall(function()
            return owner:IsValid()
        end)
        if okValid and valid then
            local okPawn, pawn = pcall(function()
                return owner.Pawn or owner.AcknowledgedPawn
            end)
            if okPawn and pawn then
                local okPv, pv = pcall(function()
                    return pawn:IsValid()
                end)
                if okPv and pv then
                    return pawn
                end
            end
        end
    end
    return nil
end

local function getLocationFromState(playerState, character)
    local pawn = character
    if not pawn then
        pawn = getPawnFromState(playerState)
    end
    if pawn then
        local x, y, z = getActorLocation(pawn)
        if x ~= nil then
            return x, y, z, pawn
        end
    end

    -- Property only — do not call GetCharacterLocation() (UFunction can AV).
    if playerState then
        local ok, loc = pcall(function()
            return playerState.CachedPlayerLocation
        end)
        if ok then
            local x, y, z = readVec3(loc)
            if x ~= nil and not (x == 0 and y == 0 and z == 0) then
                return x, y, z, pawn
            end
        end
    end
    return nil
end

local function isLocalPlayerState(playerState, character)
    if character then
        local ok, controlled = pcall(function()
            return character:IsLocallyControlled()
        end)
        if ok and controlled == true then
            return true
        end
    end

    if playerState then
        local okOwn, isLocal = pcall(function()
            local owner = playerState.Owner
            if not owner then
                return false
            end
            if not owner:IsValid() then
                return false
            end
            if owner.IsLocalPlayerController == nil then
                return false
            end
            return owner:IsLocalPlayerController()
        end)
        if okOwn and isLocal == true then
            return true
        end
    end

    return false
end

local function getLocalPlayerState()
    local controllers = {}
    collectOfClass("PalPlayerController", controllers)
    if #controllers == 0 then
        collectOfClass("PlayerController", controllers)
    end
    for i = 1, #controllers do
        local pc = controllers[i]
        local ok, isLocal = pcall(function()
            return pc and pc:IsValid() and pc:IsLocalPlayerController()
        end)
        if ok and isLocal then
            local okPs, ps = pcall(function()
                return pc.PlayerState
            end)
            if okPs and ps then
                local okValid, valid = pcall(function()
                    return ps:IsValid()
                end)
                if okValid and valid then
                    return ps
                end
            end
        end
    end
    return nil
end

local function gatherPlayerStates()
    local states = {}
    local seen = {}

    local function addState(state)
        local addr = objectAddress(state)
        if not addr or seen[addr] then
            return
        end
        seen[addr] = true
        states[#states + 1] = state
    end

    -- Preferred: GameState.PlayerArray (all connected players).
    local gameStateClasses = {
        "PalGameStateInGame",
        "PalGameState",
        "GameStateBase",
        "GameState",
    }
    for _, className in ipairs(gameStateClasses) do
        local ok, gs = pcall(function()
            return FindFirstOf(className)
        end)
        if ok and gs then
            local okValid, valid = pcall(function()
                return gs:IsValid()
            end)
            if okValid and valid then
                local okArr, arr = pcall(function()
                    return gs.PlayerArray
                end)
                if okArr and arr ~= nil then
                    forEachCollection(arr, addState)
                end
                if #states > 0 then
                    return states
                end
            end
        end
    end

    -- Fallback: FindAllOf player states.
    local found = {}
    collectOfClass("PalPlayerState", found)
    if #found == 0 then
        collectOfClass("PlayerState", found)
    end
    for i = 1, #found do
        addState(found[i])
    end

    return states
end

local function gatherPlayers()
    local players = {}
    local seenIds = {}
    local localState = getLocalPlayerState()
    local localStateAddr = objectAddress(localState)

    local states = gatherPlayerStates()
    local index = 0

    for i = 1, #states do
        local playerState = states[i]
        local character = getPawnFromState(playerState)
        local x, y, z, pawn = getLocationFromState(playerState, character)
        if x ~= nil then
            index = index + 1
            if not character and pawn then
                character = pawn
            end

            local id = readPlayerId(playerState, character) or ("state:" .. tostring(index))
            if not seenIds[id] then
                seenIds[id] = true

                local name = readPlayerName(character, playerState)
                if not name then
                    name = "Player " .. tostring(index)
                end

                local isLocal = false
                if localStateAddr and objectAddress(playerState) == localStateAddr then
                    isLocal = true
                else
                    isLocal = isLocalPlayerState(playerState, character)
                end

                players[#players + 1] = {
                    id = id,
                    name = name,
                    x = x,
                    y = y,
                    z = z or 0,
                    isLocal = isLocal,
                    relicPossessNum = readRelicPossessNumFrom(character, playerState),
                }
            end
        end
    end

    -- Character scan fallback if no PlayerStates yielded positions.
    if #players == 0 then
        local chars = {}
        collectOfClass("PalPlayerCharacter", chars)
        for i = 1, #chars do
            local character = chars[i]
            local x, y, z = getActorLocation(character)
            if x ~= nil then
                local playerState = nil
                pcall(function()
                    playerState = character.PlayerState
                end)
                local id = readPlayerId(playerState, character) or ("char:" .. tostring(i))
                if not seenIds[id] then
                    seenIds[id] = true
                    players[#players + 1] = {
                        id = id,
                        name = readPlayerName(character, playerState) or ("Player " .. tostring(i)),
                        x = x,
                        y = y,
                        z = z or 0,
                        isLocal = isLocalPlayerState(playerState, character),
                        relicPossessNum = readRelicPossessNumFrom(character, playerState),
                    }
                end
            end
        end
    end

    table.sort(players, function(a, b)
        if a.isLocal ~= b.isLocal then
            return a.isLocal
        end
        return tostring(a.name) < tostring(b.name)
    end)

    return players
end

local function pickPrimaryPlayer(players)
    if #players == 0 then
        return nil
    end
    for i = 1, #players do
        if players[i].isLocal then
            return players[i]
        end
    end
    return players[1]
end

local function anyPlayerNear(x, y, maxDist)
    local max2 = maxDist * maxDist
    for i = 1, #latestPlayers do
        local p = latestPlayers[i]
        local dx = p.x - x
        local dy = p.y - y
        if (dx * dx + dy * dy) < max2 then
            return true
        end
    end
    return false
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
    local players = gatherPlayers()
    latestPlayers = players
    latestPlayer = pickPrimaryPlayer(players)

    if latestPlayer and latestPlayer.relicPossessNum ~= nil then
        relicPossessNum = latestPlayer.relicPossessNum
    elseif #players > 0 then
        for i = 1, #players do
            if players[i].relicPossessNum ~= nil then
                relicPossessNum = players[i].relicPossessNum
                break
            end
        end
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

    -- Nearby disappearance ⇒ collected (any nearby player on the server).
    for key, it in pairs(previousPresent) do
        if currentKeys[key] == nil and seenCollected[key] == nil then
            if anyPlayerNear(it.x, it.y, 30000) then
                markCollected(it.x, it.y, it.z)
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
