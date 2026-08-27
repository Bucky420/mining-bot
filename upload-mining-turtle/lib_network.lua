local config = require("config")
local inventory = require("lib.inventory")
local state = require("lib.state")
local util = require("lib.util")

local network = {}
local deferredMessages = {}
local MAX_DEFERRED_MESSAGES = 64

local function deferMessage(sender, message)
    if not sender or type(message) ~= "table" then return end
    if #deferredMessages >= MAX_DEFERRED_MESSAGES then table.remove(deferredMessages, 1) end
    deferredMessages[#deferredMessages + 1] = { sender = sender, message = message }
end

local function yieldNetwork()
    if type(sleep) == "function" then sleep(0) end
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

local function removeReport(messageId)
    local data = state.get()
    for index, message in ipairs(data.reportOutbox) do
        if message.messageId == messageId then
            table.remove(data.reportOutbox, index)
            state.save()
            return
        end
    end
end

local function sendReport(controllerId, message)
    rednet.send(controllerId, message, config.network.protocol)
    local deadline = util.now() + 2000
    while util.now() < deadline do
        yieldNetwork()
        local sender, response = rednet.receive(
            config.network.protocol,
            math.max(0, (deadline - util.now()) / 1000)
        )
        if sender == controllerId and type(response) == "table"
            and response.type == "REPORT_ACK" and response.messageId == message.messageId then
            removeReport(message.messageId)
            return true
        end
        if sender and type(response) == "table" then
            deferMessage(sender, response)
        end
    end
    return false, "REPORT_NOT_ACKNOWLEDGED"
end

local function openModems()
    if not config.network.enabled then return false, "NETWORK_DISABLED" end
    local ok, modemError = inventory.ensureModem()
    if not ok then return false, modemError end
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    if not opened then return false, "NO_MODEM_PERIPHERAL" end
    return true
end

local function openAttachedModems()
    if not config.network.enabled then return false, "NETWORK_DISABLED" end
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    if not opened then return false, "NO_MODEM_PERIPHERAL" end
    return true
end

local function installedRelease()
    if not fs.exists("/data/deployment.state") then return nil end
    local handle = fs.open("/data/deployment.state", "r")
    if not handle then return nil end
    local deployment = textutils.unserialize(handle.readAll())
    handle.close()
    return type(deployment) == "table" and deployment.release or nil
end

function network.open()
    return openModems()
end

local function reportLimit()
    return math.max(1, math.floor(tonumber(config.network.maxQueuedReports) or 16))
end

function network.reportBacklogFull()
    return #state.get().reportOutbox >= reportLimit()
end

function network.report(eventType, payload)
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return false, "NO_CONTROLLER_CONFIGURED" end
    if eventType == "FARM_MAP" and network.reportBacklogFull() then
        return true, "QUEUED_IN_RAM"
    end
    if eventType ~= "FARM_MAP" and network.reportBacklogFull() then
        return false, "REPORT_BACKLOG_LIMIT_REACHED"
    end
    local sequence = data.nextReportSequence or 1
    data.nextReportSequence = sequence + 1
    local message = {
        type = eventType,
        messageId = ("report-%d-%d-%d"):format(os.getComputerID(), util.now(), sequence),
        turtleId = os.getComputerID(),
        status = state.get().status,
        position = util.detachedCopy(data.position),
        heading = data.heading,
        positionVerifiedAt = data.positionVerifiedAt,
        release = installedRelease(),
        -- Outbox entries must not share table references with currentJob/lastJob,
        -- because textutils.serialize rejects repeated table identities.
        payload = util.detachedCopy(payload),
        sentAt = util.now(),
    }
    table.insert(data.reportOutbox, message)
    state.save()
    local flushed, flushError = network.flushReports(true)
    if flushed then return true end
    if network.reportBacklogFull() then
        return false, ("REPORT_BACKLOG_LIMIT_REACHED: %d/%d (%s)"):format(
            #data.reportOutbox, reportLimit(), tostring(flushError)
        )
    end
    return true, "QUEUED_OFFLINE: " .. tostring(flushError)
end

function network.flushReports(attachedOnly)
    local controllerId = state.get().controllerId or config.network.controllerId
    if not controllerId then return false, "NO_CONTROLLER_CONFIGURED" end
    local ok, openError = attachedOnly and openAttachedModems() or openModems()
    if not ok then return false, openError end
    local pending = {}
    for _, message in ipairs(state.get().reportOutbox) do table.insert(pending, message) end
    local sendError
    for _, message in ipairs(pending) do
        local sent, reportError = sendReport(controllerId, message)
        if not sent then sendError = reportError break end
    end
    if #state.get().reportOutbox == 0 then return true end
    return false, sendError or "REPORT_OUTBOX_NOT_ACKNOWLEDGED"
end

function network.announce(resync, attachedOnly)
    local ok, openError = attachedOnly and openAttachedModems() or openModems()
    if not ok then return false, openError end
    local data = state.get()
    network.flushReports(attachedOnly)
    local message = {
        type = "WORKER_HELLO",
        turtleId = os.getComputerID(),
        status = data.status,
        statusDetail = data.statusDetail,
        position = data.position,
        positionVerifiedAt = data.positionVerifiedAt,
        heading = data.heading,
        navigationReady = data.navigationReady == true,
        navigationError = data.navigationError,
        home = data.home,
        label = os.getComputerLabel and os.getComputerLabel() or nil,
        release = installedRelease(),
        sentAt = util.now(),
        resync = resync == true,
    }
    local controllerId = data.controllerId or config.network.controllerId
    if controllerId then rednet.send(controllerId, message, config.network.protocol)
    else rednet.broadcast(message, config.network.protocol) end
    return true
end

function network.receiveDeploymentUpdate(timeout)
    local opened = openAttachedModems()
    if not opened then return false end
    local _, message = rednet.receive(config.network.id .. "/deployment/v1", timeout)
    if type(message) ~= "table" or message.type ~= "UPDATE_AVAILABLE"
        or message.project ~= "mining-bot" or message.target ~= "turtle" then
        return false
    end
    local deployment
    if fs.exists("/data/deployment.state") then
        local handle = fs.open("/data/deployment.state", "r")
        if handle then
            deployment = textutils.unserialize(handle.readAll())
            handle.close()
        end
    end
    return type(deployment) ~= "table" or deployment.release ~= message.release, message.release
end

function network.needsRelease(release)
    if type(release) ~= "string" then return false end
    if not fs.exists("/data/deployment.state") then return true end
    local handle = fs.open("/data/deployment.state", "r")
    if not handle then return true end
    local deployment = textutils.unserialize(handle.readAll())
    handle.close()
    return type(deployment) ~= "table" or deployment.release ~= release
end

local function receiveControllerMessage(controllerId, deadline)
    while util.now() < deadline do
        if type(sleep) == "function" then sleep(0) end
        for index, deferred in ipairs(deferredMessages) do
            if deferred.sender == controllerId and type(deferred.message) == "table" then
                table.remove(deferredMessages, index)
                return deferred.message
            end
        end
        local sender, message = rednet.receive(
            config.network.protocol,
            math.max(0, (deadline - util.now()) / 1000)
        )
        if sender == controllerId and type(message) == "table" then return message end
        if sender and type(message) == "table" then
            deferMessage(sender, message)
        end
    end
    return nil
end

function network.requestFarmRoute(farmId, start, target, heading, minRevision)
    local opened, openError = openAttachedModems()
    if not opened then return nil, openError end
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return nil, "NO_CONTROLLER_CONFIGURED" end
    local requestId = util.makeId("farm-route")
    for _ = 1, 3 do
        rednet.send(controllerId, {
            type = "FARM_ROUTE_REQUEST", requestId = requestId, farmId = farmId,
            start = util.detachedCopy(start), target = util.detachedCopy(target), heading = heading,
            minRevision = minRevision,
        }, config.network.protocol)
        local deadline = util.now() + 3000
        while util.now() < deadline do
            yieldNetwork()
            local message = receiveControllerMessage(controllerId, deadline)
            if not message then break end
            if message.type == "FARM_ROUTE_RESPONSE" and message.requestId == requestId then
                if not message.ok then return nil, message.error or "CONTROLLER_ROUTE_REJECTED" end
                if type(message.path) ~= "table" or #message.path > 256 then
                    return nil, "INVALID_CONTROLLER_ROUTE"
                end
                local previous = start
                for _, point in ipairs(message.path) do
                    if type(point) ~= "table" or type(point.x) ~= "number" or type(point.z) ~= "number"
                        or point.x ~= math.floor(point.x) or point.z ~= math.floor(point.z)
                        or math.abs(point.x - previous.x) + math.abs(point.z - previous.z) ~= 1 then
                        return nil, "INVALID_CONTROLLER_ROUTE"
                    end
                    previous = point
                end
                if previous.x ~= target.x or previous.z ~= target.z then
                    return nil, "INCOMPLETE_CONTROLLER_ROUTE"
                end
                return message.path, nil, message.mapRevision
            end
            deferMessage(controllerId, message)
        end
    end
    return nil, "CONTROLLER_ROUTE_TIMEOUT"
end

function network.requestRoute(mapId, start, target)
    local opened, openError = openAttachedModems()
    if not opened then return nil, openError end
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return nil, "NO_CONTROLLER_CONFIGURED" end
    local announced, announceError = network.announce(false, true)
    if not announced then return nil, announceError end
    local requestId = util.makeId("route-3d")
    rednet.send(controllerId, {
        type = "ROUTE_REQUEST", requestId = requestId, mapId = mapId or "world",
        start = util.detachedCopy(start), target = util.detachedCopy(target),
    }, config.network.protocol)
    local deadline = util.now() + 10000
    while util.now() < deadline do
        yieldNetwork()
        local message = receiveControllerMessage(controllerId, deadline)
        if not message then break end
        if message.type == "ROUTE_RESPONSE" and message.requestId == requestId then
            if not message.ok then return nil, message.error or "CONTROLLER_ROUTE_REJECTED" end
            if data.controllerBootId and message.controllerBootId ~= data.controllerBootId
                or type(message.reservationId) ~= "string"
                or type(message.reservationExpiresAt) ~= "number"
                or type(message.path) ~= "table" or #message.path > 1024 then
                return nil, "INVALID_CONTROLLER_3D_ROUTE"
            end
            local previous = start
            for _, point in ipairs(message.path) do
                if type(point) ~= "table" or type(point.x) ~= "number"
                    or type(point.y) ~= "number" or type(point.z) ~= "number"
                    or point.x ~= math.floor(point.x) or point.y ~= math.floor(point.y)
                    or point.z ~= math.floor(point.z)
                    or math.abs(point.x - previous.x) + math.abs(point.y - previous.y)
                        + math.abs(point.z - previous.z) ~= 1 then
                    return nil, "INVALID_CONTROLLER_3D_ROUTE"
                end
                previous = point
            end
            if previous.x ~= target.x or previous.y ~= target.y or previous.z ~= target.z then
                return nil, "INCOMPLETE_CONTROLLER_3D_ROUTE"
            end
            return message.path, nil, message.reservationId
        end
        deferMessage(controllerId, message)
    end
    return nil, "CONTROLLER_3D_ROUTE_TIMEOUT"
end

function network.finishRoute(reservationId, blocked, point, block)
    if type(reservationId) ~= "string" then return false end
    local opened = openAttachedModems()
    local controllerId = state.get().controllerId or config.network.controllerId
    if not opened or not controllerId then return false end
    rednet.send(controllerId, {
        type = blocked and "ROUTE_BLOCKED" or "ROUTE_RELEASE",
        reservationId = reservationId,
        point = util.detachedCopy(point),
        blockName = type(block) == "table" and block.name or nil,
    }, config.network.protocol)
    return true
end

function network.requestFarmTerrain(farmId, minRevision)
    local opened, openError = openAttachedModems()
    if not opened then return nil, openError end
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return nil, "NO_CONTROLLER_CONFIGURED" end
    local requestId = util.makeId("farm-terrain")
    for _ = 1, 3 do
        rednet.send(controllerId, {
            type = "FARM_TERRAIN_REQUEST", requestId = requestId, farmId = farmId,
            minRevision = minRevision,
        }, config.network.protocol)
        local deadline, metadata, chunks = util.now() + 10000, nil, {}
        while util.now() < deadline do
            yieldNetwork()
            local message = receiveControllerMessage(controllerId, deadline)
            if not message then break end
            if message.requestId ~= requestId then
                deferMessage(controllerId, message)
            elseif message.type == "FARM_TERRAIN_RESPONSE" and not message.ok then
                return nil, message.error or "CONTROLLER_TERRAIN_REJECTED"
            elseif message.type == "FARM_TERRAIN_BEGIN" then
                if type(message.chunkCount) ~= "number" or message.chunkCount < 1
                    or message.chunkCount > 512 or type(message.cellCount) ~= "number"
                    or message.cellCount < 0 or message.cellCount > 16384 then
                    return nil, "INVALID_TERRAIN_HEADER"
                end
                metadata = message
            elseif metadata and message.type == "FARM_TERRAIN_CHUNK"
                and message.chunkCount == metadata.chunkCount
                and type(message.chunkIndex) == "number" and message.chunkIndex >= 1
                and message.chunkIndex <= metadata.chunkCount and type(message.cells) == "table"
                and #message.cells <= 32 then
                chunks[message.chunkIndex] = util.detachedCopy(message.cells)
            elseif metadata and message.type == "FARM_TERRAIN_END"
                and message.chunkCount == metadata.chunkCount and message.revision == metadata.revision then
                local cells = {}
                for index = 1, metadata.chunkCount do
                    if not chunks[index] then cells = nil break end
                    for _, cell in ipairs(chunks[index]) do
                        if type(cell) ~= "table" or type(cell.x) ~= "number"
                            or type(cell.y) ~= "number" or type(cell.z) ~= "number" then
                            return nil, "INVALID_TERRAIN_CELL"
                        end
                        cells[#cells + 1] = cell
                    end
                end
                if cells and #cells == metadata.cellCount then return cells, nil, metadata.revision end
                break
            end
        end
    end
    return nil, "CONTROLLER_TERRAIN_TIMEOUT"
end

function network.requestFarmSpatial(farmId, chunks, minRevision)
    local opened, openError = openAttachedModems()
    if not opened then return nil, openError end
    if type(farmId) ~= "string" or type(chunks) ~= "table" or #chunks < 1 or #chunks > 27 then
        return nil, "INVALID_SPATIAL_REQUEST"
    end
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return nil, "NO_CONTROLLER_CONFIGURED" end
    local requestId = util.makeId("farm-3d")
    rednet.send(controllerId, {
        type = "FARM_3D_CHUNK_REQUEST", requestId = requestId, farmId = farmId,
        chunks = util.detachedCopy(chunks), minRevision = minRevision,
    }, config.network.protocol)
    local deadline, received = util.now() + 5000, {}
    while util.now() < deadline do
        yieldNetwork()
        local message = receiveControllerMessage(controllerId, deadline)
        if not message then break end
        if message.type == "FARM_3D_CHUNK_RESPONSE" and message.requestId == requestId then
            if not message.ok then return nil, message.error or "SPATIAL_REQUEST_REJECTED" end
            if type(message.chunkKey) ~= "string" then return nil, "INVALID_SPATIAL_RESPONSE" end
            received[message.chunkKey] = message.missing and false or util.detachedCopy(message.chunk)
            local count = 0
            for _ in pairs(received) do count = count + 1 end
            if count == #chunks then return received end
        else
            deferMessage(controllerId, message)
        end
    end
    return nil, "SPATIAL_REQUEST_TIMEOUT"
end

function network.requestFarmSurveyPlan(farmId, center, baseY, radius, step, start, version)
    local opened, openError = openAttachedModems()
    if not opened then return nil, openError end
    local controllerId = state.get().controllerId or config.network.controllerId
    if not controllerId then return nil, "NO_CONTROLLER_CONFIGURED" end
    local requestId = util.makeId("survey-plan")
    rednet.send(controllerId, {
        type = "FARM_3D_SURVEY_PLAN_REQUEST", requestId = requestId,
        farmId = farmId, center = util.detachedCopy(center), baseY = baseY,
        radius = radius, step = step, start = util.detachedCopy(start), version = version,
    }, config.network.protocol)
    local deadline = util.now() + 5000
    while util.now() < deadline do
        yieldNetwork()
        local message = receiveControllerMessage(controllerId, deadline)
        if not message then break end
        if message.type == "FARM_3D_SURVEY_PLAN_RESPONSE" and message.requestId == requestId then
            if not message.ok then return nil, message.error or "SURVEY_PLAN_REJECTED" end
            if message.version ~= version or type(message.poses) ~= "table" or #message.poses > 1024 then
                return nil, "INVALID_SURVEY_PLAN_RESPONSE"
            end
            local poses, seen = {}, {}
            for _, pose in ipairs(message.poses) do
                if type(pose) ~= "table" or type(pose.x) ~= "number" or pose.x ~= math.floor(pose.x)
                    or type(pose.y) ~= "number" or pose.y ~= math.floor(pose.y)
                    or type(pose.z) ~= "number" or pose.z ~= math.floor(pose.z)
                    or (pose.x - center.x) ^ 2 + (pose.z - center.z) ^ 2 > radius * radius then
                    return nil, "INVALID_SURVEY_PLAN_POSE"
                end
                local poseKey = ("%d:%d:%d"):format(pose.x, pose.y, pose.z)
                if seen[poseKey] then return nil, "DUPLICATE_SURVEY_PLAN_POSE" end
                seen[poseKey] = true
                poses[#poses + 1] = util.detachedCopy(pose)
            end
            return poses
        end
        deferMessage(controllerId, message)
    end
    return nil, "SURVEY_PLAN_TIMEOUT"
end

function network.reportFarmSpatial(farmId, chunks, revision, origin, radius, version)
    if type(farmId) ~= "string" or type(chunks) ~= "table" or type(origin) ~= "table"
        or type(origin.x) ~= "number" or type(origin.y) ~= "number" or type(origin.z) ~= "number"
        or type(radius) ~= "number" or type(version) ~= "number" then
        return false, "INVALID_SPATIAL_REPORT"
    end
    local controllerId = state.get().controllerId or config.network.controllerId
    if not controllerId then return true, "QUEUED_IN_RAM" end
    local opened = openModems()
    if not opened then return true, "RETAINED_IN_RAM" end
    for chunkKey, cells in pairs(chunks) do
        local sequence = state.get().nextReportSequence or 1
        state.get().nextReportSequence = sequence + 1
        rednet.send(controllerId, {
            type = "FARM_3D_MAP",
            messageId = ("spatial-%d-%d-%d"):format(os.getComputerID(), util.now(), sequence),
            turtleId = os.getComputerID(),
            status = state.get().status,
            position = util.detachedCopy(state.get().position),
            heading = state.get().heading,
            positionVerifiedAt = state.get().positionVerifiedAt,
            payload = {
                farmId = farmId,
                revision = revision or 0,
                verifiedAt = util.now(),
                version = version,
                origin = util.detachedCopy(origin),
                radius = radius,
                chunks = { [chunkKey] = util.detachedCopy(cells) },
            },
            sentAt = util.now(),
        }, config.network.protocol)
    end
    return true
end

function network.reportFarmMap(payload)
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return true, "RETAINED_IN_RAM" end
    local opened = openModems()
    if not opened then return true, "RETAINED_IN_RAM" end
    local sequence = data.nextReportSequence or 1
    data.nextReportSequence = sequence + 1
    rednet.send(controllerId, {
        type = "FARM_MAP",
        messageId = ("farm-map-%d-%d-%d"):format(os.getComputerID(), util.now(), sequence),
        turtleId = os.getComputerID(),
        status = data.status,
        position = util.detachedCopy(data.position),
        heading = data.heading,
        positionVerifiedAt = data.positionVerifiedAt,
        payload = util.detachedCopy(payload),
        sentAt = util.now(),
    }, config.network.protocol)
    return true
end

function network.syncFarmMap(payload)
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return false, "NO_CONTROLLER_CONFIGURED" end
    local opened, openError = openModems()
    if not opened then return false, openError end
    local sequence = data.nextReportSequence or 1
    data.nextReportSequence = sequence + 1
    local message = {
        type = "FARM_MAP",
        messageId = ("farm-map-sync-%d-%d-%d"):format(os.getComputerID(), util.now(), sequence),
        turtleId = os.getComputerID(),
        status = data.status,
        position = util.detachedCopy(data.position),
        heading = data.heading,
        positionVerifiedAt = data.positionVerifiedAt,
        payload = util.detachedCopy(payload),
        sentAt = util.now(),
    }
    local lastError
    for _ = 1, 3 do
        local sent, sendError = sendReport(controllerId, message)
        if sent then return true end
        lastError = sendError
    end
    return false, lastError or "FARM_MAP_SYNC_NOT_ACKNOWLEDGED"
end

function network.receiveJob(timeout, attachedOnly)
    local ok = attachedOnly and openAttachedModems() or openModems()
    if not ok then return nil end
    local sender, message
    for index, deferred in ipairs(deferredMessages) do
        local messageType = type(deferred.message) == "table" and deferred.message.type
        if messageType == "CONTROLLER_HELLO" or messageType == "REGISTRATION_REQUIRED"
            or messageType == "CONTROL_JOB" or messageType == "ASSIGN_JOB" then
            sender, message = deferred.sender, deferred.message
            table.remove(deferredMessages, index)
            break
        end
    end
    if not sender then
        sender, message = rednet.receive(config.network.protocol, timeout)
    end
    if not sender or type(message) ~= "table" then
        return nil
    end
    if message.type == "CONTROLLER_HELLO" then
        if message.controllerId ~= sender or type(message.bootId) ~= "string"
            or type(message.heartbeatNonce) ~= "string" then
            return nil, "INVALID_CONTROLLER_HELLO"
        end
        local data = state.get()
        if data.controllerId and sender ~= data.controllerId then
            return nil, "UNAUTHORIZED_CONTROLLER"
        end
        local changed = data.controllerId ~= sender or data.controllerBootId ~= message.bootId
        data.controllerId = sender
        data.controllerBootId = message.bootId
        if changed then
            state.save()
            network.announce(true, attachedOnly)
            local failedJob = data.currentJob and data.currentJob.status == "FAILED"
            if actionableStatuses[data.status] or failedJob or data.lastError then
                network.report("WORKER_STATUS", {
                    reason = data.statusDetail,
                    lastError = data.lastError,
                    job = data.currentJob or data.lastJob,
                })
            end
        end
        rednet.send(sender, {
            type = "WORKER_HEARTBEAT",
            turtleId = os.getComputerID(),
            controllerBootId = message.bootId,
            heartbeatNonce = message.heartbeatNonce,
            status = data.status,
            position = util.detachedCopy(data.position),
            heading = data.heading,
            positionVerifiedAt = data.positionVerifiedAt,
            navigationReady = data.navigationReady == true,
            release = installedRelease(),
            sentAt = util.now(),
        }, config.network.protocol)
        return nil
    end
    if message.type == "REGISTRATION_REQUIRED" then
        network.announce(true, attachedOnly)
        return nil
    end
    if message.type == "REPORT_ACK" and type(message.messageId) == "string" then
        removeReport(message.messageId)
        return nil
    end
    local controllerId = state.get().controllerId or config.network.controllerId
    if controllerId and sender ~= controllerId then
        return nil, "UNAUTHORIZED_CONTROLLER"
    end
    if message.type == "CONTROL_JOB"
        and (message.action == "retry" or message.action == "cancel"
            or message.action == "retry_on" or message.action == "retry_off"
            or message.action == "retry_status" or message.action == "retry_toggle"
            or message.action == "update" or message.action == "farm_status"
            or message.action == "farm_expand" or message.action == "farm_radius"
            or message.action == "farm_cancel") then
        return nil, nil, sender, message.action, message.release, message.parameters
    end
    if message.type ~= "ASSIGN_JOB" then
        deferMessage(sender, message)
        return nil
    end
    if type(message.job) ~= "table" or type(message.job.type) ~= "string" then
        return nil, "INVALID_JOB_MESSAGE"
    end
    return message.job, nil, sender, nil
end

return network
