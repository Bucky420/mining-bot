local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local arguments = { ... }
local NATIVE_TABS = arguments[1] == "native"
local PROTOCOL = NETWORK_ID .. "/deployment/v1"
local JOB_PROTOCOL = NETWORK_ID .. "/mining/v1"
local CACHE_ROOT = "/relay-cache"
local COMMAND_STATE = "/relay-commands.state"
local TIMEOUT = 8

local cache = {}
local masterId
local deferredEvents = {}
local relayState = {
    nextCommand = 1,
    pendingCommands = {},
    alertsEnabled = true,
    seenAlertIds = {},
    seenAlertOrder = {},
    alertControllerBootId = nil,
    farmMaps = {},
    ui = { zoom = 1, followPlayer = true },
}
local pendingCommands = relayState.pendingCommands

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
        monitor.setCursorPos(1, 1)
        for _, value in ipairs(history) do
            local text = tostring(value)
            repeat
                local line = text:sub(1, width)
                text = text:sub(width + 1)
                local _, y = monitor.getCursorPos()
                if y > height then monitor.scroll(1) y = height end
                monitor.setCursorPos(1, y)
                monitor.write(line)
                monitor.setCursorPos(1, y + 1)
            until text == ""
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

local function saveRelayState()
    local temporary = COMMAND_STATE .. ".tmp"
    local previous = COMMAND_STATE .. ".previous"
    if fs.exists(temporary) then fs.delete(temporary) end
    local handle = fs.open(temporary, "w")
    if not handle then return false end
    handle.write(textutils.serialize(relayState, { compact = true }))
    handle.close()
    if fs.exists(previous) then fs.delete(previous) end
    if fs.exists(COMMAND_STATE) then
        fs.copy(COMMAND_STATE, previous)
        fs.delete(COMMAND_STATE)
    end
    local moved = pcall(fs.move, temporary, COMMAND_STATE)
    if not moved then
        if fs.exists(COMMAND_STATE) then pcall(fs.delete, COMMAND_STATE) end
        if fs.exists(previous) then pcall(fs.copy, previous, COMMAND_STATE) end
        return false
    end
    if fs.exists(previous) then fs.delete(previous) end
    return true
end

local function loadRelayState()
    for _, path in ipairs({ COMMAND_STATE, COMMAND_STATE .. ".tmp", COMMAND_STATE .. ".previous" }) do
        if fs.exists(path) then
            local handle = fs.open(path, "r")
            if handle then
                local value = textutils.unserialize(handle.readAll())
                handle.close()
                if type(value) == "table" and type(value.pendingCommands) == "table" then
                    relayState = value
                    relayState.nextCommand = relayState.nextCommand or 1
                    if relayState.alertsEnabled == nil then relayState.alertsEnabled = true end
                    relayState.seenAlertIds = relayState.seenAlertIds or {}
                    relayState.seenAlertOrder = relayState.seenAlertOrder or {}
                    relayState.farmMaps = relayState.farmMaps or {}
                    relayState.ui = relayState.ui or { zoom = 1, followPlayer = true }
                    relayState.farmMaps = {}
                    pendingCommands = relayState.pendingCommands
                    return
                end
            end
        end
    end
end

local function nextCommandId()
    local id = ("remote-%d-%d"):format(os.getComputerID(), relayState.nextCommand)
    relayState.nextCommand = relayState.nextCommand + 1
    return id
end

local function nextEvent()
    if #deferredEvents > 0 then
        local event = table.remove(deferredEvents, 1)
        return event[1], event[2], event[3], event[4]
    end
    return os.pullEvent()
end

local function deferEvent(event, first, second, third)
    table.insert(deferredEvents, { event, first, second, third })
end

local function validName(value)
    return type(value) == "string" and value:match("^[%w_.-]+$") ~= nil
end

local function validPath(path)
    return type(path) == "string" and path ~= "" and path:sub(1, 1) ~= "/"
        and not path:find("..", 1, true) and not path:find("\\", 1, true)
end

local function openModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            return true
        end
    end
    return false
end

local function nonce(label)
    return ("relay-%d-%d-%s"):format(os.getComputerID(), os.epoch("utc"), label or "")
end

local function cacheKey(project, target)
    return project .. "/" .. target
end

local function saveCacheFile(project, target, path, contents, root)
    root = root or CACHE_ROOT
    local destination = fs.combine(fs.combine(fs.combine(root, project), target), path)
    local parent = fs.getDir(destination)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle = fs.open(destination, "w")
    if not handle then return false end
    handle.write(contents)
    handle.close()
    return true
end

local function saveCacheManifest(project, target, entry, root)
    root = root or CACHE_ROOT
    local path = fs.combine(fs.combine(fs.combine(root, project), target), ".manifest")
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(textutils.serialize({ release = entry.release, manifest = entry.manifest }))
    handle.close()
    return true
end

local function recoverCacheTransactions()
    local backupRoot = fs.combine(CACHE_ROOT, ".backup")
    if not fs.exists(backupRoot) then return end
    for _, project in ipairs(fs.list(backupRoot)) do
        local projectBackup = fs.combine(backupRoot, project)
        if fs.isDir(projectBackup) then
            for _, target in ipairs(fs.list(projectBackup)) do
                local backup = fs.combine(projectBackup, target)
                local live = fs.combine(fs.combine(CACHE_ROOT, project), target)
                if fs.isDir(backup) then
                    if not fs.exists(live) then
                        local parent = fs.getDir(live)
                        if not fs.exists(parent) then fs.makeDir(parent) end
                        fs.move(backup, live)
                    else
                        fs.delete(backup)
                    end
                end
            end
        end
    end
end

local function loadCachedTargets()
    if not fs.exists(CACHE_ROOT) then return end
    for _, project in ipairs(fs.list(CACHE_ROOT)) do
        local projectPath = fs.combine(CACHE_ROOT, project)
        if validName(project) and fs.isDir(projectPath) then
            for _, target in ipairs(fs.list(projectPath)) do
                local manifestPath = fs.combine(fs.combine(projectPath, target), ".manifest")
                if validName(target) and fs.exists(manifestPath) then
                    local handle = fs.open(manifestPath, "r")
                    if handle then
                        local value = textutils.unserialize(handle.readAll())
                        handle.close()
                        if type(value) == "table" and type(value.release) == "string"
                            and type(value.manifest) == "table" then
                            cache[cacheKey(project, target)] = {
                                release = value.release, manifest = value.manifest, files = {},
                            }
                        end
                    end
                end
            end
        end
    end
end

local function loadCacheFile(project, target, path)
    local source = fs.combine(fs.combine(fs.combine(CACHE_ROOT, project), target), path)
    if not fs.exists(source) then return nil end
    local handle = fs.open(source, "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function receiveMaster(requestNonce)
    local timer = os.startTimer(TIMEOUT)
    while true do
        local event, sender, message, protocol = os.pullEvent()
        if event == "timer" and sender == timer then
            return nil, "master request timed out"
        end
        if event == "rednet_message" and sender == masterId and protocol == PROTOCOL
            and type(message) == "table" and message.nonce == requestNonce then
            if message.type == "ERROR" then return nil, message.error end
            return message
        end
        if event == "rednet_message" or event == "file_transfer" then
            deferEvent(event, sender, message, protocol)
        elseif event == "char" or event == "key" then
            deferEvent(event, sender, message, protocol)
        end
    end
end

local function discoverMaster()
    local requestNonce = nonce("discover")
    rednet.broadcast({
        type = "DISCOVER_AUTHORITY", nonce = requestNonce,
    }, PROTOCOL)
    local timer = os.startTimer(TIMEOUT)
    local offers = {}
    while true do
        local event, sender, message, protocol = os.pullEvent()
        if event == "timer" and sender == timer then
            local found, authority
            for id, offer in pairs(offers) do
                if offer.authority then authority = id end
                found = found or id
            end
            if authority then found = authority end
            if not found then return nil, "deployment master is offline" end
            masterId = found
            return found
        end
        if event == "rednet_message" and protocol == PROTOCOL and type(message) == "table"
            and message.type == "AUTHORITY_OFFER" and message.nonce == requestNonce
            and message.authority == true then
            if next(offers) == nil then timer = os.startTimer(1) end
            offers[sender] = message
        elseif event == "rednet_message" or event == "file_transfer"
            or event == "char" or event == "key" then
            deferEvent(event, sender, message, protocol)
        end
    end
end

local function ensureMaster()
    if masterId then return masterId end
    return discoverMaster()
end

local function requestMaster(request)
    local project, target = request.project, request.target
    if not validName(project) or not validName(target) then return nil, "invalid target" end
    local server, masterError = ensureMaster()
    if not server then return nil, masterError end
    request.nonce = nonce(request.type)
    rednet.send(server, request, PROTOCOL)
    local response, responseError = receiveMaster(request.nonce)
    if not response and responseError == "master request timed out" then
        masterId = nil
    end
    return response, responseError
end

local function syncTarget(project, target)
    local manifest, manifestError = requestMaster({
        type = "GET_MANIFEST", project = project, target = target,
    })
    if not manifest then return false, manifestError end
    local existing = cache[cacheKey(project, target)]
    if existing and existing.release == manifest.release then
        return true, existing
    end
    local entry = { release = manifest.release, manifest = manifest.files, files = {} }
    local stageRoot = fs.combine(CACHE_ROOT, ".stage")
    local stageTarget = fs.combine(fs.combine(stageRoot, project), target)
    local liveTarget = fs.combine(fs.combine(CACHE_ROOT, project), target)
    local backupTarget = fs.combine(fs.combine(fs.combine(CACHE_ROOT, ".backup"), project), target)
    if fs.exists(stageTarget) then fs.delete(stageTarget) end
    if not fs.exists(stageTarget) then fs.makeDir(stageTarget) end
    for index, fileEntry in ipairs(manifest.files or {}) do
        local response, fileError = requestMaster({
            type = "GET_FILE", project = project, target = target, path = fileEntry.path,
        })
        if not response then return false, fileError end
        if response.release ~= manifest.release or response.path ~= fileEntry.path
            or type(response.contents) ~= "string" or #response.contents ~= fileEntry.size then
            return false, "master changed revision during relay sync"
        end
        entry.files[fileEntry.path] = response.contents
        local savedFile = saveCacheFile(project, target, fileEntry.path, response.contents, stageRoot)
        if not savedFile then
            fs.delete(stageTarget)
            return false, "unable to write relay cache"
        end
        print(("Cached %s/%s file %d/%d"):format(project, target, index, #manifest.files))
    end
    if not saveCacheManifest(project, target, entry, stageRoot) then
        fs.delete(stageTarget)
        return false, "unable to write relay cache manifest"
    end
    if fs.exists(backupTarget) then fs.delete(backupTarget) end
    local backupParent = fs.getDir(backupTarget)
    if not fs.exists(backupParent) then fs.makeDir(backupParent) end
    if fs.exists(liveTarget) then fs.move(liveTarget, backupTarget) end
    fs.move(stageTarget, liveTarget)
    if fs.exists(backupTarget) then fs.delete(backupTarget) end
    cache[cacheKey(project, target)] = entry
    return true, entry
end

local function getTarget(project, target)
    local entry = cache[cacheKey(project, target)]
    if entry then return entry end
    local ok, synced = syncTarget(project, target)
    if not ok then return nil, synced end
    return synced
end

local function handleClient(sender, request)
    if type(request) ~= "table" or not validName(request.project) or not validName(request.target) then
        return
    end
    local entry, targetError = getTarget(request.project, request.target)
    if not entry then
        rednet.send(sender, {
            type = "ERROR", nonce = request.nonce, error = targetError,
        }, PROTOCOL)
        return
    end
    if request.type == "DISCOVER" then
        rednet.send(sender, {
            type = "OFFER", nonce = request.nonce, project = request.project,
            target = request.target, release = entry.release, serverId = os.getComputerID(),
            authority = false, authorityId = masterId,
        }, PROTOCOL)
    elseif request.type == "GET_MANIFEST" then
        rednet.send(sender, {
            type = "MANIFEST", nonce = request.nonce, project = request.project,
            target = request.target, release = entry.release, files = entry.manifest,
        }, PROTOCOL)
    elseif request.type == "GET_FILE" and validPath(request.path) then
        local contents = entry.files[request.path] or loadCacheFile(request.project, request.target, request.path)
        if contents then
            rednet.send(sender, {
                type = "FILE", nonce = request.nonce, release = entry.release,
                path = request.path, contents = contents,
            }, PROTOCOL)
        end
    end
end

local controllerId
local controllerBootId
local controllerRegistered = false
local input = ""
local promptVisible = false
local promptStartY
local recentAlertSemantics = {}
local completionTurtles = {}
local completionSites = {}
local commandHistory = {}
local historyIndex
local historyDraft = ""
local tabCycle
local baseTerminal
local commandWindow
local activeTab = "command"
local liveFarmMaps = {}
local turtleStates = {}
local mapSnapshots = {}
local mapDeltas = {}
local playerPosition
local mapCenter = { x = 0, z = 0 }
local mapMessage = "Waiting for map data"
local gpsTimer
local viewHeading = "north"
local previousGpsPosition
local playerHeadingAt

local function terminalSize()
    if baseTerminal then return baseTerminal.getSize() end
    return term.getSize()
end

local function mapZoom()
    local zoom = tonumber(relayState.ui.zoom) or 1
    return math.max(1, math.min(16, zoom))
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

local function headingFromYaw(yaw)
    yaw = yaw % 360
    if yaw < 45 or yaw >= 315 then return "south" end
    if yaw < 135 then return "west" end
    if yaw < 225 then return "north" end
    return "east"
end

local function finitePlayerNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
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
    playerPosition = { x = x, y = y, z = z, at = os.epoch("utc") }
end

local function applyControllerPlayer(player)
    if player == false then
        playerHeadingAt = nil
        return false
    end
    if type(player) ~= "table" or not finitePlayerNumber(player.x)
        or not finitePlayerNumber(player.y) or not finitePlayerNumber(player.z)
        or not finitePlayerNumber(player.yaw) then return false end
    playerPosition = { x = player.x, y = player.y, z = player.z, at = os.epoch("utc") }
    previousGpsPosition = { x = player.x, z = player.z }
    viewHeading = headingFromYaw(player.yaw)
    playerHeadingAt = os.epoch("utc")
    if relayState.ui.followPlayer then mapCenter.x, mapCenter.z = player.x, player.z end
    mapMessage = "Controller yaw"
    return true
end

local function terrainColor(cell)
    local class = cell.class
    if cell.occupant then
        if cell.occupant:find("leaves", 1, true) or cell.occupant:find("log", 1, true) then
            return colors.green
        end
        return colors.lime
    end
    if class == "water" then return colors.blue end
    if class == "grass" then return colors.green end
    if class == "farmland" then return colors.brown end
    if class == "dirt" then return colors.orange end
    if class == "sand" then return colors.yellow end
    if class == "stone" then return colors.lightGray end
    if class == "tree_log" then return colors.brown end
    if class == "tree_leaves" then return colors.lime end
    if class == "fence" or class == "hard" or class == "unknown" then return colors.gray end
    return colors.lightGray
end

local function writeBase(x, y, text, foreground, background)
    if not baseTerminal then return end
    baseTerminal.setCursorPos(x, y)
    if foreground then baseTerminal.setTextColor(foreground) end
    if background then baseTerminal.setBackgroundColor(background) end
    baseTerminal.write(text)
    baseTerminal.setTextColor(colors.white)
    baseTerminal.setBackgroundColor(colors.black)
end

local function writePixelBase(x, y, color)
    writeBase(x, y, " ", colors.white, color)
end

local function drawTabHeader()
    if not baseTerminal then return end
    local width = terminalSize()
    baseTerminal.setCursorPos(1, 1)
    baseTerminal.setBackgroundColor(colors.gray)
    baseTerminal.setTextColor(colors.white)
    baseTerminal.clearLine()
    writeBase(1, 1, " CMD ", colors.white,
        activeTab == "command" and colors.blue or colors.gray)
    writeBase(7, 1, " MAP ", colors.white,
        activeTab == "map" and colors.blue or colors.gray)
    if activeTab == "map" and width >= 20 then
        writeBase(width - 10, 1, " - ", colors.white, colors.gray)
        writeBase(width - 6, 1, " + ", colors.white, colors.gray)
        writeBase(width - 2, 1, relayState.ui.followPlayer and "F" or "P",
            relayState.ui.followPlayer and colors.lime or colors.white, colors.gray)
    end
end

local function chooseInitialCenter()
    if relayState.ui.followPlayer and playerPosition then
        mapCenter.x, mapCenter.z = playerPosition.x, playerPosition.z
        return
    end
    if mapCenter.x ~= 0 or mapCenter.z ~= 0 then return end
    for _, farmMap in pairs(liveFarmMaps) do
        local center = farmMap.data and farmMap.data.center
        if center then mapCenter.x, mapCenter.z = center.x, center.z return end
    end
    for _, turtleInfo in pairs(turtleStates) do
        if turtleInfo.position then
            mapCenter.x, mapCenter.z = turtleInfo.position.x, turtleInfo.position.z
            return
        end
    end
end

local function renderMap()
    if activeTab ~= "map" or not baseTerminal then return end
    chooseInitialCenter()
    local width, height = terminalSize()
    local top, bottom = 2, height - 1
    local contentHeight = math.max(1, bottom - top + 1)
    baseTerminal.setBackgroundColor(colors.black)
    baseTerminal.setTextColor(colors.white)
    for y = top, height do
        baseTerminal.setCursorPos(1, y)
        baseTerminal.clearLine()
    end
    local zoom = mapZoom()
    for _, farmMap in pairs(liveFarmMaps) do
        for _, cell in pairs(farmMap.data and farmMap.data.cells or {}) do
            local viewX, viewY = viewDelta(cell.x - mapCenter.x, cell.z - mapCenter.z)
            local screenX = math.floor(viewX / zoom + width / 2 + 0.5)
            local screenY = math.floor(viewY / zoom + contentHeight / 2 + top)
            if screenX >= 1 and screenX <= width and screenY >= top and screenY <= bottom then
                writePixelBase(screenX, screenY, terrainColor(cell))
            end
        end
    end
    local nearestName, nearestDistance
    for _, turtleInfo in pairs(turtleStates) do
        local position = turtleInfo.position
        if position then
            local distance = math.floor(math.sqrt(
                (position.x - mapCenter.x) ^ 2 + (position.z - mapCenter.z) ^ 2
            ) + 0.5)
            if not nearestDistance or distance < nearestDistance then
                nearestName, nearestDistance = turtleInfo.name or ("T" .. tostring(turtleInfo.id)), distance
            end
            local viewX, viewY = viewDelta(position.x - mapCenter.x, position.z - mapCenter.z)
            local rawX = math.floor(viewX / zoom + width / 2 + 0.5)
            local rawY = math.floor(viewY / zoom + contentHeight / 2 + top)
            local onScreen = rawX >= 1 and rawX <= width and rawY >= top and rawY <= bottom
            local screenX = math.max(1, math.min(width, rawX))
            local screenY = math.max(top, math.min(bottom, rawY))
            local stale = turtleInfo.lastSeen
                and os.epoch("utc") - turtleInfo.lastSeen > 60000
            writePixelBase(screenX, screenY,
                stale and colors.lightGray or onScreen and colors.orange or colors.red)
        end
    end
    if playerPosition then
        local viewX, viewY = viewDelta(playerPosition.x - mapCenter.x, playerPosition.z - mapCenter.z)
        local screenX = math.floor(viewX / zoom + width / 2 + 0.5)
        local screenY = math.floor(viewY / zoom + contentHeight / 2 + top)
        if screenX >= 1 and screenX <= width and screenY >= top and screenY <= bottom then
            writePixelBase(screenX, screenY, colors.cyan)
        end
    end
    local status = ("%s z%d UP:%s %d,%d"):format(
        relayState.ui.followPlayer and "FOLLOW" or "PAN", zoom,
        viewHeading:sub(1, 1):upper(),
        math.floor(mapCenter.x), math.floor(mapCenter.z)
    )
    if nearestName and #status < width then
        status = status .. (" %s:%d"):format(tostring(nearestName), nearestDistance)
    end
    if #status < width then status = status .. " " .. tostring(mapMessage) end
    writeBase(1, height, status:sub(1, width), colors.white, colors.black)
    drawTabHeader()
end

local function switchTab(tab)
    if tab ~= "command" and tab ~= "map" then return end
    activeTab = tab
    promptVisible = false
    if commandWindow then commandWindow.setVisible(tab == "command") end
    drawTabHeader()
    if tab == "map" then renderMap() end
end

local function setZoom(value)
    relayState.ui.zoom = math.max(1, math.min(16, value))
    saveRelayState()
    renderMap()
end

local function panMap(dx, dz)
    relayState.ui.followPlayer = false
    local step = mapZoom() * 2
    local worldX, worldZ = worldDelta(dx * step, dz * step)
    mapCenter.x, mapCenter.z = mapCenter.x + worldX, mapCenter.z + worldZ
    saveRelayState()
    renderMap()
end

local function clearPrompt()
    if activeTab ~= "command" then return end
    if not promptVisible then return end
    local _, currentY = term.getCursorPos()
    local startY = math.min(promptStartY or currentY, currentY)
    for y = startY, currentY do
        term.setCursorPos(1, y)
        term.clearLine()
    end
    term.setCursorPos(1, startY)
end

local function drawPrompt(value)
    if activeTab ~= "command" then return end
    local _, y = term.getCursorPos()
    promptStartY = y
    write("relay> " .. value)
end

local function redrawPrompt()
    if promptVisible then drawPrompt(input) end
end

local function printAsync(value, isError)
    if activeTab == "map" then
        mapMessage = tostring(value)
        renderMap()
        return
    end
    clearPrompt()
    if isError then printError(value) else print(value) end
    redrawPrompt()
end

local function rememberAlert(alert)
    local id = alert.id or alert.alertId
    if not id then
        id = table.concat({ tostring(alert.turtleId), tostring(alert.status), tostring(alert.at), tostring(alert.text) }, ":")
    end
    local semanticId = table.concat({
        "semantic", tostring(alert.turtleId), tostring(alert.status), tostring(alert.text),
    }, ":")
    local now = os.epoch("utc")
    if relayState.seenAlertIds[id]
        or (recentAlertSemantics[semanticId] and now - recentAlertSemantics[semanticId] < 5000) then
        return false
    end
    relayState.seenAlertIds[id] = true
    recentAlertSemantics[semanticId] = now
    table.insert(relayState.seenAlertOrder, id)
    while #relayState.seenAlertOrder > 200 do
        relayState.seenAlertIds[table.remove(relayState.seenAlertOrder, 1)] = nil
    end
    return true
end

local function requestAlertSync()
    if relayState.alertsEnabled and controllerId and controllerRegistered then
        rednet.send(controllerId, {
            type = "ALERT_SYNC_REQUEST",
            source = os.getComputerID(),
            controllerBootId = controllerBootId,
        }, JOB_PROTOCOL)
    end
end

local function requestFarmSnapshot(farmKey)
    if NATIVE_TABS or not controllerId or not controllerRegistered or type(farmKey) ~= "string" then return end
    for key, pending in pairs(mapDeltas) do
        if pending.farmKey == farmKey then mapDeltas[key] = nil end
    end
    rednet.send(controllerId, {
        type = "FARM_MAP_RESYNC_REQUEST", source = os.getComputerID(),
        controllerBootId = controllerBootId, farmKey = farmKey,
        haveRevision = liveFarmMaps[farmKey] and liveFarmMaps[farmKey].revision or 0,
    }, JOB_PROTOCOL)
end

local function requestFarmIndex(index)
    local indexed = {}
    for _, entry in ipairs(index or {}) do
        if type(entry) == "table" and type(entry.farmKey) == "string" then
            indexed[entry.farmKey] = true
            local localMap = liveFarmMaps[entry.farmKey]
            if not localMap or tonumber(localMap.revision) ~= tonumber(entry.revision) then
                requestFarmSnapshot(entry.farmKey)
            end
        end
    end
    for farmKey in pairs(liveFarmMaps) do
        if not indexed[farmKey] then
            liveFarmMaps[farmKey] = nil
            mapSnapshots[farmKey] = nil
            for key, pending in pairs(mapDeltas) do
                if pending.farmKey == farmKey then mapDeltas[key] = nil end
            end
        end
    end
    for farmKey in pairs(mapSnapshots) do
        if not indexed[farmKey] then mapSnapshots[farmKey] = nil end
    end
    for key, pending in pairs(mapDeltas) do
        if not indexed[pending.farmKey] then mapDeltas[key] = nil end
    end
end

local function finiteMapNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function validMapCell(cell)
    return type(cell) == "table" and finiteMapNumber(cell.x) and finiteMapNumber(cell.y)
        and finiteMapNumber(cell.z) and cell.x % 1 == 0 and cell.y % 1 == 0
        and cell.z % 1 == 0 and type(cell.name) == "string" and #cell.name <= 128
end

local function safeMapCell(cell)
    if not validMapCell(cell) then return nil end
    return {
        x = cell.x, y = cell.y, z = cell.z, name = cell.name,
        class = type(cell.class) == "string" and cell.class:sub(1, 128) or nil,
        occupant = type(cell.occupant) == "string" and cell.occupant:sub(1, 128) or nil,
    }
end

local function safeMapMetadata(metadata)
    metadata = type(metadata) == "table" and metadata or {}
    local result = {
        phase = type(metadata.phase) == "string" and metadata.phase or nil,
        radius = finiteMapNumber(metadata.radius) and metadata.radius or nil,
        knownColumns = finiteMapNumber(metadata.knownColumns) and metadata.knownColumns or nil,
        autoExpand = type(metadata.autoExpand) == "boolean" and metadata.autoExpand or nil,
    }
    if type(metadata.center) == "table" and finiteMapNumber(metadata.center.x)
        and finiteMapNumber(metadata.center.y) and finiteMapNumber(metadata.center.z) then
        result.center = { x = metadata.center.x, y = metadata.center.y, z = metadata.center.z }
    end
    return result
end

local function safeTurtleStates(source)
    local result, count = {}, 0
    for id, turtleInfo in pairs(type(source) == "table" and source or {}) do
        if count >= 128 then break end
        local position = type(turtleInfo) == "table" and turtleInfo.position
        local turtleId = type(turtleInfo) == "table" and (turtleInfo.id or id) or nil
        local validId = finiteMapNumber(turtleId)
            or type(turtleId) == "string" and #turtleId <= 32
        if validId and type(position) == "table" and finiteMapNumber(position.x)
            and finiteMapNumber(position.y) and finiteMapNumber(position.z) then
            local headings = { north = true, east = true, south = true, west = true }
            result[turtleId] = {
                id = turtleId,
                name = type(turtleInfo.name) == "string" and turtleInfo.name:sub(1, 32) or nil,
                heading = headings[turtleInfo.heading] and turtleInfo.heading or nil,
                lastSeen = finiteMapNumber(turtleInfo.lastSeen) and turtleInfo.lastSeen or nil,
                online = type(turtleInfo.online) == "boolean" and turtleInfo.online or nil,
                release = type(turtleInfo.release) == "string" and turtleInfo.release:sub(1, 128) or nil,
                position = { x = position.x, y = position.y, z = position.z },
            }
            count = count + 1
        end
    end
    return result
end

local function cachedCellCount()
    local count = 0
    for _, farmMap in pairs(liveFarmMaps) do
        for _ in pairs(farmMap.data and farmMap.data.cells or {}) do count = count + 1 end
    end
    return count
end

local function prunePendingMaps(collection, maximum)
    local now, count, oldestKey, oldestAt = os.epoch("utc"), 0
    local removed = {}
    for key, pending in pairs(collection) do
        local createdAt = pending.createdAt or now
        if now - createdAt > 30000 then
            collection[key] = nil
            removed[#removed + 1] = pending.farmKey
        else
            count = count + 1
            if not oldestAt or createdAt < oldestAt then
                oldestKey, oldestAt = key, createdAt
            end
        end
    end
    if count >= maximum and oldestKey then
        removed[#removed + 1] = collection[oldestKey].farmKey
        collection[oldestKey] = nil
    end
    return removed
end

local function applySnapshotChunk(message)
    local pending = mapSnapshots[message.farmKey]
    if not pending or pending.snapshotId ~= message.snapshotId
        or message.chunkCount ~= pending.chunkCount
        or type(message.chunkIndex) ~= "number" or message.chunkIndex < 1
        or message.chunkIndex > pending.chunkCount or type(message.cells) ~= "table"
        or #message.cells > 32 then return end
    local cells = {}
    for _, cell in ipairs(message.cells) do
        local safeCell = safeMapCell(cell)
        if safeCell then cells[#cells + 1] = safeCell end
    end
    pending.chunks[message.chunkIndex] = cells
end

local function finishSnapshot(message)
    local pending = mapSnapshots[message.farmKey]
    if not pending or pending.snapshotId ~= message.snapshotId then return end
    if message.chunkCount ~= pending.chunkCount or message.mapRevision ~= pending.revision then
        mapSnapshots[message.farmKey] = nil
        requestFarmSnapshot(message.farmKey)
        return
    end
    local cells, receivedCount, uniqueCount = {}, 0, 0
    for chunkIndex = 1, pending.chunkCount do
        local chunk = pending.chunks[chunkIndex]
        if not chunk then
            mapSnapshots[message.farmKey] = nil
            requestFarmSnapshot(message.farmKey)
            return
        end
        for _, cell in ipairs(chunk) do
            local key = ("%d:%d"):format(cell.x, cell.z)
            receivedCount = receivedCount + 1
            if not cells[key] then uniqueCount = uniqueCount + 1 end
            cells[key] = cell
        end
    end
    local replacedCount = 0
    local replaced = liveFarmMaps[message.farmKey]
    for _ in pairs(replaced and replaced.data and replaced.data.cells or {}) do replacedCount = replacedCount + 1 end
    local total = cachedCellCount() - replacedCount + uniqueCount
    if receivedCount ~= pending.cellCount or uniqueCount ~= pending.cellCount
        or uniqueCount > 4096 or total > 8192 then
        mapSnapshots[message.farmKey] = nil
        mapMessage = "Invalid or oversized map snapshot"
        return
    end
    pending.metadata.cells = cells
    if not liveFarmMaps[message.farmKey] then
        local mapCount, oldestKey, oldestAt = 0
        for farmKey, farmMap in pairs(liveFarmMaps) do
            mapCount = mapCount + 1
            if not oldestAt or (farmMap.syncedAt or 0) < oldestAt then
                oldestKey, oldestAt = farmKey, farmMap.syncedAt or 0
            end
        end
        if mapCount >= 32 and oldestKey then liveFarmMaps[oldestKey] = nil end
    end
    liveFarmMaps[message.farmKey] = {
        revision = pending.revision, data = pending.metadata, syncedAt = os.epoch("utc"),
    }
    mapSnapshots[message.farmKey] = nil
    mapMessage = ("Map %s synced"):format(tostring(message.farmKey))
    renderMap()
end

local function applyFarmDelta(message)
    local current = liveFarmMaps[message.farmKey]
    if not current then requestFarmSnapshot(message.farmKey) return end
    local revision = tonumber(message.mapRevision)
    local currentRevision = tonumber(current.revision) or 0
    local baseRevision = tonumber(message.baseRevision)
    if not revision or revision <= currentRevision then return end
    if (baseRevision and baseRevision ~= currentRevision)
        or (not baseRevision and revision ~= currentRevision + 1) then
        requestFarmSnapshot(message.farmKey)
        return
    end
    if type(message.chunkCount) ~= "number" or message.chunkCount < 1
        or message.chunkCount > 4 or message.chunkCount % 1 ~= 0
        or type(message.chunkIndex) ~= "number" or message.chunkIndex % 1 ~= 0
        or message.chunkIndex < 1 or message.chunkIndex > message.chunkCount
        or type(message.cells) ~= "table" or #message.cells > 32 then return end
    prunePendingMaps(mapDeltas, 16)
    local deltaKey = tostring(message.farmKey) .. ":" .. tostring(revision)
    local pending = mapDeltas[deltaKey] or {
        farmKey = message.farmKey, revision = revision, baseRevision = baseRevision,
        chunkCount = message.chunkCount, chunks = {}, metadata = safeMapMetadata(message.metadata),
        createdAt = os.epoch("utc"),
    }
    if pending.chunkCount ~= message.chunkCount or pending.baseRevision ~= baseRevision then
        mapDeltas[deltaKey] = nil
        requestFarmSnapshot(message.farmKey)
        return
    end
    local cells = {}
    for _, cell in ipairs(message.cells) do
        local safeCell = safeMapCell(cell)
        if safeCell then cells[#cells + 1] = safeCell end
    end
    pending.chunks[message.chunkIndex] = cells
    mapDeltas[deltaKey] = pending
    for chunkIndex = 1, pending.chunkCount do if not pending.chunks[chunkIndex] then return end end
    current.data = current.data or { cells = {} }
    current.data.cells = current.data.cells or {}
    local additions = {}
    for chunkIndex = 1, pending.chunkCount do
        for _, cell in ipairs(pending.chunks[chunkIndex]) do
            local key = ("%d:%d"):format(cell.x, cell.z)
            if not current.data.cells[key] then additions[key] = true end
        end
    end
    local additionCount = 0
    for _ in pairs(additions) do additionCount = additionCount + 1 end
    if cachedCellCount() + additionCount > 8192 then
        mapDeltas[deltaKey] = nil
        mapMessage = "Map cache limit reached"
        return
    end
    for chunkIndex = 1, pending.chunkCount do
        for _, cell in ipairs(pending.chunks[chunkIndex]) do
            if validMapCell(cell) then current.data.cells[("%d:%d"):format(cell.x, cell.z)] = cell end
        end
    end
    for field, value in pairs(pending.metadata) do current.data[field] = value end
    current.revision = pending.revision
    mapDeltas[deltaKey] = nil
    mapMessage = ("Map r%s"):format(tostring(current.revision))
    renderMap()
end

local function toggleAlerts(argument)
    local value = string.lower(argument or "")
    if value == "on" then relayState.alertsEnabled = true
    elseif value == "off" then relayState.alertsEnabled = false
    elseif value == "" or value == "toggle" then relayState.alertsEnabled = not relayState.alertsEnabled
    elseif value ~= "status" then
        printError("Usage: alerts [on|off|status]")
        return
    end
    if not saveRelayState() then printError("Could not save alert preference") end
    print("Alerts " .. (relayState.alertsEnabled and "enabled" or "disabled"))
    if relayState.alertsEnabled then requestAlertSync() end
end

local function sendControllerCommand(command)
    local queued = {
        id = nextCommandId(),
        command = command,
    }
    table.insert(pendingCommands, queued)
    if not saveRelayState() then
        table.remove(pendingCommands)
        printError("Command was not sent because the relay queue could not be saved.")
        return
    end
    if not controllerId or not controllerRegistered then
        rednet.broadcast({ type = "CONTROLLER_QUERY", source = os.getComputerID() }, JOB_PROTOCOL)
        print("Waiting for mining controller...")
        return
    end
    rednet.send(controllerId, {
        type = "REMOTE_COMMAND", requestId = queued.id,
        command = queued.command, source = os.getComputerID(),
    }, JOB_PROTOCOL)
end

local function handleControllerMessage(sender, message)
    if type(message) ~= "table" then return end
    if NATIVE_TABS and (message.type == "PLAYER_UPDATE" or message.type == "TURTLE_UPDATE"
        or tostring(message.type):find("^FARM_MAP_")) then return end
    if message.type == "CONTROLLER_HELLO" then
        if message.controllerId ~= sender then return end
        if controllerId and sender ~= controllerId then return end
        local changed = controllerId ~= sender or controllerBootId ~= message.bootId
        if changed then
            liveFarmMaps, mapSnapshots, mapDeltas = {}, {}, {}
            mapMessage = "Controller changed; syncing maps"
        end
        if relayState.alertControllerBootId ~= message.bootId then
            relayState.alertControllerBootId = message.bootId
            relayState.seenAlertIds = {}
            relayState.seenAlertOrder = {}
            recentAlertSemantics = {}
            saveRelayState()
        end
        controllerId = sender
        controllerBootId = message.bootId
        completionTurtles = type(message.turtles) == "table" and message.turtles or completionTurtles
        completionSites = type(message.sites) == "table" and message.sites or completionSites
        if not NATIVE_TABS and type(message.turtleStates) == "table" then
            turtleStates = safeTurtleStates(message.turtleStates)
        end
        if not NATIVE_TABS and message.player ~= nil then applyControllerPlayer(message.player) end
        if changed then controllerRegistered = false end
        if changed then
            printAsync(("Mining controller connected (computer %d)"):format(sender), false)
        end
        if changed or not controllerRegistered then
            rednet.send(controllerId, {
                type = "RELAY_HELLO",
                source = os.getComputerID(),
                controllerBootId = controllerBootId,
            }, JOB_PROTOCOL)
        end
        if controllerRegistered then requestFarmIndex(message.farmMapKeys) end
    elseif message.type == "RELAY_ACK" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        controllerRegistered = true
        completionTurtles = type(message.turtles) == "table" and message.turtles or {}
        completionSites = type(message.sites) == "table" and message.sites or {}
        if not NATIVE_TABS and type(message.turtleStates) == "table" then
            turtleStates = safeTurtleStates(message.turtleStates)
        end
        if not NATIVE_TABS and message.player ~= nil then applyControllerPlayer(message.player) end
        saveRelayState()
        for _, command in ipairs(pendingCommands) do
            rednet.send(controllerId, {
                type = "REMOTE_COMMAND", requestId = command.id,
                command = command.command, source = os.getComputerID(),
            }, JOB_PROTOCOL)
        end
        requestAlertSync()
        requestFarmIndex(message.farmMapKeys)
    elseif message.type == "REMOTE_OUTPUT" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        if message.requestId then
            for index, command in ipairs(pendingCommands) do
                if command.id == message.requestId then
                    table.remove(pendingCommands, index)
                    if not saveRelayState() then
                        printError("Command completed, but relay queue cleanup could not be saved.")
                    end
                    break
                end
            end
        end
        printAsync(message.text or "", false)
    elseif message.type == "PLAYER_UPDATE" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        applyControllerPlayer(message.player)
        renderMap()
    elseif message.type == "TURTLE_UPDATE" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        if type(message.turtle) == "table" and message.turtle.id then
            local safe = safeTurtleStates({ [message.turtle.id] = message.turtle })
            if safe[message.turtle.id] then turtleStates[message.turtle.id] = safe[message.turtle.id] end
            renderMap()
        end
    elseif message.type == "FARM_MAP_SNAPSHOT_BEGIN" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        local cellCount = tonumber(message.cellCount)
        if type(message.farmKey) == "string" and type(message.snapshotId) == "string"
            and #message.farmKey <= 128 and #message.snapshotId <= 256
            and type(message.mapRevision) == "number"
            and type(message.chunkCount) == "number" and message.chunkCount >= 1
            and message.chunkCount <= 128 and message.chunkCount % 1 == 0
            and cellCount and cellCount >= 0 and cellCount <= 4096 and cellCount % 1 == 0
            and message.chunkCount == math.max(1, math.ceil(cellCount / 32)) then
            prunePendingMaps(mapSnapshots, 8)
            mapSnapshots[message.farmKey] = {
                snapshotId = message.snapshotId, revision = message.mapRevision,
                chunkCount = message.chunkCount, cellCount = cellCount, chunks = {},
                metadata = safeMapMetadata(message.metadata), createdAt = os.epoch("utc"),
            }
        end
    elseif message.type == "FARM_MAP_SNAPSHOT_CHUNK" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        applySnapshotChunk(message)
    elseif message.type == "FARM_MAP_SNAPSHOT_END" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        finishSnapshot(message)
    elseif message.type == "FARM_MAP_DELTA" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        applyFarmDelta(message)
    elseif message.type == "CONTROL_RESULT" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        printAsync(message.text or "", false)
    elseif message.type == "WORKER_ALERT" and sender == controllerId
        and relayState.alertsEnabled then
        if message.controllerBootId == controllerBootId and rememberAlert(message) then
            saveRelayState()
            printAsync(message.text or "A mining turtle needs attention", true)
        end
    elseif message.type == "ALERT_SYNC" and relayState.alertsEnabled
        and message.controllerBootId == controllerBootId then
        local alerts = message.alerts or {}
        local fresh = {}
        for _, alert in ipairs(alerts) do
            if rememberAlert(alert) then table.insert(fresh, alert) end
        end
        if #fresh > 0 then
            saveRelayState()
            clearPrompt()
            print(("Recent turtle alerts (%d):"):format(#fresh))
            for _, alert in ipairs(fresh) do
                printError(alert.text or tostring(alert.status or "Unknown turtle problem"))
            end
            redrawPrompt()
        end
    end
end

local function forwardUpload(transfer)
    local files = {}
    for _, file in ipairs(transfer.getFiles()) do
        files[fs.getName(file.getName())] = file.readAll()
        file.close()
    end
    if files["deploy_server.lua"] and files["startup.lua"] and not files["relay.lua"]
        and not files["upload.lua"] then
        local server, masterError = ensureMaster()
        if not server then printError(masterError) return end
        local requestNonce = nonce("master-update")
        rednet.send(server, {
            type = "RELAY_MASTER_UPDATE", nonce = requestNonce, files = files,
        }, PROTOCOL)
        local response, responseError = receiveMaster(requestNonce)
        if not response then
            printError("Master deployment update failed: " .. tostring(responseError))
        else
            print("Master deployment update accepted; it is rebooting.")
        end
        return
    end
    if files["relay-manifest.lua"] and not files["upload.lua"] then
        local manifestChunk, manifestError = load(
            files["relay-manifest.lua"], "@relay-manifest.lua", "t", {}
        )
        if not manifestChunk then printError("Relay manifest is invalid: " .. manifestError) return end
        local manifestOk, manifest = pcall(manifestChunk)
        if not manifestOk or type(manifest) ~= "table" or manifest.version ~= 1
            or type(manifest.files) ~= "table" or #manifest.files == 0 then
            printError("Relay manifest must return a version 1 file list")
            return
        end
        local entries, seen = {}, {}
        for _, entry in ipairs(manifest.files) do
            local source = type(entry) == "table" and entry.source
            local path = type(entry) == "table" and entry.path
            if type(source) ~= "string" or source ~= fs.getName(source)
                or type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
                or path:find("..", 1, true) or path:find("\\", 1, true)
                or path:match("^data/") or path:match("^%.relay") or seen[path]
                or type(files[source]) ~= "string" then
                printError("Relay manifest has an unsafe, duplicate, or missing file")
                return
            end
            if path:sub(-4) == ".lua" then
                local chunk, syntaxError = load(files[source], "@/" .. path, "t", _ENV)
                if not chunk then
                    printError(("Relay update rejected invalid %s: %s"):format(path, syntaxError))
                    return
                end
            end
            seen[path] = true
            entries[#entries + 1] = { source = source, path = path }
        end

        local root = "/.relay-self-update"
        local stageRoot, backupRoot = fs.combine(root, "stage"), fs.combine(root, "backup")
        if fs.exists(root) then fs.delete(root) end
        fs.makeDir(stageRoot)
        local marker = { version = 1, files = {} }
        for _, entry in ipairs(entries) do
            local staged = fs.combine(stageRoot, entry.path)
            local parent = fs.getDir(staged)
            if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
            local handle, openError = fs.open(staged, "w")
            if not handle then
                fs.delete(root)
                printError("Relay self-update staging failed: " .. tostring(openError))
                return
            end
            local wrote, writeError = pcall(handle.write, files[entry.source])
            pcall(handle.close)
            if not wrote then
                fs.delete(root)
                printError("Relay self-update staging failed: " .. tostring(writeError))
                return
            end
            marker.files[#marker.files + 1] = {
                path = entry.path, existed = fs.exists("/" .. entry.path),
            }
        end
        local markerHandle, markerError = fs.open(fs.combine(root, "installing"), "w")
        if not markerHandle then
            fs.delete(root)
            printError("Relay update marker failed: " .. tostring(markerError))
            return
        end
        local markerWrote, markerWriteError = pcall(function()
            markerHandle.write(textutils.serialize(marker, { compact = true }))
            markerHandle.close()
        end)
        if not markerWrote then
            pcall(markerHandle.close)
            fs.delete(root)
            printError("Relay update marker failed: " .. tostring(markerWriteError))
            return
        end

        local installed, installError = pcall(function()
            for _, entry in ipairs(entries) do
                local destination, backup = "/" .. entry.path, fs.combine(backupRoot, entry.path)
                if fs.exists(destination) then
                    local backupParent = fs.getDir(backup)
                    if backupParent ~= "" and not fs.exists(backupParent) then fs.makeDir(backupParent) end
                    fs.copy(destination, backup)
                    fs.delete(destination)
                end
                local parent = fs.getDir(destination)
                if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
                fs.move(fs.combine(stageRoot, entry.path), destination)
            end
        end)
        if not installed then
            for _, entry in ipairs(marker.files) do
                local destination, backup = "/" .. entry.path, fs.combine(backupRoot, entry.path)
                if fs.exists(backup) then
                    if fs.exists(destination) then fs.delete(destination) end
                    fs.move(backup, destination)
                elseif not entry.existed and fs.exists(destination) then
                    fs.delete(destination)
                end
            end
            fs.delete(root)
            printError("Relay self-update install failed: " .. tostring(installError))
            return
        end
        fs.delete(root)
        print("Deployment relay updated. Rebooting...")
        sleep(1)
        os.reboot()
        return
    end
    local descriptorSource = files["upload.lua"]
    if not descriptorSource then printError("Relay upload requires upload.lua") return end
    local chunk, syntaxError = load(descriptorSource, "@upload.lua", "t", {})
    if not chunk then printError(syntaxError) return end
    local ok, descriptor = pcall(chunk)
    if not ok or type(descriptor) ~= "table" or not validName(descriptor.project)
        or not validName(descriptor.target) then
        printError("Relay upload has an invalid project/target")
        return
    end
    local server, masterError = ensureMaster()
    if not server then printError(masterError) return end
    local requestNonce = nonce("upload")
    rednet.send(server, {
        type = "RELAY_UPLOAD", nonce = requestNonce, files = files,
    }, PROTOCOL)
    local response, responseError = receiveMaster(requestNonce)
    if not response then printError("Master upload failed: " .. tostring(responseError)) return end
    print("Upload accepted by the master deployment server.")
end

local function setupTerminalUi()
    if not baseTerminal then baseTerminal = term.current() end
    if commandWindow then commandWindow.setVisible(false) end
    local width, height = baseTerminal.getSize()
    term.redirect(baseTerminal)
    local top = NATIVE_TABS and 1 or 2
    commandWindow = window.create(baseTerminal, 1, top, width, math.max(1, height - top + 1), true)
    term.redirect(commandWindow)
    promptVisible = false
    commandWindow.setVisible(activeTab == "command")
    if not NATIVE_TABS then drawTabHeader() end
    if activeTab == "map" then renderMap() end
end

local function announceCachedTargets()
    for key, entry in pairs(cache) do
        local project, target = key:match("^([^/]+)/(.+)$")
        if project and target then
            rednet.broadcast({
                type = "UPDATE_AVAILABLE",
                project = project,
                target = target,
                release = entry.release,
                serverId = os.getComputerID(),
                authority = false,
            }, PROTOCOL)
        end
    end
end

if not openModem() then error("Relay requires an attached modem", 0) end
loadRelayState()
setupTerminalUi()
recoverCacheTransactions()
loadCachedTargets()
if #pendingCommands > 0 then
    rednet.broadcast({ type = "CONTROLLER_QUERY", source = os.getComputerID() }, JOB_PROTOCOL)
end
print(("Deployment relay computer %d"):format(os.getComputerID()))
print("Network: " .. NETWORK_ID)
print("This computer is a relay only. The master deployment PC remains authoritative.")
print("Alerts " .. (relayState.alertsEnabled and "enabled" or "disabled") .. " (type 'alerts' to toggle)")

announceCachedTargets()
local cacheAnnounceTimer = os.startTimer(15)
if not NATIVE_TABS then gpsTimer = os.startTimer(0.1) end

local commandNames = {
    "alerts", "cancel", "dig", "farm", "farm-expand", "farm-radius", "farm-service", "help", "jobs", "map", "repair", "retry", "setup-farm",
    "setup-room", "setup-station", "setup-tunnel", "sites", "survey",
    "surveys", "travel", "tunnel", "turtles",
}
local turtleCommands = {
    cancel = true, dig = true, farm = true, farm_expand = true, farm_radius = true,
    farm_service = true, repair = true, retry = true,
    setup_farm = true, setup_room = true,
    setup_station = true, setup_tunnel = true, survey = true, travel = true, tunnel = true,
}

local function completeInput(value)
    if tabCycle and tabCycle.rendered == value then
        tabCycle.index = tabCycle.index % #tabCycle.matches + 1
        tabCycle.rendered = tabCycle.base .. tabCycle.matches[tabCycle.index]
        return tabCycle.rendered
    end
    local base, prefix = value:match("^(.-)([^%s]*)$")
    local words = {}
    for word in base:gmatch("%S+") do table.insert(words, word) end
    local choices = commandNames
    if #words == 1 then
        local command = words[1]
        if command == "alerts" then choices = { "off", "on", "status" }
        elseif command == "retry" then
            choices = { "now" }
            for _, turtleName in ipairs(completionTurtles) do table.insert(choices, turtleName) end
        elseif turtleCommands[command:gsub("-", "_")] then choices = completionTurtles
        else return value end
    elseif #words == 2 and (words[1] == "farm" or words[1] == "tunnel") then
        choices = completionSites
    elseif #words == 2 and words[1] == "farm-service" then
        choices = { "start", "status", "stop" }
    elseif #words == 2 and words[1] == "farm-expand" then
        choices = { "off", "on", "toggle" }
    elseif #words == 2 and words[1] == "farm-radius" then
        return value
    elseif #words > 0 then
        return value
    end
    local matches = {}
    local seenMatches = {}
    for _, choice in ipairs(choices) do
        if choice:sub(1, #prefix) == prefix and not seenMatches[choice] then
            seenMatches[choice] = true
            table.insert(matches, choice)
        end
    end
    if #matches == 0 then tabCycle = nil return value end
    table.sort(matches)
    if #matches == 1 then
        tabCycle = nil
        return base .. matches[1] .. " "
    end
    tabCycle = { base = base, matches = matches, index = 1 }
    tabCycle.rendered = base .. matches[1]
    return tabCycle.rendered
end

local function replacePromptInput(value)
    input = value
    clearPrompt()
    drawPrompt(input)
end

local function resetCompletion()
    tabCycle = nil
end

local function recallHistory(direction)
    resetCompletion()
    if #commandHistory == 0 then return end
    if direction < 0 then
        if not historyIndex then
            historyDraft = input
            historyIndex = #commandHistory
        else
            historyIndex = math.max(1, historyIndex - 1)
        end
        replacePromptInput(commandHistory[historyIndex])
    elseif historyIndex then
        if historyIndex < #commandHistory then
            historyIndex = historyIndex + 1
            replacePromptInput(commandHistory[historyIndex])
        else
            historyIndex = nil
            replacePromptInput(historyDraft)
        end
    end
end

local function toggleFollow()
    relayState.ui.followPlayer = not relayState.ui.followPlayer
    if relayState.ui.followPlayer and playerPosition then
        mapCenter.x, mapCenter.z = playerPosition.x, playerPosition.z
    end
    saveRelayState()
    renderMap()
end

local function handleMapClick(button, x, y)
    local width, height = terminalSize()
    if y == 1 then
        if x >= 1 and x <= 5 then switchTab("command") return end
        if x >= 7 and x <= 11 then switchTab("map") return end
        if activeTab == "map" and width >= 20 then
            if x >= width - 10 and x <= width - 8 then setZoom(mapZoom() * 2) return end
            if x >= width - 6 and x <= width - 4 then setZoom(math.floor(mapZoom() / 2)) return end
            if x >= width - 2 then toggleFollow() return end
        end
    end
    if activeTab ~= "map" or y < 2 or y >= height then return end
    relayState.ui.followPlayer = false
    local zoom = mapZoom()
    local worldX, worldZ = worldDelta(
        math.floor((x - width / 2) * zoom),
        math.floor((y - 2 - (height - 2) / 2) * zoom)
    )
    mapCenter.x, mapCenter.z = mapCenter.x + worldX, mapCenter.z + worldZ
    if button == 1 then setZoom(math.max(1, math.floor(zoom / 2)))
    elseif button == 2 then setZoom(math.min(16, zoom * 2))
    else renderMap() end
end

local function focusNativeMap()
    if not NATIVE_TABS then return false end
    for tab = 1, multishell.getCount() do
        if multishell.getTitle(tab) == "Map" then
            multishell.setFocus(tab)
            return true
        end
    end
    return false
end

while true do
    if not promptVisible then
        drawPrompt("")
        promptVisible = true
    end
    local event, first, second, third = nextEvent()
    if event == "term_resize" then
        setupTerminalUi()
    elseif event == "mouse_click" and not NATIVE_TABS then
        handleMapClick(first, second, third)
    elseif event == "mouse_scroll" and activeTab == "map" then
        if first > 0 then setZoom(mapZoom() * 2)
        else setZoom(math.floor(mapZoom() / 2)) end
    elseif event == "monitor_resize" and refreshMonitor then
        refreshMonitor()
    elseif event == "char" and activeTab == "map" then
        if first == "+" or first == "=" then setZoom(math.floor(mapZoom() / 2))
        elseif first == "-" then setZoom(mapZoom() * 2)
        elseif string.lower(first) == "f" then toggleFollow() end
    elseif event == "char" and activeTab == "command" then
        resetCompletion()
        historyIndex = nil
        input = input .. first
        write(first)
    elseif event == "key" and activeTab == "map" and first == keys.left then
        panMap(-1, 0)
    elseif event == "key" and activeTab == "map" and first == keys.right then
        panMap(1, 0)
    elseif event == "key" and activeTab == "map" and first == keys.up then
        panMap(0, -1)
    elseif event == "key" and activeTab == "map" and first == keys.down then
        panMap(0, 1)
    elseif event == "key" and activeTab == "map" and first == keys.pageUp then
        setZoom(math.floor(mapZoom() / 2))
    elseif event == "key" and activeTab == "map" and first == keys.pageDown then
        setZoom(mapZoom() * 2)
    elseif event == "key" and activeTab == "map" and first == keys.space then
        relayState.ui.followPlayer = true
        if playerPosition then mapCenter.x, mapCenter.z = playerPosition.x, playerPosition.z end
        saveRelayState()
        renderMap()
    elseif event == "key" and activeTab == "map" and first == keys.tab then
        switchTab("command")
    elseif event == "key" and activeTab == "command" and first == keys.backspace and #input > 0 then
        resetCompletion()
        historyIndex = nil
        input = input:sub(1, -2)
        clearPrompt()
        drawPrompt(input)
    elseif event == "key" and activeTab == "command" and first == keys.tab then
        replacePromptInput(completeInput(input))
    elseif event == "key" and activeTab == "command" and first == keys.up then
        recallHistory(-1)
    elseif event == "key" and activeTab == "command" and first == keys.down then
        recallHistory(1)
    elseif event == "key" and activeTab == "command" and first == keys.enter then
        resetCompletion()
        print()
        if input ~= "" then
            if commandHistory[#commandHistory] ~= input then table.insert(commandHistory, input) end
            while #commandHistory > 50 do table.remove(commandHistory, 1) end
            local command, argument, extra = string.lower(input):match("^(%S+)%s*(%S*)%s*(.-)%s*$")
            if command == "alerts" then
                if extra ~= "" then printError("Usage: alerts [on|off|status]")
                else toggleAlerts(argument) end
            elseif command == "map" then
                if not focusNativeMap() then switchTab("map") end
            else
                sendControllerCommand(input)
            end
        end
        input = ""
        historyIndex = nil
        historyDraft = ""
        promptVisible = false
    elseif event == "timer" and first == gpsTimer then
        local expired = prunePendingMaps(mapSnapshots, math.huge)
        for _, farmKey in ipairs(prunePendingMaps(mapDeltas, math.huge)) do
            expired[#expired + 1] = farmKey
        end
        local requested = {}
        for _, farmKey in ipairs(expired) do
            if farmKey and not requested[farmKey] then
                requested[farmKey] = true
                requestFarmSnapshot(farmKey)
            end
        end
        local x, y, z = gps.locate(0.2, false)
        if x then
            updatePlayerGps(x, y, z)
            if relayState.ui.followPlayer then mapCenter.x, mapCenter.z = x, z end
            mapMessage = "GPS locked"
        else
            mapMessage = "GPS unavailable"
        end
        gpsTimer = os.startTimer(2)
        renderMap()
    elseif event == "timer" and first == cacheAnnounceTimer then
        announceCachedTargets()
        cacheAnnounceTimer = os.startTimer(15)
    elseif event == "file_transfer" then
        forwardUpload(first)
    elseif event == "rednet_message" and third == PROTOCOL then
        local message = second
        if type(message) == "table" and message.type == "UPDATE_AVAILABLE"
            and message.project and message.target and message.serverId == first
            and message.authority ~= false then
            masterId = first
            local ok, synced = syncTarget(message.project, message.target)
            if ok then
                rednet.broadcast({
                    type = "UPDATE_AVAILABLE",
                    project = message.project,
                    target = message.target,
                    release = synced.release,
                    serverId = os.getComputerID(),
                    authority = false,
                }, PROTOCOL)
            else
                printError("Relay cache update failed: " .. tostring(synced))
            end
        else
            handleClient(first, message)
        end
    elseif event == "rednet_message" and third == JOB_PROTOCOL then
        handleControllerMessage(first, second)
    end
    if activeTab == "map" then renderMap() end
end
