local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
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

local function clearPrompt()
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
    local _, y = term.getCursorPos()
    promptStartY = y
    write("relay> " .. value)
end

local function redrawPrompt()
    if promptVisible then drawPrompt(input) end
end

local function printAsync(value, isError)
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
    if message.type == "CONTROLLER_HELLO" then
        if message.controllerId ~= sender then return end
        if controllerId and sender ~= controllerId then return end
        local changed = controllerId ~= sender or controllerBootId ~= message.bootId
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
    elseif message.type == "RELAY_ACK" and sender == controllerId
        and message.controllerBootId == controllerBootId then
        controllerRegistered = true
        completionTurtles = type(message.turtles) == "table" and message.turtles or {}
        completionSites = type(message.sites) == "table" and message.sites or {}
        for _, command in ipairs(pendingCommands) do
            rednet.send(controllerId, {
                type = "REMOTE_COMMAND", requestId = command.id,
                command = command.command, source = os.getComputerID(),
            }, JOB_PROTOCOL)
        end
        requestAlertSync()
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
    if files["relay.lua"] and files["startup.lua"] and not files["upload.lua"] then
        local stage = "/.relay-self-update"
        if fs.exists(stage) then fs.delete(stage) end
        fs.makeDir(stage)
        for _, name in ipairs({ "relay.lua", "startup.lua" }) do
            local handle, openError = fs.open(fs.combine(stage, name), "w")
            if not handle then
                fs.delete(stage)
                printError("Relay self-update failed: " .. tostring(openError))
                return
            end
            handle.write(files[name])
            handle.close()
        end
        if fs.exists("/relay.lua") then fs.delete("/relay.lua") end
        if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
        fs.move(fs.combine(stage, "relay.lua"), "/relay.lua")
        fs.move(fs.combine(stage, "startup.lua"), "/startup.lua")
        fs.delete(stage)
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

if not openModem() then error("Relay requires an attached modem", 0) end
loadRelayState()
recoverCacheTransactions()
loadCachedTargets()
if #pendingCommands > 0 then
    rednet.broadcast({ type = "CONTROLLER_QUERY", source = os.getComputerID() }, JOB_PROTOCOL)
end
print(("Deployment relay computer %d"):format(os.getComputerID()))
print("Network: " .. NETWORK_ID)
print("This computer is a relay only. The master deployment PC remains authoritative.")
print("Alerts " .. (relayState.alertsEnabled and "enabled" or "disabled") .. " (type 'alerts' to toggle)")

local cacheAnnounceTimer = os.startTimer(5)

local commandNames = {
    "alerts", "cancel", "dig", "farm", "help", "jobs", "repair", "retry", "setup-farm",
    "setup-room", "setup-station", "setup-tunnel", "sites", "survey",
    "surveys", "travel", "tunnel", "turtles",
}
local turtleCommands = {
    cancel = true, dig = true, farm = true, repair = true, retry = true,
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

while true do
    if not promptVisible then
        drawPrompt("")
        promptVisible = true
    end
    local event, first, second, third = nextEvent()
    if event == "monitor_resize" and refreshMonitor then
        refreshMonitor()
    elseif event == "char" then
        resetCompletion()
        historyIndex = nil
        input = input .. first
        write(first)
    elseif event == "key" and first == keys.backspace and #input > 0 then
        resetCompletion()
        historyIndex = nil
        input = input:sub(1, -2)
        clearPrompt()
        drawPrompt(input)
    elseif event == "key" and first == keys.tab then
        replacePromptInput(completeInput(input))
    elseif event == "key" and first == keys.up then
        recallHistory(-1)
    elseif event == "key" and first == keys.down then
        recallHistory(1)
    elseif event == "key" and first == keys.enter then
        resetCompletion()
        print()
        if input ~= "" then
            if commandHistory[#commandHistory] ~= input then table.insert(commandHistory, input) end
            while #commandHistory > 50 do table.remove(commandHistory, 1) end
            local command, argument, extra = string.lower(input):match("^(%S+)%s*(%S*)%s*(.-)%s*$")
            if command == "alerts" then
                if extra ~= "" then printError("Usage: alerts [on|off|status]")
                else toggleAlerts(argument) end
            else
                sendControllerCommand(input)
            end
        end
        input = ""
        historyIndex = nil
        historyDraft = ""
        promptVisible = false
    elseif event == "timer" and first == cacheAnnounceTimer then
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
        cacheAnnounceTimer = os.startTimer(15)
    elseif event == "file_transfer" then
        forwardUpload(first)
    elseif event == "rednet_message" and third == PROTOCOL then
        local message = second
        if type(message) == "table" and message.type == "UPDATE_AVAILABLE"
            and message.project and message.target and message.serverId == first
            and message.authority ~= false then
            masterId = first
            local ok, syncError = syncTarget(message.project, message.target)
            if ok then
                rednet.broadcast(message, PROTOCOL)
            else
                printError("Relay cache update failed: " .. tostring(syncError))
            end
        else
            handleClient(first, message)
        end
    elseif event == "rednet_message" and third == JOB_PROTOCOL then
        handleControllerMessage(first, second)
    end
end
