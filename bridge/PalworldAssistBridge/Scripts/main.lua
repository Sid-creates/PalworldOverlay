--[[
  PalworldAssistBridge
  Reads live player position + Relic/effigy state from game memory and writes:
    %LOCALAPPDATA%\PalworldAssist\live.json

  Collected detection:
    - Actor property flags (bPickedInClient / bIsPicked / similar) on loaded relics
    - Sticky watch + disappearance of a nearby previously-seen relic (pickup)
    - RelicPossessNum increase near a watched relic

  Perf (keep in sync with companion/shared/relicTracking.js):
    - Class-name FindAllOf only (never FindAllOf("Actor"))
    - Adaptive scan cadence (hot near watched relic, cold otherwise)
    - Present list sorted by player distance + capped
    - Skip unchanged live.json bodies (ignore updatedAt)
]]

local BRIDGE_REV = "0.4.1"
local TICK_MS = 500
local PLAYER_EVERY_TICKS = 4 -- 2s
local SCAN_HOT_TICKS = 3 -- 1.5s while standing on a watched relic
local SCAN_COLD_TICKS = 10 -- 5s otherwise
local PRESENT_NEAR_CM = 120000
local STICKY_DROP_CM = 180000
local DISAPPEAR_CONFIRM_CM = 45000
local PRESENT_MAX = 48
local WATCH_MAX = 256
local POSSESS_PICK_CM = 25000
local HOT_NEAR_CM = 15000

local lastFlushBody = nil
local tickCount = 0
local nextScanTick = 0

local lastWarn = 0
local outPath = nil
local dirReady = false
local seenCollected = {}
local watchedRelics = {}

local latestPlayer = nil
local latestPlayers = {}
local latestPresent = {}
local pendingCollected = {}
local relicPossessNum = nil
local previousPossessNum = nil
local possessBumpPending = false

local PICKED_PROPS = {
    "bPickedInClient",
    "bIsPicked",
    "bPicked",
    "bObtained",
    "bAlreadyPicked",
    "PickedInClient",
    "bCollected",
    "bObtainedInClient",
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

    local content = string.format(
        '{"version":3,"bridgeRev":"%s","player":%s,"players":[%s],"playerCount":%d,"relicPossessNum":%s,"present":[%s],"collected":[%s]}',
        BRIDGE_REV,
        playerJson,
        table.concat(playersParts, ","),
        #latestPlayers,
        possessJson,
        table.concat(presentParts, ","),
        table.concat(collectedParts, ",")
    )

    local ok, err = pcall(function()
        -- Skip identical writes to cut disk churn (ignore updatedAt).
        if content == lastFlushBody then
            return
        end
        local body = string.format(
            '{"version":3,"bridgeRev":"%s","updatedAt":%d,"player":%s,"players":[%s],"playerCount":%d,"relicPossessNum":%s,"present":[%s],"collected":[%s]}',
            BRIDGE_REV,
            os.time(),
            playerJson,
            table.concat(playersParts, ","),
            #latestPlayers,
            possessJson,
            table.concat(presentParts, ","),
            table.concat(collectedParts, ",")
        )
        local f = io.open(path, "w")
        if not f then
            error("open failed: " .. path)
        end
        f:write(body)
        f:close()
        lastFlushBody = content
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
        function()
            return actor.Model.bIsPicked
        end,
        function()
            return actor.MapObjectModel.bIsPicked
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

local function isValidWorldLocation(x, y, z)
    if type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    z = z or 0
    if type(z) ~= "number" then
        return false
    end
    if math.abs(x) < 50 and math.abs(y) < 50 then
        return false
    end
    return true
end

local function markCollected(x, y, z)
    if not isValidWorldLocation(x, y, z) then
        return
    end
    local key = roundKey(x, y, z)
    if seenCollected[key] then
        return
    end
    seenCollected[key] = true
    pendingCollected[#pendingCollected + 1] = { x = x, y = y, z = z or 0 }
end

local function minDist2ToPlayers(x, y)
    local best = nil
    for i = 1, #latestPlayers do
        local p = latestPlayers[i]
        local dx = p.x - x
        local dy = p.y - y
        local d2 = dx * dx + dy * dy
        if best == nil or d2 < best then
            best = d2
        end
    end
    return best
end

local function gatherRelicActors()
    local found = {}
    local seen = {}

    local function addActor(actor)
        if not actor then
            return
        end
        local okValid, valid = pcall(function()
            return actor:IsValid()
        end)
        if not okValid or not valid then
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

    -- Class-name scans only. Never FindAllOf("Actor") — that freezes weaker PCs.
    for _, className in ipairs(RELIC_CLASS_CANDIDATES) do
        local ok, list = pcall(function()
            return FindAllOf(className)
        end)
        if ok and list ~= nil then
            forEachCollection(list, addActor)
        end
    end

    return found
end

local function sampleRelics()
    local samples = {}
    local actors = gatherRelicActors()

    for _, actor in ipairs(actors) do
        local x, y, z = getActorLocation(actor)
        if isValidWorldLocation(x, y, z) then
            samples[#samples + 1] = {
                x = x,
                y = y,
                z = z or 0,
                picked = actorIsPicked(actor),
            }
        end
    end

    return samples
end

local function updateWatched(samples)
    local near2 = PRESENT_NEAR_CM * PRESENT_NEAR_CM
    local drop2 = STICKY_DROP_CM * STICKY_DROP_CM

    for i = 1, #samples do
        local s = samples[i]
        local d2 = minDist2ToPlayers(s.x, s.y)
        if s.picked or d2 == nil or d2 <= near2 then
            local key = roundKey(s.x, s.y, s.z)
            watchedRelics[key] = { x = s.x, y = s.y, z = s.z }
        end
    end

    for key, it in pairs(watchedRelics) do
        local d2 = minDist2ToPlayers(it.x, it.y)
        if d2 ~= nil and d2 > drop2 then
            watchedRelics[key] = nil
        end
    end

    local keys = {}
    for key, _ in pairs(watchedRelics) do
        keys[#keys + 1] = key
    end
    if #keys > WATCH_MAX then
        table.sort(keys, function(a, b)
            local da = minDist2ToPlayers(watchedRelics[a].x, watchedRelics[a].y) or 0
            local db = minDist2ToPlayers(watchedRelics[b].x, watchedRelics[b].y) or 0
            return da > db
        end)
        for i = 1, #keys - WATCH_MAX do
            watchedRelics[keys[i]] = nil
        end
    end
end

local function detectDisappeared(samples)
    local currentKeys = {}
    for i = 1, #samples do
        local s = samples[i]
        currentKeys[roundKey(s.x, s.y, s.z)] = true
    end

    local confirm2 = DISAPPEAR_CONFIRM_CM * DISAPPEAR_CONFIRM_CM
    for key, it in pairs(watchedRelics) do
        if currentKeys[key] == nil and seenCollected[key] == nil then
            local d2 = minDist2ToPlayers(it.x, it.y)
            if d2 ~= nil and d2 <= confirm2 then
                markCollected(it.x, it.y, it.z)
            end
        end
    end
end

local function selectPresent(samples)
    local near2 = PRESENT_NEAR_CM * PRESENT_NEAR_CM
    local noPlayers = #latestPlayers == 0
    local scored = {}

    for i = 1, #samples do
        local s = samples[i]
        local d2 = minDist2ToPlayers(s.x, s.y)
        if s.picked or noPlayers or d2 == nil or d2 <= near2 then
            scored[#scored + 1] = {
                x = s.x,
                y = s.y,
                z = s.z,
                picked = s.picked,
                dist2 = s.picked and -1 or (d2 or 0),
            }
        end
    end

    table.sort(scored, function(a, b)
        return a.dist2 < b.dist2
    end)

    local present = {}
    local seen = {}
    for i = 1, #scored do
        local s = scored[i]
        local key = roundKey(s.x, s.y, s.z)
        if not seen[key] then
            seen[key] = true
            present[#present + 1] = {
                x = s.x,
                y = s.y,
                z = s.z,
                picked = s.picked,
            }
            if s.picked then
                markCollected(s.x, s.y, s.z)
            end
            if #present >= PRESENT_MAX then
                break
            end
        end
    end
    return present
end

local function playerStandingOnWatched()
    local hot2 = HOT_NEAR_CM * HOT_NEAR_CM
    for key, it in pairs(watchedRelics) do
        if seenCollected[key] == nil then
            local d2 = minDist2ToPlayers(it.x, it.y)
            if d2 ~= nil and d2 <= hot2 then
                return true
            end
        end
    end
    return false
end

local function markNearestWatchedForPossessBump()
    if not possessBumpPending then
        return false
    end
    if previousPossessNum == nil or relicPossessNum == nil then
        return false
    end
    if relicPossessNum <= previousPossessNum then
        possessBumpPending = false
        return false
    end

    local anchor = latestPlayer
    if not anchor then
        for i = 1, #latestPlayers do
            if latestPlayers[i].isLocal then
                anchor = latestPlayers[i]
                break
            end
        end
        anchor = anchor or latestPlayers[1]
    end
    if not anchor then
        return false
    end

    local max2 = POSSESS_PICK_CM * POSSESS_PICK_CM
    local best = nil
    local best2 = max2
    for key, it in pairs(watchedRelics) do
        if seenCollected[key] == nil then
            local dx = anchor.x - it.x
            local dy = anchor.y - it.y
            local d2 = dx * dx + dy * dy
            if d2 <= best2 then
                best2 = d2
                best = it
            end
        end
    end
    if best then
        markCollected(best.x, best.y, best.z)
        possessBumpPending = false
        return true
    end
    return false
end

local function tickPlayer()
    local players = gatherPlayers()
    latestPlayers = players
    latestPlayer = pickPrimaryPlayer(players)

    local possess = nil
    if latestPlayer and latestPlayer.relicPossessNum ~= nil then
        possess = latestPlayer.relicPossessNum
    elseif #players > 0 then
        for i = 1, #players do
            if players[i].relicPossessNum ~= nil then
                possess = players[i].relicPossessNum
                break
            end
        end
    end

    if possess ~= nil then
        if relicPossessNum ~= nil and possess > relicPossessNum then
            possessBumpPending = true
        end
        previousPossessNum = relicPossessNum
        relicPossessNum = possess
        markNearestWatchedForPossessBump()
    end

    flush()
end

local function tickScan()
    local samples = sampleRelics()
    updateWatched(samples)
    detectDisappeared(samples)
    latestPresent = selectPresent(samples)
    markNearestWatchedForPossessBump()
    flush()
end

log("starting → " .. resolveOutPath() .. " (no console spawn; companion must create the folder)")
flush()

LoopAsync(TICK_MS, function()
    tickCount = tickCount + 1

    if tickCount % PLAYER_EVERY_TICKS == 0 then
        local ok, err = pcall(tickPlayer)
        if not ok then
            local now = os.time()
            if now - lastWarn > 15 then
                log("player tick error: " .. tostring(err))
                lastWarn = now
            end
        end
    end

    if tickCount >= nextScanTick then
        local ok, err = pcall(tickScan)
        if not ok then
            local now = os.time()
            if now - lastWarn > 15 then
                log("scan tick error: " .. tostring(err))
                lastWarn = now
            end
        end
        local cadence = playerStandingOnWatched() and SCAN_HOT_TICKS or SCAN_COLD_TICKS
        nextScanTick = tickCount + cadence
    end

    return false
end)
