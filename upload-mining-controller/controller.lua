local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local JOB_PROTOCOL = NETWORK_ID .. "/mining/v1"
local DEPLOY_PROTOCOL = NETWORK_ID .. "/deployment/v1"
local STATE_PATH = "/data/controller.state"
local MAX_STORAGE_DRIVES = tonumber(settings.get("bucky.storage.maxDrives", 8)) or 8
local BOOT_ID = ("%d:%d"):format(os.getComputerID(), os.epoch("utc"))
local storage = require("lib.controller_storage")
local spatialStorage = require("lib.controller_spatial")
local routePlanner = require("lib.controller_route")

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function detachedCopy(value, ancestors)
    if type(value) ~= "table" then return value end
    ancestors = ancestors or {}
    if ancestors[value] then return "<cyclic table>" end
    ancestors[value] = true
    local result = {}
    for key, item in pairs(value) do
        result[detachedCopy(key, ancestors)] = detachedCopy(item, ancestors)
    end
    ancestors[value] = nil
    return result
end

local function boundFarmMaps(farmMaps, preserveKey)
    local changed = false
    for farmKey, farmMap in pairs(farmMaps) do
        local data = type(farmMap.data) == "table" and farmMap.data or {}
        local cells = {}
        for _, cell in pairs(type(data.cells) == "table" and data.cells or {}) do
            if type(cell) == "table" and type(cell.x) == "number"
                and type(cell.y) == "number" and type(cell.z) == "number" then
                cells[#cells + 1] = cell
            else
                changed = true
            end
        end
        if type(data.cells) == "table" then
            data.cells = {}
            for _, cell in ipairs(cells) do
                data.cells[("%d:%d"):format(cell.x, cell.z)] = cell
            end
        end
        farmMap.data = data
    end
    return changed
end

local function enableMonitorOutput()
    local monitor = peripheral.find("monitor")
    if not monitor then return end
    pcall(monitor.setTextScale, 0.5)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    local oldPrint, oldWrite, oldError = print, write, printError
    local history = {}
    local function redraw()
        local width, height = monitor.getSize()
        monitor.clear()
        local stats = storage.stats(MAX_STORAGE_DRIVES)
        local left = ("Storage %.1f%% %d/%d"):format(
            stats.percent, stats.connected, stats.maximum
        )
        local right = ("%d/%d"):format(stats.used, stats.capacity)
        monitor.setCursorPos(1, 1)
        monitor.write(left:sub(1, width))
        if #right < width then
            monitor.setCursorPos(width - #right + 1, 1)
            monitor.write(right)
        end
        local lines = {}
        for _, value in ipairs(history) do
            local text = tostring(value)
            repeat
                lines[#lines + 1] = text:sub(1, width)
                text = text:sub(width + 1)
            until text == ""
        end
        local first = math.max(1, #lines - math.max(0, height - 2))
        local row = 2
        for index = first, #lines do
            if row > height then break end
            monitor.setCursorPos(1, row)
            monitor.write(lines[index])
            row = row + 1
        end
    end
    local function mirror(value)
        table.insert(history, tostring(value))
        table.insert(history, "")
        while #history > 200 do table.remove(history, 1) end
        redraw()
    end
    function print(...)
        local values = { ... }
        for index, value in ipairs(values) do values[index] = tostring(value) end
        local text = table.concat(values, "\t")
        oldPrint(text)
        mirror(text)
    end
    function write(value)
        oldWrite(value)
        if #history == 0 then history[1] = "" end
        history[#history] = history[#history] .. tostring(value)
        redraw()
    end
    function printError(...)
        local values = { ... }
        for index, value in ipairs(values) do values[index] = tostring(value) end
        local text = table.concat(values, "\t")
        oldError(text)
        mirror("ERROR: " .. text)
    end
    return redraw
end

local refreshMonitor = enableMonitorOutput()

local function openModems()
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    return opened
end

local function loadState()
    for _, path in ipairs({ STATE_PATH, STATE_PATH .. ".previous", STATE_PATH .. ".tmp" }) do
        if fs.exists(path) then
            local handle = fs.open(path, "r")
            if handle then
                local value = textutils.unserialize(handle.readAll())
                handle.close()
                if type(value) == "table" then
                    local valid = true
                    for _, field in ipairs({
                        "turtles", "jobs", "processedReports", "processedReportOrder",
                        "remoteCommands", "remoteCommandOrder", "sites", "farmMaps",
                        "surveys", "alerts", "relays", "terrainStorage", "spatialStorage",
                    }) do
                        if value[field] == nil then value[field] = {}
                        elseif type(value[field]) ~= "table" then valid = false end
                    end
                    if type(value.nextTurtleNumber) ~= "number" and value.nextTurtleNumber ~= nil
                        or type(value.nextAlertSequence) ~= "number" and value.nextAlertSequence ~= nil then
                        valid = false
                    end
                    for _, turtleInfo in pairs(value.turtles or {}) do
                        if type(turtleInfo) ~= "table" then valid = false break end
                    end
                    for _, alert in ipairs(value.alerts or {}) do
                        if type(alert) ~= "table" then valid = false break end
                    end
                    if not valid then value = nil end
                end
                if type(value) == "table" then
                    value.nextTurtleNumber = value.nextTurtleNumber or 1
                    value.nextAlertSequence = value.nextAlertSequence or 1
                    for index, alert in ipairs(value.alerts) do
                        alert.id = alert.id or ("legacy-%s-%d"):format(tostring(alert.at or 0), index)
                    end
                    return value
                end
            end
        end
    end
    return {
        version = 1, turtles = {}, jobs = {}, processedReports = {}, processedReportOrder = {},
        nextTurtleNumber = 1, nextAlertSequence = 1, remoteCommands = {}, remoteCommandOrder = {},
        sites = {}, farmMaps = {}, surveys = {}, alerts = {}, relays = {}, terrainStorage = {},
        spatialStorage = {},
    }
end

local controllerState = loadState()
spatialStorage.configure(controllerState.spatialStorage)
local farmMapsTrimmedAtBoot = boundFarmMaps(controllerState.farmMaps)
local activeRelays = {}
local announcedTurtleRelease
local trackedPlayer
local routeReservations = {}
local playerDetector = peripheral.find("playerDetector") or peripheral.find("player_detector")
for _, turtleInfo in pairs(controllerState.turtles) do turtleInfo.online = false end

local function installedRelease()
    if not fs.exists("/data/deployment.state") then return nil end
    local handle = fs.open("/data/deployment.state", "r")
    if not handle then return nil end
    local deployment = textutils.unserialize(handle.readAll())
    handle.close()
    return type(deployment) == "table" and deployment.release or nil
end

local function saveState()
    if not fs.exists("/data") then fs.makeDir("/data") end
    local temporary = STATE_PATH .. ".tmp"
    local handle = fs.open(temporary, "w")
    if not handle then return false end
    local snapshot = detachedCopy(controllerState)
    for farmKey, farmMap in pairs(snapshot.farmMaps) do
        local stored = snapshot.terrainStorage[farmKey]
        if stored and tonumber(stored.revision) >= (tonumber(farmMap.revision) or 0)
            and type(farmMap.data) == "table" then
            farmMap.data.cells = nil
        end
    end
    handle.write(textutils.serialize(snapshot, { compact = true }))
    handle.close()
    local previous = STATE_PATH .. ".previous"
    local ok = pcall(function()
        if fs.exists(previous) then fs.delete(previous) end
        if fs.exists(STATE_PATH) then fs.move(STATE_PATH, previous) end
        fs.move(temporary, STATE_PATH)
    end)
    if not ok then
        if not fs.exists(STATE_PATH) and fs.exists(previous) then pcall(fs.move, previous, STATE_PATH) end
        return false
    end
    return fs.exists(STATE_PATH)
end

local function loadFarmMap(farmKey)
    local farmMap = controllerState.farmMaps[farmKey]
    if not farmMap then return nil, "FARM_MAP_NOT_FOUND" end
    if type(farmMap.data) == "table" and type(farmMap.data.cells) == "table" then return farmMap end
    local stored, storageError = storage.readFarm(controllerState.terrainStorage[farmKey])
    if not stored or tonumber(stored.revision) ~= tonumber(farmMap.revision) then
        return nil, storageError or "TERRAIN_REVISION_MISMATCH"
    end
    farmMap.data = stored.data
    return farmMap
end

local function handleFarmRouteRequest(sender, message)
    local requestId = type(message.requestId) == "string" and message.requestId
    local start, target = message.start, message.target
    local function reject(reason)
        rednet.send(sender, {
            type = message.type == "ROUTE_REQUEST" and "ROUTE_RESPONSE" or "FARM_ROUTE_RESPONSE",
            requestId = requestId,
            ok = false, error = reason, controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
    end
    if not requestId or not controllerState.turtles[sender] then return reject("UNREGISTERED_WORKER") end
    if type(start) ~= "table" or type(target) ~= "table"
        or type(start.x) ~= "number" or type(start.y) ~= "number" or type(start.z) ~= "number"
        or type(target.x) ~= "number" or type(target.y) ~= "number" or type(target.z) ~= "number"
        or start.x ~= math.floor(start.x) or start.y ~= math.floor(start.y)
        or start.z ~= math.floor(start.z) or target.x ~= math.floor(target.x)
        or target.y ~= math.floor(target.y) or target.z ~= math.floor(target.z) then
        return reject("INVALID_ROUTE_COORDINATES")
    end
    local turtleInfo = controllerState.turtles[sender]
    if type(turtleInfo.position) ~= "table" or turtleInfo.position.x ~= start.x
        or turtleInfo.position.y ~= start.y or turtleInfo.position.z ~= start.z
        or not turtleInfo.positionVerifiedAt or not turtleInfo.lastSeen
        or os.epoch("utc") - turtleInfo.lastSeen > 45000 then
        return reject("ROUTE_START_NOT_VERIFIED")
    end
    local mapId = message.mapId or message.farmId or "world"
    if type(mapId) ~= "string" then return reject("INVALID_ROUTE_MAP") end
    local now, excluded = os.epoch("utc"), {}
    for reservationId, reservation in pairs(routeReservations) do
        if reservation.expiresAt <= now then routeReservations[reservationId] = nil
        elseif reservation.turtleId ~= sender then
            for _, point in ipairs(reservation.path) do
                excluded[("%d:%d:%d"):format(point.x, point.y, point.z)] = true
            end
        end
    end
    for turtleId, other in pairs(controllerState.turtles) do
        if turtleId ~= sender and other.online ~= false and type(other.position) == "table"
            and other.lastSeen and now - other.lastSeen <= 45000 then
            for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
                excluded[("%d:%d:%d"):format(
                    math.floor(other.position.x) + dx, math.floor(other.position.y) + dy,
                    math.floor(other.position.z) + dz
                )] = true
            end end end
        end
    end
    if trackedPlayer and trackedPlayer.sampledAt and now - trackedPlayer.sampledAt <= 2000 then
        for dx = -2, 2 do for dy = -1, 2 do for dz = -2, 2 do
            excluded[("%d:%d:%d"):format(
                math.floor(trackedPlayer.x) + dx, math.floor(trackedPlayer.y) + dy,
                math.floor(trackedPlayer.z) + dz
            )] = true
        end end end
    end
    local path, routeError = routePlanner.find3D(
        start, target, spatialStorage.cellReader(mapId), excluded,
        { maximumNodes = 30000, margin = 24 }
    )
    if not path then return reject(routeError or "NO_SAFE_CONTROLLER_ROUTE") end
    if #path > 1024 then return reject("CONTROLLER_ROUTE_TOO_LONG") end
    local reservationId = ("route-%d-%d"):format(sender, now)
    local reservationExpiresAt = now + math.max(30000, #path * 1500 + 10000)
    routeReservations[reservationId] = {
        turtleId = sender, mapId = mapId, path = detachedCopy(path),
        acquiredAt = now, expiresAt = reservationExpiresAt,
    }
    rednet.send(sender, {
        type = message.type == "ROUTE_REQUEST" and "ROUTE_RESPONSE" or "FARM_ROUTE_RESPONSE",
        requestId = requestId, ok = true, path = path,
        reservationId = reservationId, reservationExpiresAt = reservationExpiresAt,
        controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
end

local function handleRouteControl(sender, message)
    local reservation = type(message.reservationId) == "string"
        and routeReservations[message.reservationId]
    if not reservation or reservation.turtleId ~= sender then return end
    if message.type == "ROUTE_BLOCKED" and type(message.point) == "table"
        and type(message.blockName) == "string" then
        local updated, updateError = spatialStorage.updateCell(
            reservation.mapId, message.point, message.blockName
        )
        if not updated then
            printError("Blocked route map update failed: " .. tostring(updateError))
        elseif not saveState() then
            printError("Blocked route map index could not be saved")
        end
    end
    routeReservations[message.reservationId] = nil
end

local function handleFarmTerrainRequest(sender, message)
    local requestId = type(message.requestId) == "string" and message.requestId
    local farmMap, loadError
    if requestId and controllerState.turtles[sender] then
        farmMap, loadError = loadFarmMap(message.farmId)
    else
        loadError = "UNREGISTERED_WORKER"
    end
    if not farmMap then
        rednet.send(sender, {
            type = "FARM_TERRAIN_RESPONSE", requestId = requestId,
            ok = false, error = loadError, controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    if type(message.minRevision) == "number" and farmMap.revision < message.minRevision then
        farmMap.data.cells = nil
        rednet.send(sender, {
            type = "FARM_TERRAIN_RESPONSE", requestId = requestId,
            ok = false, error = "CONTROLLER_TERRAIN_STALE", controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    local cells = {}
    for _, cell in pairs(farmMap.data.cells or {}) do cells[#cells + 1] = detachedCopy(cell) end
    table.sort(cells, function(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end)
    local chunkCount = math.max(1, math.ceil(#cells / 32))
    rednet.send(sender, {
        type = "FARM_TERRAIN_BEGIN", requestId = requestId, ok = true,
        revision = farmMap.revision, chunkCount = chunkCount, cellCount = #cells,
        controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
    for chunkIndex = 1, chunkCount do
        local chunk, first = {}, (chunkIndex - 1) * 32 + 1
        for index = first, math.min(first + 31, #cells) do chunk[#chunk + 1] = cells[index] end
        rednet.send(sender, {
            type = "FARM_TERRAIN_CHUNK", requestId = requestId,
            chunkIndex = chunkIndex, chunkCount = chunkCount, cells = chunk,
            controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
    end
    rednet.send(sender, {
        type = "FARM_TERRAIN_END", requestId = requestId,
        revision = farmMap.revision, chunkCount = chunkCount, controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
    farmMap.data.cells = nil
end

local function handleFarmSpatialRequest(sender, message)
    local requestId = type(message.requestId) == "string" and message.requestId
    if not requestId or not controllerState.turtles[sender] or type(message.farmId) ~= "string"
        or type(message.chunks) ~= "table" or #message.chunks < 1 or #message.chunks > 27 then
        rednet.send(sender, {
            type = "FARM_3D_CHUNK_RESPONSE", requestId = requestId, ok = false,
            error = "INVALID_SPATIAL_REQUEST", controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    for _, chunkKey in ipairs(message.chunks) do
        if type(chunkKey) ~= "string" or not chunkKey:match("^-?%d+:-?%d+:-?%d+$") then
            rednet.send(sender, {
                type = "FARM_3D_CHUNK_RESPONSE", requestId = requestId, ok = false,
                error = "INVALID_SPATIAL_CHUNK_KEY", controllerBootId = BOOT_ID,
            }, JOB_PROTOCOL)
            return
        end
        local chunk = spatialStorage.read(message.farmId, chunkKey)
        rednet.send(sender, {
            type = "FARM_3D_CHUNK_RESPONSE", requestId = requestId, ok = true,
            farmId = message.farmId, chunkKey = chunkKey, chunk = chunk,
            missing = chunk == nil,
            controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
    end
end

local function handleFarmSurveyPlanRequest(sender, message)
    local requestId = type(message.requestId) == "string" and message.requestId
    local center, start = message.center, message.start
    local radius, step, baseY = tonumber(message.radius), tonumber(message.step), tonumber(message.baseY)
    local valid = requestId and controllerState.turtles[sender] and type(message.farmId) == "string"
        and type(center) == "table" and type(start) == "table"
        and type(center.x) == "number" and center.x == math.floor(center.x)
        and type(center.z) == "number" and center.z == math.floor(center.z)
        and type(start.x) == "number" and start.x == math.floor(start.x)
        and type(start.z) == "number" and start.z == math.floor(start.z)
        and baseY and baseY == math.floor(baseY) and radius and radius >= 1 and radius <= 128
        and radius == math.floor(radius) and step and step >= 1 and step <= 16
        and step == math.floor(step) and message.version == 2
    if not valid then
        rednet.send(sender, {
            type = "FARM_3D_SURVEY_PLAN_RESPONSE", requestId = requestId, ok = false,
            error = "INVALID_SURVEY_PLAN_REQUEST", controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    local poses, version = spatialStorage.surveyPlan(
        message.farmId, center.x, center.z, baseY, radius, step, start
    )
    if #poses > 1024 then
        rednet.send(sender, {
            type = "FARM_3D_SURVEY_PLAN_RESPONSE", requestId = requestId, ok = false,
            error = "SURVEY_PLAN_TOO_LARGE", controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    rednet.send(sender, {
        type = "FARM_3D_SURVEY_PLAN_RESPONSE", requestId = requestId, ok = true,
        farmId = message.farmId, version = version, poses = poses,
        controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
end

local function surfaceEnvironment(farmId, x, y, z)
    local farmMap = loadFarmMap(farmId)
    for _, cell in pairs(farmMap and farmMap.data and farmMap.data.cells or {}) do
        if math.floor(cell.x) == math.floor(x) and math.floor(cell.z) == math.floor(z) then
            local surfaceY = tonumber(cell.surfaceY) or tonumber(cell.y)
            if surfaceY then return y >= surfaceY + 1 and "surface" or "cave" end
        end
    end
    return nil
end

local function handleRelaySpatialSliceRequest(sender, message)
    local requestId = type(message.requestId) == "string" and message.requestId
    local farmId, centerX, centerZ = message.farmId, tonumber(message.x), tonumber(message.z)
    local layerY, radius = tonumber(message.y), tonumber(message.radius)
    if not requestId or not activeRelays[sender] or type(farmId) ~= "string"
        or not finiteNumber(centerX) or not finiteNumber(centerZ) or not finiteNumber(layerY)
        or not finiteNumber(radius) or radius < 4 or radius > 64 then
        rednet.send(sender, {
            type = "FARM_3D_SLICE_RESPONSE", requestId = requestId, ok = false,
            error = "INVALID_3D_SLICE_REQUEST", controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    centerX, centerZ, layerY, radius = math.floor(centerX), math.floor(centerZ),
        math.floor(layerY), math.floor(radius)
    local cells = spatialStorage.slice(farmId, centerX, centerZ, layerY, radius)
    local focusX = trackedPlayer and trackedPlayer.x or centerX
    local focusY = trackedPlayer and trackedPlayer.y or layerY
    local focusZ = trackedPlayer and trackedPlayer.z or centerZ
    local environment = surfaceEnvironment(farmId, focusX, focusY, focusZ)
        or spatialStorage.classify(farmId, focusX, focusY, focusZ)
    local chunkCount = math.max(1, math.ceil(#cells / 64))
    rednet.send(sender, {
        type = "FARM_3D_SLICE_BEGIN", requestId = requestId, farmId = farmId,
        x = centerX, y = layerY, z = centerZ, radius = radius,
        environment = environment,
        cellCount = #cells, chunkCount = chunkCount, controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
    for chunkIndex = 1, chunkCount do
        local chunk, first = {}, (chunkIndex - 1) * 64 + 1
        for index = first, math.min(first + 63, #cells) do chunk[#chunk + 1] = cells[index] end
        rednet.send(sender, {
            type = "FARM_3D_SLICE_CHUNK", requestId = requestId,
            chunkIndex = chunkIndex, chunkCount = chunkCount, cells = chunk,
            controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
    end
    rednet.send(sender, {
        type = "FARM_3D_SLICE_END", requestId = requestId,
        chunkCount = chunkCount, cellCount = #cells, controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
end

local storageChanged = false
for farmKey, farmMap in pairs(controllerState.farmMaps) do
    if type(farmMap.data) == "table" and type(farmMap.data.cells) == "table"
        and next(farmMap.data.cells) ~= nil then
        local stored, storageError = storage.writeFarm(
            farmKey, farmMap, controllerState.terrainStorage[farmKey]
        )
        if stored then
            controllerState.terrainStorage[farmKey] = stored
            storageChanged = true
        else
            printError(("Terrain migration deferred for %s: %s"):format(
                tostring(farmKey), tostring(storageError)
            ))
        end
    end
end
local spatialStorageChanged = spatialStorage.migrateLegacy()
if farmMapsTrimmedAtBoot or storageChanged or spatialStorageChanged then saveState() end

local actionableStatuses = {
    NEEDS_FUEL = true,
    NEEDS_INVENTORY_SPACE = true,
    NEEDS_TOOL = true,
    NEEDS_SUPPLIES = true,
    NEEDS_OUTPUT = true,
    NEEDS_SCANNER = true,
    NEEDS_FARM = true,
    NEEDS_NETWORK = true,
    RECOVERING = true,
    JOB_FAILED = true,
}

local function registerRelay(relayId)
    controllerState.relays[relayId] = os.epoch("utc")
    activeRelays[relayId] = true
end

local function readTrackedPlayer()
    if not playerDetector then
        playerDetector = peripheral.find("playerDetector") or peripheral.find("player_detector")
    end
    if not playerDetector then return nil end
    local playerName = settings.get("bucky.player")
    if type(playerName) ~= "string" or playerName == "" then
        local ok, online = pcall(playerDetector.getOnlinePlayers)
        if not ok or type(online) ~= "table" or #online ~= 1 then return nil end
        playerName = online[1]
    end
    local ok, position = pcall(playerDetector.getPlayerPos, playerName)
    if not ok or type(position) ~= "table" or not finiteNumber(position.x)
        or not finiteNumber(position.y) or not finiteNumber(position.z)
        or not finiteNumber(position.yaw) then return nil end
    return {
        name = tostring(playerName):sub(1, 64),
        x = position.x, y = position.y, z = position.z,
        yaw = position.yaw, pitch = finiteNumber(position.pitch) and position.pitch or nil,
        sampledAt = os.epoch("utc"),
    }
end

local function sendTrackedPlayer(recipient)
    local message = {
        type = "PLAYER_UPDATE", controllerBootId = BOOT_ID,
        player = trackedPlayer and detachedCopy(trackedPlayer) or false,
    }
    if recipient then
        rednet.send(recipient, message, JOB_PROTOCOL)
    else
        for relayId in pairs(activeRelays) do rednet.send(relayId, message, JOB_PROTOCOL) end
    end
end

local function pollTrackedPlayer()
    local previousAvailable = trackedPlayer ~= nil
    trackedPlayer = readTrackedPlayer()
    if trackedPlayer or previousAvailable then sendTrackedPlayer() end
end

local function sendWorkerAlert(turtleId, turtleName, status, detail, sourceId, customText)
    local alertId
    if sourceId then
        alertId = "source-" .. tostring(sourceId)
    else
        local sequence = controllerState.nextAlertSequence or 1
        controllerState.nextAlertSequence = sequence + 1
        alertId = ("alert-%d-%d"):format(os.getComputerID(), sequence)
    end
    local alert, found
    for _, existing in ipairs(controllerState.alerts) do
        if existing.id == alertId then alert, found = existing, true break end
    end
    alert = alert or {
        id = alertId,
        turtleId = turtleId,
        turtleName = turtleName,
        status = status,
        text = customText or ("%s needs attention: %s"):format(
            turtleName, tostring(detail or status or "unknown problem")
        ),
        at = os.epoch("utc"),
    }
    if not found then
        table.insert(controllerState.alerts, alert)
        while #controllerState.alerts > 100 do table.remove(controllerState.alerts, 1) end
    end

    local message = {
        type = "WORKER_ALERT",
        turtleId = alert.turtleId,
        turtleName = alert.turtleName,
        status = alert.status,
        text = alert.text,
        alertId = alert.id,
        controllerBootId = BOOT_ID,
    }
    for relayId in pairs(activeRelays) do
        rednet.send(relayId, message, JOB_PROTOCOL)
    end
    rednet.broadcast(message, JOB_PROTOCOL)
end

local function currentAlerts()
    local result = detachedCopy(controllerState.alerts)
    local seen = {}
    for _, alert in ipairs(result) do
        seen[("%s:%s:%s"):format(
            tostring(alert.turtleId), tostring(alert.status), tostring(alert.text)
        )] = true
    end
    for turtleId, turtleInfo in pairs(controllerState.turtles) do
        if actionableStatuses[turtleInfo.status] then
            local text = ("%s currently needs attention: %s"):format(
                turtleInfo.name or ("turtle-" .. tostring(turtleId)),
                tostring(turtleInfo.status)
            )
            local key = ("%s:%s:%s"):format(tostring(turtleId), tostring(turtleInfo.status), text)
            if not seen[key] then
                table.insert(result, {
                    turtleId = turtleId,
                    turtleName = turtleInfo.name,
                    status = turtleInfo.status,
                    text = text,
                    source = "current-turtle-status",
                })
                seen[key] = true
            end
        end
    end
    for id, job in pairs(controllerState.jobs) do
        if job.status == "JOB_FAILED" or job.status == "JOB_REJECTED" or job.status == "SEND_FAILED" then
            table.insert(result, {
                jobId = id,
                turtleId = job.turtleId,
                status = job.status,
                text = type(job.result) == "string" and job.result or ("Job " .. id .. " is " .. job.status),
                source = "current-job-status",
            })
        end
    end
    return result
end

local function latestAlerts(limit)
    local turtleIds = {}
    for turtleId in pairs(controllerState.turtles) do table.insert(turtleIds, turtleId) end
    table.sort(turtleIds, function(a, b) return tostring(a) < tostring(b) end)
    local currentTurtleKeys = {}
    for _, turtleId in ipairs(turtleIds) do
        local turtleInfo = controllerState.turtles[turtleId]
        if actionableStatuses[turtleInfo.status] then
            currentTurtleKeys[("%s:%s"):format(tostring(turtleId), tostring(turtleInfo.status))] = true
        end
    end
    local all = {}
    for _, alert in ipairs(controllerState.alerts) do
        local key = ("%s:%s"):format(tostring(alert.turtleId), tostring(alert.status))
        if not currentTurtleKeys[key] then table.insert(all, detachedCopy(alert)) end
    end
    for _, turtleId in ipairs(turtleIds) do
        local turtleInfo = controllerState.turtles[turtleId]
        if actionableStatuses[turtleInfo.status] then
            table.insert(all, {
                id = ("current-%s-%s-%s"):format(
                    tostring(turtleId), tostring(turtleInfo.status), tostring(turtleInfo.statusDetail or "")
                ),
                turtleId = turtleId,
                turtleName = turtleInfo.name,
                status = turtleInfo.status,
                text = ("%s needs attention: %s"):format(
                    turtleInfo.name or ("turtle-" .. tostring(turtleId)),
                    tostring(turtleInfo.statusDetail or turtleInfo.status)
                ),
                source = "current-turtle-status",
            })
        end
    end
    local jobIds = {}
    for id in pairs(controllerState.jobs) do table.insert(jobIds, id) end
    table.sort(jobIds)
    for _, id in ipairs(jobIds) do
        local job = controllerState.jobs[id]
        if job.status == "JOB_FAILED" or job.status == "JOB_REJECTED" or job.status == "SEND_FAILED" then
            table.insert(all, {
                id = ("current-job-%s-%s-%s"):format(
                    id, job.status, type(job.result) == "string" and job.result or ""
                ),
                jobId = id,
                turtleId = job.turtleId,
                status = job.status,
                text = type(job.result) == "string" and job.result or ("Job " .. id .. " is " .. job.status),
                source = "current-job-status",
            })
        end
    end
    local result = {}
    local first = math.max(1, #all - limit + 1)
    for index = first, #all do table.insert(result, all[index]) end
    return result
end

local function completionSnapshot()
    local turtles, sites = {}, {}
    for _, turtleInfo in pairs(controllerState.turtles) do
        if turtleInfo.name then table.insert(turtles, turtleInfo.name) end
    end
    for id in pairs(controllerState.sites) do table.insert(sites, id) end
    table.sort(turtles)
    table.sort(sites)
    return turtles, sites
end

local function jobId()
    return ("controller-%d-%d"):format(os.getComputerID(), os.epoch("utc"))
end

local function parseInteger(value, name)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then
        printError((name or "value") .. " must be an integer")
        return nil
    end
    return number
end

local function sendJob(turtleId, jobType, parameters, fixedId)
    local turtleInfo = controllerState.turtles[turtleId]
    if not turtleInfo then
        printError("UNKNOWN_COMPUTER: turtle " .. tostring(turtleId) .. " is not registered")
        return false, "UNKNOWN_COMPUTER"
    end
    if turtleInfo.online == false
        or not turtleInfo.lastSeen or os.epoch("utc") - turtleInfo.lastSeen > 45000 then
        printError("Turtle " .. tostring(turtleId) .. " is offline")
        return false, "TURTLE_OFFLINE"
    end
    if turtleInfo.navigationReady == false then
        local reason = "Navigation is not ready"
        if turtleInfo.navigationError then reason = reason .. ": " .. tostring(turtleInfo.navigationError) end
        printError(reason)
        return false, reason
    end
    local id = fixedId or jobId()
    if controllerState.jobs[id] then return true, "Job " .. id .. " was already submitted" end
    local job = { id = id, type = jobType, parameters = parameters, progress = {} }
    controllerState.jobs[job.id] = {
        turtleId = turtleId, type = jobType, parameters = detachedCopy(parameters),
        status = "PENDING_SEND", createdAt = os.epoch("utc"),
    }
    if not saveState() then
        controllerState.jobs[job.id] = nil
        printError("Job was not sent because controller state could not be saved")
        return false, "Controller state could not be saved"
    end
    if not rednet.send(turtleId, { type = "ASSIGN_JOB", job = job }, JOB_PROTOCOL) then
        controllerState.jobs[job.id].status = "SEND_FAILED"
        saveState()
        printError("Unable to send job to turtle " .. turtleId)
        return false, "Unable to send job to turtle"
    end
    controllerState.jobs[job.id].status = "SENT"
    controllerState.jobs[job.id].sentAt = os.epoch("utc")
    saveState()
    print(("Sent %s job %s to turtle %d"):format(jobType, job.id, turtleId))
    return true, "Job " .. job.id .. " sent"
end

local function resolveTurtle(value)
    local numeric = tonumber(value)
    if numeric and controllerState.turtles[numeric] then return numeric end
    for id, turtleInfo in pairs(controllerState.turtles) do
        if turtleInfo.name == value then return id end
    end
    for id, turtleInfo in pairs(controllerState.turtles) do
        if turtleInfo.label == value then return id end
    end
    printError("Unknown turtle name: " .. tostring(value))
    return nil
end

local function sendControl(turtleId, action, parameters)
    local message = { type = "CONTROL_JOB", action = action }
    if parameters then message.parameters = parameters end
    if not rednet.send(turtleId, message, JOB_PROTOCOL) then
        return false, "Unable to send control command"
    end
    return true, ("%s sent to turtle %d"):format(action, turtleId)
end

local function activeFarmJobId(turtleId)
    local foundId, foundAt
    for id, job in pairs(controllerState.jobs) do
        local terminal = job.status == "JOB_COMPLETE" or job.status == "JOB_FAILED"
            or job.status == "JOB_CANCELLED" or job.status == "JOB_REJECTED"
            or job.status == "SEND_FAILED"
        if job.turtleId == turtleId and job.type == "FARM_SERVICE" and not terminal then
            local createdAt = tonumber(job.createdAt) or 0
            if not foundAt or createdAt > foundAt then foundId, foundAt = id, createdAt end
        end
    end
    return foundId
end

local function showHelp()
    print("turtles")
    print("jobs")
    print("retry | retry now | retry <turtle-name> | cancel <turtle-name>")
    print("travel <turtle-name> <x> <y> <z>")
    print("dig <turtle-name> <direction> <length> [profile]")
    print("repair <turtle-name> <x> <y> <z> <marker-type>")
    print("survey <turtle-name> [radius] [exact-block-name]")
    print("farm-service <turtle-name> start [radius]")
    print("farm-service <turtle-name> stop | status")
    print("farm-expand <turtle-name> [on|off|toggle]")
    print("farm-radius <turtle-name> <radius>")
    print("farm <turtle-name> <farm-id> [mature-age] [seed-name]")
    print("tunnel <turtle-name> <tunnel-id> <length>")
    print("setup-station <turtle-name> <id> <supply-direction> <output-direction>")
    print("setup-tunnel <turtle-name> <id> <direction> <width> <height>")
    print("setup-farm <turtle-name> <id> <width> <length> <direction> <crop> <seed> [age] <station-id>")
    print("setup-room <turtle-name> <id> <type> <direction> <width> <length> <height>")
    print("sites | surveys")
    print("storage")
    print("help")
end

local function handleCommand(line, fixedJobId)
    local tokens = {}
    for token in tostring(line):gmatch("%S+") do table.insert(tokens, token) end
    local command = string.lower(tokens[1] or "")
    if command == "" then return end
    if command == "help" then
        showHelp()
        return true, "turtles | jobs | sites | surveys | storage | retry | cancel | travel | dig | repair | survey | farm-service | farm-expand | farm-radius | farm | tunnel | setup-* | help"
    end
    if command == "turtles" then
        local result = textutils.serialize(controllerState.turtles)
        print(result)
        return true, result
    end
    if command == "jobs" then
        local result = textutils.serialize(controllerState.jobs)
        print(result)
        return true, result
    end
    if command == "sites" or command == "surveys" then
        local result = textutils.serialize(controllerState[command])
        print(result)
        return true, result
    end
    if command == "storage" then
        local result = textutils.serialize(storage.describe())
        print(result)
        return true, result
    end
    if command == "retry" and (not tokens[2] or tokens[2] == "now"
        or tokens[2] == "on" or tokens[2] == "off" or tokens[2] == "status") then
        local action = not tokens[2] and "retry_toggle"
            or tokens[2] == "now" and "retry"
            or tokens[2] == "on" and "retry_on"
            or tokens[2] == "off" and "retry_off" or "retry_status"
        local sent = 0
        for turtleId in pairs(controllerState.turtles) do
            if sendControl(turtleId, action) then sent = sent + 1 end
        end
        local description = not tokens[2] and "toggle"
            or tokens[2] == "now" and "immediate retry" or tokens[2]
        local result = ("%s sent to %d turtle(s)"):format(description, sent)
        print(result)
        return true, result
    end
    local turtleId = resolveTurtle(tokens[2])
    if not turtleId then return false, "Unknown turtle" end
    if command == "farm-service" then
        local operation = string.lower(tokens[3] or "")
        if operation == "start" then
            local radius = tokens[4] and parseInteger(tokens[4], "radius") or 32
            if not radius or radius < 1 or radius > 32 then return false, "radius must be from 1 to 32" end
            return sendJob(turtleId, "FARM_SERVICE", {
                radius = radius, autoExpand = true,
            }, fixedJobId)
        elseif operation == "stop" then
            local farmJobId = activeFarmJobId(turtleId)
            if not farmJobId then return false, "No tracked farm service for this turtle" end
            return sendControl(turtleId, "farm_cancel", { jobId = farmJobId })
        elseif operation == "status" then
            return sendControl(turtleId, "farm_status", { jobId = activeFarmJobId(turtleId) })
        end
        return false, "Usage: farm-service <turtle-name> start [radius] | stop | status"
    elseif command == "farm-expand" then
        local value = string.lower(tokens[3] or "toggle")
        if value ~= "on" and value ~= "off" and value ~= "toggle" then
            return false, "farm-expand option must be on, off, or toggle"
        end
        local parameters = {}
        if value ~= "toggle" then parameters.autoExpand = value == "on" end
        parameters.jobId = activeFarmJobId(turtleId)
        if not parameters.jobId then return false, "No tracked farm service for this turtle" end
        return sendControl(turtleId, "farm_expand", parameters)
    elseif command == "farm-radius" then
        local radius = parseInteger(tokens[3], "radius")
        if not radius or radius < 1 or radius > 32 then return false, "radius must be from 1 to 32" end
        local farmJobId = activeFarmJobId(turtleId)
        if not farmJobId then return false, "No tracked farm service for this turtle" end
        return sendControl(turtleId, "farm_radius", { radius = radius, jobId = farmJobId })
    elseif command == "retry" or command == "cancel" then
        local action = command
        if command == "retry" and tokens[3] then
            if tokens[3] == "on" then action = "retry_on"
            elseif tokens[3] == "off" then action = "retry_off"
            elseif tokens[3] == "status" then action = "retry_status"
            else return false, "retry option must be on, off, or status" end
        elseif command == "retry" then
            action = "retry_toggle"
        end
        return sendControl(turtleId, action)
    elseif command == "travel" then
        local x = parseInteger(tokens[3], "x")
        local y = parseInteger(tokens[4], "y")
        local z = parseInteger(tokens[5], "z")
        if x and y and z then
            return sendJob(turtleId, "TRAVEL", { x = x, y = y, z = z }, fixedJobId)
        end
    elseif command == "dig" then
        local length = parseInteger(tokens[4], "length")
        if tokens[3] and length then
            return sendJob(turtleId, "DIG_TUNNEL", {
                direction = tokens[3], length = length, profile = tokens[5],
            }, fixedJobId)
        end
    elseif command == "repair" then
        local x = parseInteger(tokens[3], "x")
        local y = parseInteger(tokens[4], "y")
        local z = parseInteger(tokens[5], "z")
        if x and y and z and tokens[6] then
            return sendJob(turtleId, "REPAIR_MARKER", {
                position = { x = x, y = y, z = z }, markerType = string.upper(tokens[6]),
            }, fixedJobId)
        end
    elseif command == "survey" then
        local radius = tokens[3] and parseInteger(tokens[3], "radius") or nil
        if not tokens[3] or radius then
            return sendJob(turtleId, "SURVEY_AREA", {
                radius = radius, blockFilter = tokens[4],
            }, fixedJobId)
        end
    elseif command == "farm" then
        local farm = controllerState.sites[tokens[3]]
        local age = tokens[4] and parseInteger(tokens[4], "mature age") or nil
        if tokens[4] and not age then return false, "Invalid mature age" end
        if not farm then
            return sendJob(turtleId, "FARM_CROP", {
                farmId = tokens[3], matureAge = age, seed = tokens[5],
            }, fixedJobId)
        end
        if farm.type ~= "farm" then return false, "Site is not a farm" end
        local assignedFarm = detachedCopy(farm)
        assignedFarm.station = detachedCopy(controllerState.sites[farm.stationId])
        return sendJob(turtleId, "FARM_CROP", {
            farmId = farm.id, farm = assignedFarm, matureAge = age, seed = tokens[5],
        }, fixedJobId)
    elseif command == "tunnel" then
        local tunnel = controllerState.sites[tokens[3]]
        local length = parseInteger(tokens[4], "length")
        if not tunnel or tunnel.type ~= "tunnel_entrance" then return false, "Unknown tunnel" end
        if length then
            return sendJob(turtleId, "DIG_TUNNEL", {
                direction = tunnel.direction, length = length,
                width = tunnel.width, height = tunnel.height, profile = tunnel.profile,
            }, fixedJobId)
        end
    elseif command == "setup-station" then
        if not tokens[3] or not tokens[4] or not tokens[5] then return false, "Station setup fields are missing" end
        return sendJob(turtleId, "CONFIGURE_SITE", {
            kind = "station", id = tokens[3], supplyDirection = tokens[4], outputDirection = tokens[5],
        }, fixedJobId)
    elseif command == "setup-tunnel" then
        if not tokens[3] or not tokens[4] or not tokens[5] or not tokens[6] then
            return false, "Tunnel setup fields are missing"
        end
        local width, height = parseInteger(tokens[5], "width"), parseInteger(tokens[6], "height")
        if width and height then
            return sendJob(turtleId, "CONFIGURE_SITE", {
                kind = "tunnel", id = tokens[3], direction = tokens[4], width = width, height = height,
            }, fixedJobId)
        end
    elseif command == "setup-farm" then
        if not tokens[3] or not tokens[4] or not tokens[5] or not tokens[6]
            or not tokens[7] or not tokens[8] or not tokens[9] then
            return false, "Farm setup fields are missing"
        end
        local width, length = parseInteger(tokens[4], "width"), parseInteger(tokens[5], "length")
        local age = tokens[10] and parseInteger(tokens[9], "mature age") or nil
        local stationId = tokens[10] or tokens[9]
        if width and length and (not tokens[10] or age) then
            return sendJob(turtleId, "CONFIGURE_SITE", {
                kind = "farm", id = tokens[3], width = width, length = length,
                direction = tokens[6], crop = tokens[7], seed = tokens[8],
                matureAge = age, stationId = stationId,
            }, fixedJobId)
        end
    elseif command == "setup-room" then
        if not tokens[3] or not tokens[4] or not tokens[5] or not tokens[6]
            or not tokens[7] or not tokens[8] then return false, "Room setup fields are missing" end
        local width = parseInteger(tokens[6], "width")
        local length = parseInteger(tokens[7], "length")
        local height = parseInteger(tokens[8], "height")
        if width and length and height then
            return sendJob(turtleId, "CONFIGURE_SITE", {
                kind = "room", id = tokens[3], roomType = tokens[4], direction = tokens[5],
                width = width, length = length, height = height,
            }, fixedJobId)
        end
    else
        printError("Unknown command")
        showHelp()
        return false, "Unknown command"
    end
end

local function relayTurtleStates()
    local result = {}
    for id, turtleInfo in pairs(controllerState.turtles) do
        result[id] = {
            id = id, name = turtleInfo.name, label = turtleInfo.label,
            status = turtleInfo.status, position = detachedCopy(turtleInfo.position),
            heading = turtleInfo.heading, positionVerifiedAt = turtleInfo.positionVerifiedAt,
            lastSeen = turtleInfo.lastSeen, online = turtleInfo.online,
            release = turtleInfo.release,
        }
    end
    return result
end

local function farmMapIndex()
    local result = {}
    for farmKey, farmMap in pairs(controllerState.farmMaps) do
        local data = farmMap.data or {}
        result[#result + 1] = {
            farmKey = farmKey, revision = farmMap.revision,
            center = detachedCopy(data.center), radius = data.radius,
            phase = data.phase, knownColumns = data.knownColumns,
        }
    end
    table.sort(result, function(a, b) return tostring(a.farmKey) < tostring(b.farmKey) end)
    return result
end

local function expireTurtleLeases()
    local now = os.epoch("utc")
    for reservationId, reservation in pairs(routeReservations) do
        if reservation.expiresAt <= now then routeReservations[reservationId] = nil end
    end
    for _, turtleInfo in pairs(controllerState.turtles) do
        if turtleInfo.online ~= false and (not turtleInfo.lastSeen or now - turtleInfo.lastSeen > 45000) then
            turtleInfo.online = false
            printError(("%s offline: heartbeat lease expired"):format(
                turtleInfo.name or ("turtle-" .. tostring(turtleInfo.id))
            ))
            for relayId in pairs(activeRelays) do
                rednet.send(relayId, {
                    type = "TURTLE_UPDATE", controllerBootId = BOOT_ID,
                    turtle = detachedCopy(turtleInfo),
                }, JOB_PROTOCOL)
            end
        end
    end
end

local currentHeartbeatNonce
local function controllerHello(recipient)
    local turtles, sites = completionSnapshot()
    local sentAt = os.epoch("utc")
    currentHeartbeatNonce = currentHeartbeatNonce or BOOT_ID .. ":" .. tostring(sentAt)
    local message = {
        type = "CONTROLLER_HELLO",
        controllerId = os.getComputerID(),
        bootId = BOOT_ID,
        turtles = turtles,
        turtleStates = relayTurtleStates(),
        sites = sites,
        farmMapKeys = farmMapIndex(),
        sentAt = sentAt,
        heartbeatNonce = currentHeartbeatNonce,
    }
    if recipient then rednet.send(recipient, message, JOB_PROTOCOL)
    else rednet.broadcast(message, JOB_PROTOCOL) end
end

local function controllerHeartbeat()
    local sentAt = os.epoch("utc")
    currentHeartbeatNonce = BOOT_ID .. ":" .. tostring(sentAt)
    rednet.broadcast({
        type = "CONTROLLER_HELLO",
        controllerId = os.getComputerID(),
        bootId = BOOT_ID,
        heartbeatNonce = currentHeartbeatNonce,
        sentAt = sentAt,
    }, JOB_PROTOCOL)
end


local function sendFarmSnapshot(recipient, farmKey)
    local farmMap = loadFarmMap(farmKey)
    if not farmMap then return false end
    local data = farmMap.data or {}
    local cells = {}
    for _, cell in pairs(data.cells or {}) do cells[#cells + 1] = detachedCopy(cell) end
    table.sort(cells, function(a, b)
        return a.x == b.x and a.z < b.z or a.x < b.x
    end)
    local chunkCount = math.max(1, math.ceil(#cells / 32))
    local snapshotId = ("%s:%s:%d"):format(BOOT_ID, tostring(farmKey), os.epoch("utc"))
    local metadata = {
        farmId = data.farmId, jobId = data.jobId, phase = data.phase,
        center = detachedCopy(data.center), radius = data.radius,
        autoExpand = data.autoExpand, knownColumns = data.knownColumns,
        summary = detachedCopy(data.summary),
    }
    rednet.send(recipient, {
        type = "FARM_MAP_SNAPSHOT_BEGIN", controllerBootId = BOOT_ID,
        farmKey = farmKey, snapshotId = snapshotId,
        mapRevision = farmMap.revision, chunkCount = chunkCount,
        cellCount = #cells, metadata = metadata,
    }, JOB_PROTOCOL)
    for chunkIndex = 1, chunkCount do
        local chunk = {}
        local first = (chunkIndex - 1) * 32 + 1
        for index = first, math.min(first + 31, #cells) do chunk[#chunk + 1] = cells[index] end
        rednet.send(recipient, {
            type = "FARM_MAP_SNAPSHOT_CHUNK", controllerBootId = BOOT_ID,
            farmKey = farmKey, snapshotId = snapshotId,
            mapRevision = farmMap.revision, chunkIndex = chunkIndex,
            chunkCount = chunkCount, cells = chunk,
        }, JOB_PROTOCOL)
    end
    rednet.send(recipient, {
        type = "FARM_MAP_SNAPSHOT_END", controllerBootId = BOOT_ID,
        farmKey = farmKey, snapshotId = snapshotId,
        mapRevision = farmMap.revision, chunkCount = chunkCount,
    }, JOB_PROTOCOL)
    return true
end

local function sendFarmDelta(recipient, farmKey, farmMap, delta, baseRevision)
    delta = delta or {}
    local chunkCount = math.max(1, math.ceil(#delta / 32))
    for chunkIndex = 1, chunkCount do
        local chunk = {}
        local first = (chunkIndex - 1) * 32 + 1
        for index = first, math.min(first + 31, #delta) do chunk[#chunk + 1] = detachedCopy(delta[index]) end
        local data = farmMap.data or {}
        rednet.send(recipient, {
            type = "FARM_MAP_DELTA", controllerBootId = BOOT_ID,
            farmKey = farmKey, mapRevision = farmMap.revision,
            baseRevision = baseRevision,
            chunkIndex = chunkIndex, chunkCount = chunkCount, cells = chunk,
            metadata = {
                center = detachedCopy(data.center), radius = data.radius,
                phase = data.phase, knownColumns = data.knownColumns,
                autoExpand = data.autoExpand, summary = detachedCopy(data.summary),
            },
        }, JOB_PROTOCOL)
    end
end

local function storeFarmMap(value, fallbackId)
    if type(value) ~= "table" then return nil, false end
    local map = value.farmMap or value.map or value.terrain or value
    if type(map) ~= "table" then return nil, false end
    local key = map.farmId or map.siteId or map.id or fallbackId
    if not key then return nil, false end
    local previous = controllerState.farmMaps[key]
    local revision = tonumber(map.revision or map.mapRevision)
        or previous and (tonumber(previous.revision) or 0) + 1 or 1
    if previous and revision <= (tonumber(previous.revision) or 0) then return key, false end
    if previous then
        local loaded, loadError = loadFarmMap(key)
        if not loaded then return key, false, false, loadError end
        previous = loaded
    end
    local data = detachedCopy(map)
    local cells = {}
    if type(map.cells) ~= "table" then
        cells = previous and previous.data and detachedCopy(previous.data.cells) or {}
    end
    for _, cell in pairs(type(map.cells) == "table" and map.cells or map.delta or {}) do
        if type(cell) == "table" and type(cell.x) == "number"
            and type(cell.y) == "number" and type(cell.z) == "number" then
            cells[("%d:%d"):format(cell.x, cell.z)] = detachedCopy(cell)
        end
    end
    data.delta = nil
    data.cells = cells
    local candidate = {
        revision = revision,
        data = data,
        updatedAt = os.epoch("utc"),
    }
    local cellCount = 0
    for _ in pairs(cells) do cellCount = cellCount + 1 end
    data.knownColumns = cellCount
    local stored, storageError = storage.writeFarm(
        key, candidate, controllerState.terrainStorage[key]
    )
    if not stored then return key, false, false, storageError end
    controllerState.terrainStorage[key] = stored
    controllerState.farmMaps[key] = candidate
    return key, true, false
end

local function handleRemoteCommand(sender, message)
    if not activeRelays[sender] or message.source ~= sender then
        if message.requestId then
            rednet.send(sender, {
                type = "REMOTE_OUTPUT",
                requestId = message.requestId,
                text = "Relay is not registered with this controller.",
                controllerBootId = BOOT_ID,
            }, JOB_PROTOCOL)
        end
        return
    end
    registerRelay(sender)
    if message.requestId and controllerState.remoteCommands[message.requestId] then
        rednet.send(sender, {
            type = "REMOTE_OUTPUT", requestId = message.requestId,
            text = controllerState.remoteCommands[message.requestId],
            controllerBootId = BOOT_ID,
        }, JOB_PROTOCOL)
        return
    end
    local command = tostring(message.command or "")
    local tokens = {}
    for token in command:gmatch("%S+") do table.insert(tokens, token) end
    local name = string.lower(tokens[1] or "")
    local output
    if name == "turtles" then
        output = textutils.serialize(controllerState.turtles)
    elseif name == "jobs" then
        output = textutils.serialize(controllerState.jobs)
    elseif name == "sites" or name == "surveys" then
        output = textutils.serialize(controllerState[name])
    elseif name == "storage" then
        output = textutils.serialize(storage.describe())
    elseif name == "help" then
        output = "turtles | jobs | sites | surveys | storage | retry | cancel | travel | dig | repair | survey | farm-service | farm-expand | farm-radius | farm | tunnel | setup-* | help"
    elseif command ~= "" then
        local accepted, result = handleCommand(command, message.requestId and ("remote-" .. message.requestId))
        output = result or (accepted and "Command accepted." or "Command rejected.")
    else
        output = "Empty command."
    end
    if message.requestId then
        controllerState.remoteCommands[message.requestId] = output
        table.insert(controllerState.remoteCommandOrder, message.requestId)
        while #controllerState.remoteCommandOrder > 256 do
            local expired = table.remove(controllerState.remoteCommandOrder, 1)
            controllerState.remoteCommands[expired] = nil
        end
        saveState()
    end
    rednet.send(sender, {
        type = "REMOTE_OUTPUT", requestId = message.requestId, text = output,
        controllerBootId = BOOT_ID,
    }, JOB_PROTOCOL)
end

local function handleWorker(sender, message)
    if type(message) ~= "table" then return end
    if message.messageId and controllerState.processedReports[message.messageId] then
        rednet.send(sender, { type = "REPORT_ACK", messageId = message.messageId }, JOB_PROTOCOL)
        return
    end
    if message.type == "WORKER_HELLO" then
        local existing = controllerState.turtles[sender]
        local previousEntry = existing and detachedCopy(existing)
        local previousNextNumber = controllerState.nextTurtleNumber
        local previousStatus = existing and existing.status
        local name = existing and existing.name
        if not name then
            name = "turtle-" .. controllerState.nextTurtleNumber
            controllerState.nextTurtleNumber = controllerState.nextTurtleNumber + 1
        end
        controllerState.turtles[sender] = {
            id = sender, name = name, label = message.label, status = message.status,
            statusDetail = message.statusDetail,
            position = message.position, heading = message.heading, home = message.home,
            positionVerifiedAt = message.positionVerifiedAt,
            navigationReady = message.navigationReady,
            navigationError = message.navigationError,
            release = message.release,
            online = true,
            lastSeen = os.epoch("utc"),
        }
        if not saveState() then
            controllerState.turtles[sender] = previousEntry
            controllerState.nextTurtleNumber = previousNextNumber
            printError("Worker registration was rejected because controller state could not be saved")
            return
        end
        print(("%s online: %s"):format(name, tostring(message.status)))
        if actionableStatuses[message.status] and previousStatus ~= message.status and not message.resync then
            sendWorkerAlert(
                sender, name, message.status, message.statusDetail,
                ("hello-%s-%s-%s-%s"):format(
                    BOOT_ID, tostring(sender), tostring(message.status), tostring(message.sentAt)
                )
            )
            saveState()
        end
    elseif message.type == "WORKER_HEARTBEAT" then
        local turtleInfo = controllerState.turtles[sender]
        if not turtleInfo then
            printError("UNKNOWN_COMPUTER: heartbeat from " .. tostring(sender))
            rednet.send(sender, {
                type = "REGISTRATION_REQUIRED", controllerBootId = BOOT_ID,
            }, JOB_PROTOCOL)
            return
        end
        if message.controllerBootId ~= BOOT_ID or message.heartbeatNonce ~= currentHeartbeatNonce then return end
        turtleInfo.lastSeen = os.epoch("utc")
        turtleInfo.online = true
        turtleInfo.status = message.status or turtleInfo.status
        turtleInfo.release = type(message.release) == "string" and message.release or turtleInfo.release
        if type(message.position) == "table" then turtleInfo.position = detachedCopy(message.position) end
        if type(message.heading) == "string" then turtleInfo.heading = message.heading end
        if type(message.positionVerifiedAt) == "number" then
            turtleInfo.positionVerifiedAt = message.positionVerifiedAt
        end
        if type(message.navigationReady) == "boolean" then
            turtleInfo.navigationReady = message.navigationReady
        end
        for relayId in pairs(activeRelays) do
            rednet.send(relayId, {
                type = "TURTLE_UPDATE", controllerBootId = BOOT_ID,
                turtle = detachedCopy(turtleInfo),
            }, JOB_PROTOCOL)
        end
    elseif message.type then
        local turtleInfo = controllerState.turtles[sender]
        if not turtleInfo then
            printError("UNKNOWN_COMPUTER: message from " .. tostring(sender))
            rednet.send(sender, {
                type = "REGISTRATION_REQUIRED", controllerBootId = BOOT_ID,
            }, JOB_PROTOCOL)
            return
        end
        local previousStatus = turtleInfo.status
        if type(message.status) == "string" then turtleInfo.status = message.status end
        if type(message.position) == "table" then turtleInfo.position = detachedCopy(message.position) end
        if type(message.heading) == "string" then turtleInfo.heading = message.heading end
        if type(message.positionVerifiedAt) == "number" then
            turtleInfo.positionVerifiedAt = message.positionVerifiedAt
        end
        turtleInfo.lastMessageAt = os.epoch("utc")
        if type(message.release) == "string" then turtleInfo.release = message.release end
        controllerState.turtles[sender] = turtleInfo
        local rawPayload = message.payload
        local payload = type(rawPayload) == "table" and rawPayload or {}
        if message.type == "FARM_MAP" then
            local mapValue = type(rawPayload) == "table" and rawPayload
                or message.farmMap or message.map or message.terrain
            local mapData = type(mapValue) == "table"
                and (mapValue.farmMap or mapValue.map or mapValue.terrain or mapValue) or nil
            local sourceDelta = mapData and mapData.delta
            local candidateKey = mapData and (mapData.farmId or mapData.siteId or mapData.id)
            local baseRevision = candidateKey and controllerState.farmMaps[candidateKey]
                and controllerState.farmMaps[candidateKey].revision or 0
            local farmKey, changed, compacted, storageError = storeFarmMap(mapValue)
            if storageError then
                printError(("Terrain report was not acknowledged: %s"):format(tostring(storageError)))
                return
            end
            if changed then
                for relayId in pairs(activeRelays) do
                    if not compacted and type(sourceDelta) == "table" and #sourceDelta <= 128 then
                        sendFarmDelta(relayId, farmKey, controllerState.farmMaps[farmKey], sourceDelta, baseRevision)
                    else
                        sendFarmSnapshot(relayId, farmKey)
                    end
                end
                controllerState.farmMaps[farmKey].data.cells = nil
            end
        end
        if message.type == "FARM_3D_MAP" then
            local spatialValue = payload
            if type(spatialValue) ~= "table" or type(spatialValue.farmId) ~= "string"
                or type(spatialValue.chunks) ~= "table" or spatialValue.version ~= 2
                or type(spatialValue.origin) ~= "table"
                or type(spatialValue.origin.x) ~= "number" or type(spatialValue.origin.y) ~= "number"
                or type(spatialValue.origin.z) ~= "number" or type(spatialValue.radius) ~= "number" then
                printError("Invalid 3D terrain report; it was not acknowledged")
                return
            end
            for chunkKey, cells in pairs(spatialValue.chunks) do
                local savedSpatial, spatialError = spatialStorage.write({
                    farmId = spatialValue.farmId,
                    chunkKey = chunkKey,
                    revision = spatialValue.revision,
                    verifiedAt = spatialValue.verifiedAt,
                    changeCount = spatialValue.changeCount,
                    surveyVersion = spatialValue.version,
                    surveyOrigin = spatialValue.origin,
                    surveyRadius = spatialValue.radius,
                    cells = cells,
                })
                if not savedSpatial then
                    printError(("3D terrain report was not acknowledged: %s"):format(tostring(spatialError)))
                    return
                end
            end
            for relayId in pairs(activeRelays) do
                rednet.send(relayId, {
                    type = "FARM_3D_CHANGED", farmId = spatialValue.farmId,
                    revision = spatialValue.revision, controllerBootId = BOOT_ID,
                }, JOB_PROTOCOL)
            end
        end
        if actionableStatuses[message.status] or message.type == "JOB_FAILED" then
            turtleInfo.statusDetail = payload.reason
                or type(payload.result) == "string" and payload.result or turtleInfo.statusDetail
        else
            turtleInfo.statusDetail = nil
        end
        for relayId in pairs(activeRelays) do
            rednet.send(relayId, {
                type = "TURTLE_UPDATE", controllerBootId = BOOT_ID,
                turtle = detachedCopy(turtleInfo),
            }, JOB_PROTOCOL)
        end
        local job = payload.job
        local reportedJobId = job and job.id or payload.id
        if reportedJobId then
            controllerState.jobs[reportedJobId] = controllerState.jobs[reportedJobId] or { turtleId = sender }
            local existingStatus = controllerState.jobs[reportedJobId].status
            local terminal = existingStatus == "JOB_COMPLETE" or existingStatus == "JOB_FAILED"
                or existingStatus == "JOB_CANCELLED"
            if message.type == "JOB_STARTED" and existingStatus == "JOB_FAILED" then
                controllerState.jobs[reportedJobId].status = "JOB_STARTED"
            elseif message.type == "CONTROL_ACCEPTED" and payload.action == "retry"
                and existingStatus == "JOB_FAILED" then
                controllerState.jobs[reportedJobId].status = "RETRYING"
            elseif message.type == "CONTROL_ACCEPTED" and payload.action == "cancel"
                and existingStatus ~= "JOB_COMPLETE" then
                controllerState.jobs[reportedJobId].status = job and job.status == "CANCELLED"
                    and "JOB_CANCELLED" or "CANCEL_REQUESTED"
            elseif not terminal then
                controllerState.jobs[reportedJobId].status = message.type
            end
            controllerState.jobs[reportedJobId].result = payload.result or payload.reason
                or job and job.result
            local tracked = controllerState.jobs[reportedJobId]
            local result = payload.result or (job and job.result)
            if tracked.type == "SURVEY_AREA" and type(result) == "table" then
                controllerState.surveys[reportedJobId] = detachedCopy(result)
            elseif tracked.type == "CONFIGURE_SITE" and type(result) == "table"
                and type(result.node) == "table" and result.node.id then
                controllerState.sites[result.node.id] = detachedCopy(result.node)
            elseif tracked.type == "FARM_CROP" and type(result) == "table"
                and type(result.farm) == "table" and result.farm.id then
                controllerState.sites[result.farm.id] = detachedCopy(result.farm)
            end
            if tracked.type == "FARM_SERVICE" and type(result) == "table" then
                local _, _, _, storageError = storeFarmMap(
                    result.farmMap or result.map or result.terrain, reportedJobId
                )
                if storageError then
                    printError(("Farm result was not acknowledged: %s"):format(tostring(storageError)))
                    return
                end
            end
            if tracked.type == "FARM_CROP" and job and job.progress
                and type(job.progress.discoveredFarm) == "table" and job.progress.discoveredFarm.id then
                controllerState.sites[job.progress.discoveredFarm.id] = detachedCopy(job.progress.discoveredFarm)
            end
        end
        if (message.type == "CONTROL_ACCEPTED" or message.type == "CONTROL_REJECTED")
            and payload and type(payload.action) == "string"
            and payload.action:find("farm_", 1, true) == 1 then
            local text = ("%s %s: %s"):format(
                turtleInfo.name or ("turtle-" .. tostring(sender)),
                payload.action,
                tostring(payload.reason or (message.type == "CONTROL_ACCEPTED" and "accepted" or "rejected"))
            )
            for relayId in pairs(activeRelays) do
                rednet.send(relayId, {
                    type = "CONTROL_RESULT", text = text, controllerBootId = BOOT_ID,
                }, JOB_PROTOCOL)
            end
        end
        local workerName = turtleInfo.name or ("turtle-" .. tostring(sender))
        local lastError = payload and payload.lastError
        local detail = payload and (payload.reason or payload.result
            or type(lastError) == "table" and (lastError.message or lastError.code))
        local routineTerrainReport = message.type == "FARM_MAP" or message.type == "FARM_3D_MAP"
        if not routineTerrainReport then
            print(("%s: %s%s"):format(
                workerName,
                message.type,
                type(detail) == "string" and (" - " .. detail) or ""
            ))
        end
        if message.type == "JOB_FAILED" or message.type == "JOB_REJECTED"
            or (message.type == "WORKER_STATUS" and (actionableStatuses[message.status] or lastError)) then
            sendWorkerAlert(
                sender, workerName, message.status, detail or "job failed",
                message.messageId or ("event-%s-%s-%s"):format(
                    tostring(sender), tostring(message.type), tostring(message.sentAt)
                )
            )
        elseif message.type == "WORKER_UPDATING" then
            sendWorkerAlert(
                sender, workerName, "UPDATING", detail,
                message.messageId or ("updating-%s-%s"):format(tostring(sender), tostring(message.sentAt)),
                workerName .. " accepted an update and is rebooting"
            )
        elseif message.type == "WORKER_REBOOTED" then
            sendWorkerAlert(
                sender, workerName, "UPDATED", detail,
                message.messageId or ("updated-%s-%s"):format(tostring(sender), tostring(message.sentAt)),
                workerName .. " rebooted successfully with the update"
            )
        elseif message.type == "CONTROL_ACCEPTED" and payload
            and tostring(payload.action):find("retry", 1, true) then
            local text = payload.action == "retry"
                and (workerName .. " accepted an immediate retry")
                or (workerName .. " automatic retry is " .. tostring(payload.reason or "toggled"))
            sendWorkerAlert(
                sender, workerName, "RETRY", payload.reason,
                message.messageId or ("retry-%s-%s"):format(tostring(sender), tostring(message.sentAt)),
                text
            )
        elseif actionableStatuses[message.status] and previousStatus ~= message.status then
            sendWorkerAlert(
                sender, workerName, message.status, detail or message.status,
                message.messageId or ("status-%s-%s-%s"):format(
                    tostring(sender), tostring(message.status), tostring(message.sentAt)
                )
            )
        end
    end
    if message.messageId then
        controllerState.processedReports[message.messageId] = true
        table.insert(controllerState.processedReportOrder, message.messageId)
        while #controllerState.processedReportOrder > 512 do
            local expired = table.remove(controllerState.processedReportOrder, 1)
            controllerState.processedReports[expired] = nil
        end
    end
    local savedOk = saveState()
    if not savedOk then
        if message.messageId then
            controllerState.processedReports[message.messageId] = nil
            table.remove(controllerState.processedReportOrder)
        end
        printError("Controller state save failed; report was not acknowledged")
        return
    end
    if message.messageId then
        rednet.send(sender, { type = "REPORT_ACK", messageId = message.messageId }, JOB_PROTOCOL)
    end
end

if not openModems() then error("Mining controller requires an attached modem", 0) end
print(("Mining controller computer %d"):format(os.getComputerID()))
print("Network: " .. NETWORK_ID)
showHelp()
controllerHeartbeat()

local announceTimer = os.startTimer(15)
local playerTimer = os.startTimer(0.1)
local input = ""
write("controller> ")
while true do
    local event, first, second, third = os.pullEvent()
    if event == "monitor_resize" and refreshMonitor then
        refreshMonitor()
    elseif event == "char" then
        input = input .. first
        write(first)
    elseif event == "key" and first == keys.backspace and #input > 0 then
        input = input:sub(1, -2)
        local x, y = term.getCursorPos()
        term.setCursorPos(x - 1, y)
        write(" ")
        term.setCursorPos(x - 1, y)
    elseif event == "key" and first == keys.enter then
        print()
        handleCommand(input)
        input = ""
        write("controller> ")
    elseif event == "timer" and first == announceTimer then
        expireTurtleLeases()
        controllerHeartbeat()
        announceTimer = os.startTimer(15)
    elseif event == "timer" and first == playerTimer then
        pollTrackedPlayer()
        playerTimer = os.startTimer(0.2)
    elseif event == "rednet_message" and third == JOB_PROTOCOL then
        if type(second) == "table" and second.type == "CONTROLLER_QUERY" then
            controllerHello(first)
        elseif type(second) == "table" and second.type == "RELAY_HELLO"
            and second.source == first and second.controllerBootId == BOOT_ID then
            local previousRelay = controllerState.relays[first]
            registerRelay(first)
            if saveState() then
                local turtles, sites = completionSnapshot()
                rednet.send(first, {
                    type = "RELAY_ACK",
                    controllerBootId = BOOT_ID,
                    turtles = turtles,
                    turtleStates = relayTurtleStates(),
                    player = trackedPlayer and detachedCopy(trackedPlayer) or false,
                    sites = sites,
                    farmMapKeys = farmMapIndex(),
                }, JOB_PROTOCOL)
            else
                controllerState.relays[first] = previousRelay
                activeRelays[first] = previousRelay and true or nil
                printError("Relay registration rejected because controller state could not be saved")
            end
        elseif type(second) == "table" and second.type == "FARM_MAP_RESYNC_REQUEST"
            and second.source == first and second.controllerBootId == BOOT_ID
            and activeRelays[first] and type(second.farmKey) == "string" then
            sendFarmSnapshot(first, second.farmKey)
        elseif type(second) == "table" and second.type == "ALERT_SYNC_REQUEST"
            and second.source == first and second.controllerBootId == BOOT_ID
            and activeRelays[first] then
            local previousRelay = controllerState.relays[first]
            registerRelay(first)
            if saveState() then
                rednet.send(first, {
                    type = "ALERT_SYNC",
                    alerts = latestAlerts(10),
                    controllerBootId = BOOT_ID,
                }, JOB_PROTOCOL)
            else
                controllerState.relays[first] = previousRelay
                activeRelays[first] = previousRelay and true or nil
            end
        elseif type(second) == "table" and second.type == "REMOTE_COMMAND" then
            handleRemoteCommand(first, second)
        elseif type(second) == "table" and second.type == "FARM_ROUTE_REQUEST" then
            handleFarmRouteRequest(first, second)
        elseif type(second) == "table" and second.type == "ROUTE_REQUEST" then
            handleFarmRouteRequest(first, second)
        elseif type(second) == "table"
            and (second.type == "ROUTE_RELEASE" or second.type == "ROUTE_BLOCKED") then
            handleRouteControl(first, second)
        elseif type(second) == "table" and second.type == "FARM_TERRAIN_REQUEST" then
            handleFarmTerrainRequest(first, second)
        elseif type(second) == "table" and second.type == "FARM_3D_CHUNK_REQUEST" then
            handleFarmSpatialRequest(first, second)
        elseif type(second) == "table" and second.type == "FARM_3D_SURVEY_PLAN_REQUEST" then
            handleFarmSurveyPlanRequest(first, second)
        elseif type(second) == "table" and second.type == "FARM_3D_SLICE_REQUEST" then
            handleRelaySpatialSliceRequest(first, second)
        else
            handleWorker(first, second)
        end
    elseif event == "rednet_message" and third == DEPLOY_PROTOCOL and type(second) == "table"
        and second.type == "UPDATE_AVAILABLE" and second.project == "mining-bot"
        and second.target == "controller" and second.release ~= installedRelease() then
        os.queueEvent("bucky_deployment_update_ack", second.release)
        print("Controller update available; rebooting into updater.")
        sleep(1)
        os.reboot()
    elseif event == "rednet_message" and third == DEPLOY_PROTOCOL and type(second) == "table"
        and second.type == "UPDATE_AVAILABLE" and second.project == "mining-bot"
        and second.target == "turtle" and type(second.release) == "string"
        and second.release ~= announcedTurtleRelease then
        announcedTurtleRelease = second.release
        for turtleId in pairs(controllerState.turtles) do
            rednet.send(turtleId, {
                type = "CONTROL_JOB",
                action = "update",
                release = second.release,
            }, JOB_PROTOCOL)
        end
    elseif event == "bucky_deployment_update" and type(first) == "string"
        and first ~= installedRelease() then
        os.queueEvent("bucky_deployment_update_ack", first)
        print("Background updater found a controller release; rebooting into updater.")
        sleep(1)
        os.reboot()
    end
end
