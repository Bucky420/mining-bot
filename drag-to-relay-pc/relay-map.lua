local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local JOB_PROTOCOL = NETWORK_ID .. "/mining/v1"

local function openModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            return true
        end
    end
    return false
end

if not openModem() then error("Relay map requires a modem", 0) end

local controllerId, controllerBootId, registered
local farmMaps, snapshots, deltas, turtles = {}, {}, {}, {}
local playerPosition
local center = { x = 0, z = 0 }
local centerInitialized = false
local zoom, followPlayer = 1, true
local status = "Finding controller"
local viewHeading = "north"
local previousGpsPosition
local playerHeadingAt
local playerDetector = peripheral.find("playerDetector") or peripheral.find("player_detector")

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function viewDelta(dx, dz)
    if viewHeading == "east" then return dz, -dx end
    if viewHeading == "south" then return -dx, -dz end
    if viewHeading == "west" then return -dz, dx end
    return dx, dz
end

local function worldDelta(screenX, screenY)
    if viewHeading == "east" then return -screenY, screenX end
    if viewHeading == "south" then return -screenX, -screenY end
    if viewHeading == "west" then return screenY, -screenX end
    return screenX, screenY
end

local function updatePlayerGps(x, y, z)
    local now = os.epoch("utc")
    if previousGpsPosition and (not playerHeadingAt or now - playerHeadingAt > 1500) then
        local dx, dz = x - previousGpsPosition.x, z - previousGpsPosition.z
        if math.abs(dx) >= 0.5 or math.abs(dz) >= 0.5 then
            if math.abs(dx) >= math.abs(dz) then viewHeading = dx >= 0 and "east" or "west"
            else viewHeading = dz >= 0 and "south" or "north" end
        end
    end
    previousGpsPosition = { x = x, z = z }
    playerPosition = { x = x, y = y, z = z }
    centerInitialized = true
end

local function headingFromYaw(yaw)
    yaw = yaw % 360
    if yaw < 45 or yaw >= 315 then return "south" end
    if yaw < 135 then return "west" end
    if yaw < 225 then return "north" end
    return "east"
end

local function pollPlayerHeading()
    if not playerDetector then
        playerDetector = peripheral.find("playerDetector") or peripheral.find("player_detector")
    end
    if not playerDetector then return false end
    local configured = settings.get("bucky.player")
    local names
    if type(configured) == "string" and configured ~= "" then
        names = { configured }
    else
        local ok, online = pcall(playerDetector.getOnlinePlayers)
        if not ok or type(online) ~= "table" then return false end
        names = online
    end
    local selected, selectedDistance
    for _, name in ipairs(names) do
        local ok, position = pcall(playerDetector.getPlayerPos, name)
        if ok and type(position) == "table" and finiteNumber(position.yaw) then
            local distance = 0
            if playerPosition and finiteNumber(position.x) and finiteNumber(position.z) then
                distance = (position.x - playerPosition.x) ^ 2 + (position.z - playerPosition.z) ^ 2
            elseif #names > 1 then
                distance = math.huge
            end
            if not selectedDistance or distance < selectedDistance then
                selected, selectedDistance = position, distance
            end
        end
    end
    if not selected then return false end
    viewHeading = headingFromYaw(selected.yaw)
    playerHeadingAt = os.epoch("utc")
    return true
end

local function applyControllerPlayer(player)
    if player == false then
        playerHeadingAt = nil
        return false
    end
    if type(player) ~= "table" or not finiteNumber(player.x) or not finiteNumber(player.y)
        or not finiteNumber(player.z) or not finiteNumber(player.yaw) then return false end
    playerPosition = { x = player.x, y = player.y, z = player.z }
    previousGpsPosition = { x = player.x, z = player.z }
    viewHeading = headingFromYaw(player.yaw)
    playerHeadingAt = os.epoch("utc")
    centerInitialized = true
    status = "Controller yaw"
    return true
end

local function validCell(cell)
    return type(cell) == "table" and finiteNumber(cell.x) and finiteNumber(cell.y)
        and finiteNumber(cell.z) and cell.x % 1 == 0 and cell.y % 1 == 0
        and cell.z % 1 == 0 and type(cell.name) == "string" and #cell.name <= 128
end

local function copyCell(cell)
    if not validCell(cell) then return nil end
    return {
        x = cell.x, y = cell.y, z = cell.z, name = cell.name,
        class = type(cell.class) == "string" and cell.class:sub(1, 128) or nil,
        occupant = type(cell.occupant) == "string" and cell.occupant:sub(1, 128) or nil,
    }
end

local function copyMetadata(metadata)
    metadata = type(metadata) == "table" and metadata or {}
    local result = {
        phase = type(metadata.phase) == "string" and metadata.phase or nil,
        radius = finiteNumber(metadata.radius) and metadata.radius or nil,
        knownColumns = finiteNumber(metadata.knownColumns) and metadata.knownColumns or nil,
    }
    if type(metadata.center) == "table" and finiteNumber(metadata.center.x)
        and finiteNumber(metadata.center.y) and finiteNumber(metadata.center.z) then
        result.center = {
            x = metadata.center.x, y = metadata.center.y, z = metadata.center.z,
        }
    end
    return result
end

local function copyTurtles(source)
    local result, count = {}, 0
    for id, turtleInfo in pairs(type(source) == "table" and source or {}) do
        if count >= 128 then break end
        if type(turtleInfo) == "table" and type(turtleInfo.position) == "table"
            and finiteNumber(turtleInfo.position.x) and finiteNumber(turtleInfo.position.y)
            and finiteNumber(turtleInfo.position.z) then
            local turtleId = turtleInfo.id or id
            local validId = finiteNumber(turtleId)
                or type(turtleId) == "string" and #turtleId <= 32
            local headings = { north = true, east = true, south = true, west = true }
            if validId then result[turtleId] = {
                id = turtleId,
                name = type(turtleInfo.name) == "string" and turtleInfo.name:sub(1, 32) or nil,
                heading = headings[turtleInfo.heading] and turtleInfo.heading or nil,
                lastSeen = finiteNumber(turtleInfo.lastSeen) and turtleInfo.lastSeen or nil,
                online = type(turtleInfo.online) == "boolean" and turtleInfo.online or nil,
                release = type(turtleInfo.release) == "string" and turtleInfo.release:sub(1, 128) or nil,
                position = {
                    x = turtleInfo.position.x, y = turtleInfo.position.y, z = turtleInfo.position.z,
                },
            }
                count = count + 1
            end
        end
    end
    return result
end

local function prunePending(collection, maximum)
    local now, count, oldestKey, oldestAt = os.epoch("utc"), 0
    for key, pending in pairs(collection) do
        local createdAt = pending.createdAt or now
        if now - createdAt > 30000 then
            collection[key] = nil
        else
            count = count + 1
            if not oldestAt or createdAt < oldestAt then
                oldestKey, oldestAt = key, createdAt
            end
        end
    end
    if count >= maximum and oldestKey then collection[oldestKey] = nil end
end

local function cellCount(exceptKey)
    local count = 0
    for farmKey, farmMap in pairs(farmMaps) do
        if farmKey ~= exceptKey then
            for _ in pairs(farmMap.data and farmMap.data.cells or {}) do count = count + 1 end
        end
    end
    return count
end

local function terrainColor(cell)
    if cell.occupant then
        if cell.occupant:find("leaves", 1, true) or cell.occupant:find("log", 1, true) then
            return colors.green
        end
        return colors.lime
    end
    local styles = {
        water = colors.blue, grass = colors.green,
        farmland = colors.brown, dirt = colors.orange,
        sand = colors.yellow, stone = colors.lightGray,
        tree_log = colors.brown, tree_leaves = colors.lime,
        fence = colors.gray, hard = colors.gray, unknown = colors.gray,
    }
    return styles[cell.class] or colors.lightGray
end

local markerPriority = {
    [colors.cyan] = 3,
    [colors.orange] = 2,
    [colors.red] = 1,
}

local function encodeTexel(pixels)
    local counts, firstSeen = {}, {}
    for index, color in ipairs(pixels) do
        counts[color] = (counts[color] or 0) + 1
        firstSeen[color] = firstSeen[color] or index
    end
    local background
    for color, count in pairs(counts) do
        if not background or count > counts[background]
            or count == counts[background] and firstSeen[color] < firstSeen[background] then
            background = color
        end
    end
    local foreground
    for color in pairs(counts) do
        if color ~= background and markerPriority[color]
            and (not foreground or (markerPriority[color] or 0) > (markerPriority[foreground] or 0)) then
            foreground = color
        end
    end
    if not foreground then
        for color, count in pairs(counts) do
            if color ~= background and (not foreground or count > counts[foreground]
                or count == counts[foreground] and firstSeen[color] < firstSeen[foreground]) then
                foreground = color
            end
        end
    end
    if not foreground then
        local blit = colors.toBlit(background)
        return " ", blit, blit
    end
    local active = {}
    for index, color in ipairs(pixels) do active[index] = color == foreground end
    local sixth = active[6]
    local character = 128
    for index = 1, 5 do
        if active[index] ~= sixth then character = character + 2 ^ (index - 1) end
    end
    if sixth then foreground, background = background, foreground end
    return string.char(character), colors.toBlit(foreground), colors.toBlit(background)
end

local function renderCanvas(canvas, width, height)
    local characterRows = math.floor(height / 3)
    for row = 1, characterRows do
        local characters, foreground, background = {}, {}, {}
        for column = 1, math.floor(width / 2) do
            local x, y = column * 2 - 1, row * 3 - 2
            local character, front, back = encodeTexel({
                canvas[y][x], canvas[y][x + 1],
                canvas[y + 1][x], canvas[y + 1][x + 1],
                canvas[y + 2][x], canvas[y + 2][x + 1],
            })
            characters[column], foreground[column], background[column] = character, front, back
        end
        term.setCursorPos(1, row)
        term.blit(table.concat(characters), table.concat(foreground), table.concat(background))
    end
end

local function chooseCenter()
    if followPlayer and playerPosition then
        center.x, center.z = playerPosition.x, playerPosition.z
        centerInitialized = true
        return
    end
    if centerInitialized then return end
    for _, farmMap in pairs(farmMaps) do
        local farmCenter = farmMap.data and farmMap.data.center
        if farmCenter then
            center.x, center.z = farmCenter.x, farmCenter.z
            centerInitialized = true
            return
        end
    end
    for _, turtleInfo in pairs(turtles) do
        if turtleInfo.position then
            center.x, center.z = turtleInfo.position.x, turtleInfo.position.z
            centerInitialized = true
            return
        end
    end
end

local function render()
    local width, height = term.getSize()
    local pixelWidth, pixelHeight = width * 2, (height - 1) * 3
    local canvas = {}
    for y = 1, pixelHeight do
        canvas[y] = {}
        for x = 1, pixelWidth do canvas[y][x] = colors.black end
    end
    local function drawPixel(x, y, color)
        if x >= 1 and x <= pixelWidth and y >= 1 and y <= pixelHeight then
            canvas[y][x] = color
        end
    end
    chooseCenter()
    for _, farmMap in pairs(farmMaps) do
        for _, cell in pairs(farmMap.data and farmMap.data.cells or {}) do
            local viewX, viewY = viewDelta(cell.x - center.x, cell.z - center.z)
            local x = math.floor(viewX / zoom + pixelWidth / 2 + 0.5)
            local y = math.floor(viewY / zoom + pixelHeight / 2 + 0.5)
            if x >= 1 and x <= pixelWidth and y >= 1 and y <= pixelHeight then
                drawPixel(x, y, terrainColor(cell))
            end
        end
    end
    local nearestName, nearestDistance
    for _, turtleInfo in pairs(turtles) do
        local position = turtleInfo.position
        if position then
            local distance = math.floor(math.sqrt(
                (position.x - center.x) ^ 2 + (position.z - center.z) ^ 2
            ) + 0.5)
            if not nearestDistance or distance < nearestDistance then
                nearestName, nearestDistance = turtleInfo.name or ("T" .. tostring(turtleInfo.id)), distance
            end
            local viewX, viewY = viewDelta(position.x - center.x, position.z - center.z)
            local rawX = math.floor(viewX / zoom + pixelWidth / 2 + 0.5)
            local rawY = math.floor(viewY / zoom + pixelHeight / 2 + 0.5)
            local onScreen = rawX >= 1 and rawX <= pixelWidth and rawY >= 1 and rawY <= pixelHeight
            local x = math.max(1, math.min(pixelWidth, rawX))
            local y = math.max(1, math.min(pixelHeight, rawY))
            local stale = turtleInfo.lastSeen and os.epoch("utc") - turtleInfo.lastSeen > 60000
            drawPixel(x, y, stale and colors.lightGray or onScreen and colors.orange or colors.red)
        end
    end
    if playerPosition then
        local viewX, viewY = viewDelta(playerPosition.x - center.x, playerPosition.z - center.z)
        local x = math.floor(viewX / zoom + pixelWidth / 2 + 0.5)
        local y = math.floor(viewY / zoom + pixelHeight / 2 + 0.5)
        if x >= 1 and x <= pixelWidth and y >= 1 and y <= pixelHeight then
            drawPixel(x, y, colors.cyan)
        end
    end
    renderCanvas(canvas, pixelWidth, pixelHeight)
    local mode = followPlayer and (playerPosition and "GPS" or "AUTO") or "PAN"
    local footer = ("%s z%d UP:%s %d,%d"):format(
        mode, zoom, viewHeading:sub(1, 1):upper(),
        math.floor(center.x), math.floor(center.z)
    )
    if nearestName then footer = footer .. (" %s:%d"):format(nearestName, nearestDistance) end
    if #footer < width then footer = footer .. " " .. status end
    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write(footer:sub(1, width))
end

local function requestSnapshot(farmKey)
    if not registered or type(farmKey) ~= "string" then return end
    for key, pending in pairs(deltas) do
        if pending.farmKey == farmKey then deltas[key] = nil end
    end
    rednet.send(controllerId, {
        type = "FARM_MAP_RESYNC_REQUEST", source = os.getComputerID(),
        controllerBootId = controllerBootId, farmKey = farmKey,
        haveRevision = farmMaps[farmKey] and farmMaps[farmKey].revision or 0,
    }, JOB_PROTOCOL)
end

local function applyIndex(index)
    local indexed = {}
    for _, entry in ipairs(type(index) == "table" and index or {}) do
        if type(entry) == "table" and type(entry.farmKey) == "string" then
            indexed[entry.farmKey] = true
            if not farmMaps[entry.farmKey]
                or tonumber(farmMaps[entry.farmKey].revision) ~= tonumber(entry.revision) then
                requestSnapshot(entry.farmKey)
            end
        end
    end
    for farmKey in pairs(farmMaps) do if not indexed[farmKey] then farmMaps[farmKey] = nil end end
    for farmKey in pairs(snapshots) do if not indexed[farmKey] then snapshots[farmKey] = nil end end
end

local function finishSnapshot(message)
    local pending = snapshots[message.farmKey]
    if not pending or pending.id ~= message.snapshotId then return end
    local cells, count = {}, 0
    for index = 1, pending.chunkCount do
        if not pending.chunks[index] then
            snapshots[message.farmKey] = nil
            requestSnapshot(message.farmKey)
            return
        end
        for _, cell in ipairs(pending.chunks[index]) do
            local key = ("%d:%d"):format(cell.x, cell.z)
            if not cells[key] then count = count + 1 end
            cells[key] = cell
        end
    end
    if message.mapRevision ~= pending.revision or count ~= pending.cellCount
        or cellCount(message.farmKey) + count > 8192 then
        snapshots[message.farmKey] = nil
        status = "Map snapshot rejected"
        return
    end
    pending.metadata.cells = cells
    farmMaps[message.farmKey] = {
        revision = pending.revision, data = pending.metadata, syncedAt = os.epoch("utc"),
    }
    snapshots[message.farmKey] = nil
    status = "Map synced"
end

local function applyDelta(message)
    local current = farmMaps[message.farmKey]
    local revision, baseRevision = tonumber(message.mapRevision), tonumber(message.baseRevision)
    if not current then requestSnapshot(message.farmKey) return end
    if not revision or revision <= (tonumber(current.revision) or 0) then return end
    if baseRevision ~= tonumber(current.revision) then requestSnapshot(message.farmKey) return end
    if type(message.chunkCount) ~= "number" or message.chunkCount < 1 or message.chunkCount > 4
        or type(message.chunkIndex) ~= "number" or message.chunkIndex < 1
        or message.chunkIndex > message.chunkCount or type(message.cells) ~= "table"
        or #message.cells > 32 then return end
    prunePending(deltas, 16)
    local key = message.farmKey .. ":" .. tostring(revision)
    local pending = deltas[key] or {
        farmKey = message.farmKey, revision = revision, baseRevision = baseRevision,
        chunkCount = message.chunkCount, chunks = {}, metadata = copyMetadata(message.metadata),
        createdAt = os.epoch("utc"),
    }
    if pending.chunkCount ~= message.chunkCount then requestSnapshot(message.farmKey) return end
    pending.chunks[message.chunkIndex] = {}
    for _, cell in ipairs(message.cells) do
        local copied = copyCell(cell)
        if copied then pending.chunks[message.chunkIndex][#pending.chunks[message.chunkIndex] + 1] = copied end
    end
    deltas[key] = pending
    for index = 1, pending.chunkCount do if not pending.chunks[index] then return end end
    current.data.cells = current.data.cells or {}
    local merged, additions = {}, 0
    for index = 1, pending.chunkCount do
        for _, cell in ipairs(pending.chunks[index]) do
            local cellKey = ("%d:%d"):format(cell.x, cell.z)
            if not current.data.cells[cellKey] and not merged[cellKey] then additions = additions + 1 end
            merged[cellKey] = cell
        end
    end
    if cellCount() + additions > 8192 then requestSnapshot(message.farmKey) return end
    for cellKey, cell in pairs(merged) do current.data.cells[cellKey] = cell end
    for field, value in pairs(pending.metadata) do current.data[field] = value end
    current.revision = revision
    deltas[key] = nil
    status = "Map r" .. tostring(revision)
end

local function handleController(sender, message)
    if type(message) ~= "table" then return end
    if message.type == "CONTROLLER_HELLO" and message.controllerId == sender
        and (not controllerId or controllerId == sender) then
        local changed = controllerBootId ~= message.bootId
        controllerId, controllerBootId = sender, message.bootId
        if changed then farmMaps, snapshots, deltas, registered = {}, {}, {}, false end
        if type(message.turtleStates) == "table" then turtles = copyTurtles(message.turtleStates) end
        if message.player ~= nil then applyControllerPlayer(message.player) end
        if not registered then
            rednet.send(sender, {
                type = "RELAY_HELLO", source = os.getComputerID(), controllerBootId = controllerBootId,
            }, JOB_PROTOCOL)
        else
            applyIndex(message.farmMapKeys)
        end
    elseif message.type == "RELAY_ACK" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        registered = true
        if type(message.turtleStates) == "table" then turtles = copyTurtles(message.turtleStates) end
        if message.player ~= nil then applyControllerPlayer(message.player) end
        applyIndex(message.farmMapKeys)
    elseif message.type == "PLAYER_UPDATE" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        applyControllerPlayer(message.player)
    elseif message.type == "TURTLE_UPDATE" and sender == controllerId
        and message.controllerBootId == controllerBootId and type(message.turtle) == "table"
        and message.turtle.id then
        local copied = copyTurtles({ [message.turtle.id] = message.turtle })
        if copied[message.turtle.id] then turtles[message.turtle.id] = copied[message.turtle.id] end
    elseif message.type == "FARM_MAP_SNAPSHOT_BEGIN" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        local count = tonumber(message.cellCount)
        if type(message.farmKey) == "string" and type(message.snapshotId) == "string"
            and type(message.mapRevision) == "number" and count and count >= 0 and count <= 4096
            and type(message.chunkCount) == "number" and message.chunkCount >= 1
            and message.chunkCount <= 128 and message.chunkCount == math.max(1, math.ceil(count / 32)) then
            prunePending(snapshots, 4)
            snapshots[message.farmKey] = {
                id = message.snapshotId, revision = message.mapRevision,
                chunkCount = message.chunkCount, cellCount = count, chunks = {},
                metadata = copyMetadata(message.metadata), createdAt = os.epoch("utc"),
            }
        end
    elseif message.type == "FARM_MAP_SNAPSHOT_CHUNK" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        local pending = snapshots[message.farmKey]
        if pending and pending.id == message.snapshotId and message.chunkCount == pending.chunkCount
            and type(message.chunkIndex) == "number" and message.chunkIndex >= 1
            and message.chunkIndex <= pending.chunkCount and type(message.cells) == "table"
            and #message.cells <= 32 then
            local chunk = {}
            for _, cell in ipairs(message.cells) do
                local copied = copyCell(cell)
                if copied then chunk[#chunk + 1] = copied end
            end
            pending.chunks[message.chunkIndex] = chunk
        end
    elseif message.type == "FARM_MAP_SNAPSHOT_END" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        finishSnapshot(message)
    elseif message.type == "FARM_MAP_DELTA" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        applyDelta(message)
    end
end

rednet.broadcast({ type = "CONTROLLER_QUERY", source = os.getComputerID() }, JOB_PROTOCOL)
local gpsTimer, queryTimer = os.startTimer(0.1), os.startTimer(10)
render()

while true do
    local event, first, second, third = os.pullEvent()
    if event == "rednet_message" and third == JOB_PROTOCOL then
        handleController(first, second)
    elseif event == "timer" and first == gpsTimer then
        local now = os.epoch("utc")
        for farmKey, pending in pairs(snapshots) do
            if now - pending.createdAt > 30000 then snapshots[farmKey] = nil requestSnapshot(farmKey) end
        end
        for key, pending in pairs(deltas) do
            if now - pending.createdAt > 30000 then deltas[key] = nil requestSnapshot(pending.farmKey) end
        end
        local x, y, z = gps.locate(0.2, false)
        if x then
            updatePlayerGps(x, y, z)
            local headingFresh = playerHeadingAt and os.epoch("utc") - playerHeadingAt <= 1500
            status = headingFresh and "GPS + yaw" or "GPS locked"
        else
            status = "GPS unavailable"
        end
        if pollPlayerHeading() then status = x and "GPS + yaw" or "Yaw detected" end
        gpsTimer = os.startTimer(0.5)
    elseif event == "timer" and first == queryTimer then
        rednet.broadcast({ type = "CONTROLLER_QUERY", source = os.getComputerID() }, JOB_PROTOCOL)
        queryTimer = os.startTimer(10)
    elseif event == "term_resize" then
        -- Redrawn below.
    elseif event == "key" and first == keys.left then
        local dx, dz = worldDelta(-zoom * 2, 0)
        followPlayer, centerInitialized, center.x, center.z = false, true, center.x + dx, center.z + dz
    elseif event == "key" and first == keys.right then
        local dx, dz = worldDelta(zoom * 2, 0)
        followPlayer, centerInitialized, center.x, center.z = false, true, center.x + dx, center.z + dz
    elseif event == "key" and first == keys.up then
        local dx, dz = worldDelta(0, -zoom * 2)
        followPlayer, centerInitialized, center.x, center.z = false, true, center.x + dx, center.z + dz
    elseif event == "key" and first == keys.down then
        local dx, dz = worldDelta(0, zoom * 2)
        followPlayer, centerInitialized, center.x, center.z = false, true, center.x + dx, center.z + dz
    elseif event == "key" and first == keys.pageUp then
        zoom = math.max(1, math.floor(zoom / 2))
    elseif event == "key" and first == keys.pageDown then
        zoom = math.min(16, zoom * 2)
    elseif event == "key" and first == keys.space then
        followPlayer = true
        centerInitialized = false
        chooseCenter()
    elseif event == "char" and (first == "+" or first == "=") then
        zoom = math.max(1, math.floor(zoom / 2))
    elseif event == "char" and first == "-" then
        zoom = math.min(16, zoom * 2)
    elseif event == "char" and string.lower(first) == "f" then
        followPlayer = not followPlayer
    elseif event == "mouse_scroll" then
        if first > 0 then zoom = math.min(16, zoom * 2)
        else zoom = math.max(1, math.floor(zoom / 2)) end
    end
    render()
end
