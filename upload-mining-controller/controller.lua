local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local JOB_PROTOCOL = NETWORK_ID .. "/mining/v1"
local DEPLOY_PROTOCOL = NETWORK_ID .. "/deployment/v1"
local STATE_PATH = "/data/controller.state"
local BOOT_ID = ("%d:%d"):format(os.getComputerID(), os.epoch("utc"))

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
    for _, path in ipairs({ STATE_PATH, STATE_PATH .. ".tmp", STATE_PATH .. ".previous" }) do
        if fs.exists(path) then
            local handle = fs.open(path, "r")
            if handle then
                local value = textutils.unserialize(handle.readAll())
                handle.close()
                if type(value) == "table" then
                    value.turtles = value.turtles or {}
                    value.jobs = value.jobs or {}
                    value.processedReports = value.processedReports or {}
                    value.processedReportOrder = value.processedReportOrder or {}
                    value.nextTurtleNumber = value.nextTurtleNumber or 1
                    value.remoteCommands = value.remoteCommands or {}
                    value.remoteCommandOrder = value.remoteCommandOrder or {}
                    value.sites = value.sites or {}
                    value.surveys = value.surveys or {}
                    value.alerts = value.alerts or {}
                    value.relays = value.relays or {}
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
        sites = {}, surveys = {}, alerts = {}, relays = {},
    }
end

local controllerState = loadState()
local activeRelays = {}

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
    handle.write(textutils.serialize(detachedCopy(controllerState), { compact = true }))
    handle.close()
    local previous = STATE_PATH .. ".previous"
    if fs.exists(previous) then fs.delete(previous) end
    if fs.exists(STATE_PATH) then
        fs.copy(STATE_PATH, previous)
        fs.delete(STATE_PATH)
    end
    fs.move(temporary, STATE_PATH)
    if fs.exists(previous) then fs.delete(previous) end
    return true
end

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
    local id = fixedId or jobId()
    if controllerState.jobs[id] then return true, "Job " .. id .. " was already submitted" end
    local job = { id = id, type = jobType, parameters = parameters, progress = {} }
    controllerState.jobs[job.id] = {
        turtleId = turtleId, type = jobType, status = "PENDING_SEND", createdAt = os.epoch("utc"),
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

local function sendControl(turtleId, action)
    if not rednet.send(turtleId, { type = "CONTROL_JOB", action = action }, JOB_PROTOCOL) then
        return false, "Unable to send control command"
    end
    return true, ("%s sent to turtle %d"):format(action, turtleId)
end

local function showHelp()
    print("turtles")
    print("jobs")
    print("retry | retry now | retry <turtle-name> | cancel <turtle-name>")
    print("travel <turtle-name> <x> <y> <z>")
    print("dig <turtle-name> <direction> <length> [profile]")
    print("repair <turtle-name> <x> <y> <z> <marker-type>")
    print("survey <turtle-name> [radius] [exact-block-name]")
    print("farm <turtle-name> <farm-id> [mature-age] [seed-name]")
    print("tunnel <turtle-name> <tunnel-id> <length>")
    print("setup-station <turtle-name> <id> <supply-direction> <output-direction>")
    print("setup-tunnel <turtle-name> <id> <direction> <width> <height>")
    print("setup-farm <turtle-name> <id> <width> <length> <direction> <crop> <seed> [age] <station-id>")
    print("setup-room <turtle-name> <id> <type> <direction> <width> <length> <height>")
    print("sites | surveys")
    print("help")
end

local function handleCommand(line, fixedJobId)
    local tokens = {}
    for token in tostring(line):gmatch("%S+") do table.insert(tokens, token) end
    local command = string.lower(tokens[1] or "")
    if command == "" then return end
    if command == "help" then
        showHelp()
        return true, "turtles | jobs | sites | surveys | retry | cancel | travel | dig | repair | survey | farm | tunnel | setup-* | help"
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
    if command == "retry" or command == "cancel" then
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

local function controllerHello(recipient)
    local turtles, sites = completionSnapshot()
    local message = {
        type = "CONTROLLER_HELLO",
        controllerId = os.getComputerID(),
        bootId = BOOT_ID,
        turtles = turtles,
        sites = sites,
        sentAt = os.epoch("utc"),
    }
    if recipient then rednet.send(recipient, message, JOB_PROTOCOL)
    else rednet.broadcast(message, JOB_PROTOCOL) end
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
    elseif name == "help" then
        output = "turtles | jobs | sites | surveys | retry | cancel | travel | dig | repair | survey | farm | tunnel | setup-* | help"
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
            lastSeen = os.epoch("utc"),
        }
        saveState()
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
    elseif message.type then
        local turtleInfo = controllerState.turtles[sender] or { id = sender }
        local previousStatus = turtleInfo.status
        turtleInfo.status = message.status
        turtleInfo.lastSeen = os.epoch("utc")
        controllerState.turtles[sender] = turtleInfo
        local payload = message.payload
        if actionableStatuses[message.status] or message.type == "JOB_FAILED" then
            turtleInfo.statusDetail = payload and (payload.reason
                or type(payload.result) == "string" and payload.result) or turtleInfo.statusDetail
        else
            turtleInfo.statusDetail = nil
        end
        local job = payload and payload.job
        local reportedJobId = job and job.id or payload and payload.id
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
            if tracked.type == "FARM_CROP" and job and job.progress
                and type(job.progress.discoveredFarm) == "table" and job.progress.discoveredFarm.id then
                controllerState.sites[job.progress.discoveredFarm.id] = detachedCopy(job.progress.discoveredFarm)
            end
        end
        local workerName = turtleInfo.name or ("turtle-" .. tostring(sender))
        local lastError = payload and payload.lastError
        local detail = payload and (payload.reason or payload.result
            or type(lastError) == "table" and (lastError.message or lastError.code))
        print(("%s: %s%s"):format(
            workerName,
            message.type,
            type(detail) == "string" and (" - " .. detail) or ""
        ))
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
controllerHello()

local announceTimer = os.startTimer(15)
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
        controllerHello()
        announceTimer = os.startTimer(15)
    elseif event == "rednet_message" and third == JOB_PROTOCOL then
        if type(second) == "table" and second.type == "CONTROLLER_QUERY" then
            controllerHello(first)
        elseif type(second) == "table" and second.type == "RELAY_HELLO"
            and second.source == first and second.controllerBootId == BOOT_ID then
            registerRelay(first)
            saveState()
            local turtles, sites = completionSnapshot()
            rednet.send(first, {
                type = "RELAY_ACK",
                controllerBootId = BOOT_ID,
                turtles = turtles,
                sites = sites,
            }, JOB_PROTOCOL)
        elseif type(second) == "table" and second.type == "ALERT_SYNC_REQUEST"
            and second.source == first and second.controllerBootId == BOOT_ID
            and activeRelays[first] then
            registerRelay(first)
            saveState()
            rednet.send(first, {
                type = "ALERT_SYNC",
                alerts = latestAlerts(10),
                controllerBootId = BOOT_ID,
            }, JOB_PROTOCOL)
        elseif type(second) == "table" and second.type == "REMOTE_COMMAND" then
            handleRemoteCommand(first, second)
        else
            handleWorker(first, second)
        end
    elseif event == "rednet_message" and third == DEPLOY_PROTOCOL and type(second) == "table"
        and second.type == "UPDATE_AVAILABLE" and second.project == "mining-bot"
        and second.target == "controller" and second.release ~= installedRelease() then
        print("Controller update available; rebooting into updater.")
        sleep(1)
        os.reboot()
    elseif event == "rednet_message" and third == DEPLOY_PROTOCOL and type(second) == "table"
        and second.type == "UPDATE_AVAILABLE" and second.project == "mining-bot"
        and second.target == "turtle" and type(second.release) == "string" then
        for turtleId in pairs(controllerState.turtles) do
            rednet.send(turtleId, {
                type = "CONTROL_JOB",
                action = "update",
                release = second.release,
            }, JOB_PROTOCOL)
        end
    end
end
