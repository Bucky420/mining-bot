local config = require("config")
local inventory = require("lib.inventory")
local state = require("lib.state")
local util = require("lib.util")

local network = {}
local deferredMessages = {}
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
            table.insert(deferredMessages, { sender = sender, message = response })
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

function network.open()
    return openModems()
end

function network.report(eventType, payload)
    local data = state.get()
    local controllerId = data.controllerId or config.network.controllerId
    if not controllerId then return false, "NO_CONTROLLER_CONFIGURED" end
    local sequence = data.nextReportSequence or 1
    data.nextReportSequence = sequence + 1
    local message = {
        type = eventType,
        messageId = ("report-%d-%d-%d"):format(os.getComputerID(), util.now(), sequence),
        turtleId = os.getComputerID(),
        status = state.get().status,
        -- Outbox entries must not share table references with currentJob/lastJob,
        -- because textutils.serialize rejects repeated table identities.
        payload = util.detachedCopy(payload),
        sentAt = util.now(),
    }
    table.insert(data.reportOutbox, message)
    state.save()
    return network.flushReports()
end

function network.flushReports()
    local controllerId = state.get().controllerId or config.network.controllerId
    if not controllerId then return false, "NO_CONTROLLER_CONFIGURED" end
    local ok, openError = openModems()
    if not ok then return false, openError end
    local pending = {}
    for _, message in ipairs(state.get().reportOutbox) do table.insert(pending, message) end
    for _, message in ipairs(pending) do
        local sent = sendReport(controllerId, message)
        if not sent then break end
    end
    return #state.get().reportOutbox == 0
end

function network.announce(resync)
    local ok, openError = openModems()
    if not ok then return false, openError end
    local data = state.get()
    network.flushReports()
    local message = {
        type = "WORKER_HELLO",
        turtleId = os.getComputerID(),
        status = data.status,
        statusDetail = data.statusDetail,
        position = data.position,
        heading = data.heading,
        home = data.home,
        label = os.getComputerLabel(),
        sentAt = util.now(),
        resync = resync == true,
    }
    local controllerId = data.controllerId or config.network.controllerId
    if controllerId then rednet.send(controllerId, message, config.network.protocol)
    else rednet.broadcast(message, config.network.protocol) end
    return true
end

function network.receiveDeploymentUpdate(timeout)
    local ok = openModems()
    if not ok then return false end
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
    return type(deployment) ~= "table" or deployment.release ~= message.release
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

function network.checkDeploymentUpdate(timeout)
    local ok = openModems()
    if not ok then return false end
    local nonce = tostring(os.getComputerID()) .. ":" .. tostring(util.now())
    rednet.broadcast({
        type = "DISCOVER",
        project = "mining-bot",
        target = "turtle",
        nonce = nonce,
    }, config.network.id .. "/deployment/v1")
    local deadline = util.now() + math.floor((timeout or 1) * 1000)
    while util.now() < deadline do
        local _, message = rednet.receive(
            config.network.id .. "/deployment/v1",
            math.max(0, (deadline - util.now()) / 1000)
        )
        if type(message) == "table" and message.type == "OFFER"
            and message.nonce == nonce and message.project == "mining-bot"
            and message.target == "turtle" then
            local deployment
            if fs.exists("/data/deployment.state") then
                local handle = fs.open("/data/deployment.state", "r")
                if handle then
                    deployment = textutils.unserialize(handle.readAll())
                    handle.close()
                end
            end
            return type(deployment) ~= "table" or deployment.release ~= message.release
        end
    end
    return false
end

function network.receiveJob(timeout)
    local ok = openModems()
    if not ok then return nil end
    local sender, message
    if #deferredMessages > 0 then
        local deferred = table.remove(deferredMessages, 1)
        sender, message = deferred.sender, deferred.message
    else
        sender, message = rednet.receive(config.network.protocol, timeout)
    end
    if not sender or type(message) ~= "table" then
        return nil
    end
    if message.type == "CONTROLLER_HELLO" then
        local data = state.get()
        if data.controllerId and sender ~= data.controllerId then
            return nil, "UNAUTHORIZED_CONTROLLER"
        end
        local changed = data.controllerId ~= sender or data.controllerBootId ~= message.bootId
        data.controllerId = sender
        data.controllerBootId = message.bootId
        state.save()
        if changed then
            network.announce(true)
            local failedJob = data.currentJob and data.currentJob.status == "FAILED"
            if actionableStatuses[data.status] or failedJob or data.lastError then
                network.report("WORKER_STATUS", {
                    reason = data.statusDetail,
                    lastError = data.lastError,
                    job = data.currentJob or data.lastJob,
                })
            end
        end
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
            or message.action == "update") then
        return nil, nil, sender, message.action, message.release
    end
    if message.type ~= "ASSIGN_JOB" then return nil end
    if type(message.job) ~= "table" or type(message.job.type) ~= "string" then
        return nil, "INVALID_JOB_MESSAGE"
    end
    return message.job, nil, sender, nil
end

return network
