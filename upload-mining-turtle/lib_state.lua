local config = require("config")
local util = require("lib.util")

local state = {}
local current

local validStatuses = {
    IDLE = true,
    TRAVELING = true,
    WORKING = true,
    WAITING_BLOCKED = true,
    WAITING_NETWORK = true,
    UPDATE_PENDING = true,
    NEEDS_FUEL = true,
    NEEDS_INVENTORY_SPACE = true,
    NEEDS_TOOL = true,
    NEEDS_SUPPLIES = true,
    NEEDS_OUTPUT = true,
    NEEDS_SCANNER = true,
    NEEDS_FARM = true,
    NEEDS_NETWORK = true,
    JOB_FAILED = true,
    RECOVERING = true,
}

local function defaults()
    return {
        version = config.schemaVersion,
        turtleId = os.getComputerID(),
        status = "RECOVERING",
        position = nil,
        heading = nil,
        positionVerifiedAt = nil,
        pendingMove = nil,
        movesSinceGps = 0,
        currentJob = nil,
        lastJob = nil,
        pendingTasks = {},
        reportOutbox = {},
        nextReportSequence = 1,
        mapRevision = 0,
        home = nil,
        controllerId = nil,
        controllerBootId = nil,
        equipment = { left = nil, right = nil },
        autoRetry = true,
        lastError = nil,
        updatedAt = util.now(),
    }
end

local function validate(data)
    if type(data) ~= "table" then
        return false, "state is not a table"
    end
    if data.autoRetry == nil then data.autoRetry = true end
    if data.version ~= config.schemaVersion then
        return false, "unsupported state version " .. tostring(data.version)
    end
    if data.turtleId ~= os.getComputerID() then
        return false, ("state belongs to turtle %s, not turtle %s"):format(
            tostring(data.turtleId), tostring(os.getComputerID())
        )
    end
    if not validStatuses[data.status] then
        return false, "state status is invalid: " .. tostring(data.status)
    end
    if data.position ~= nil then
        local p = data.position
        if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then
            return false, "state position is invalid"
        end
    end
    if data.heading ~= nil and not ({ north=true, east=true, south=true, west=true })[data.heading] then
        return false, "state heading is invalid"
    end
    if data.home ~= nil then
        local home = data.home
        local position = type(home) == "table" and home.position
        if type(position) ~= "table" or type(position.x) ~= "number"
            or type(position.y) ~= "number" or type(position.z) ~= "number" then
            return false, "state home is invalid"
        end
    end
    data.pendingTasks = data.pendingTasks or {}
    data.reportOutbox = data.reportOutbox or {}
    data.nextReportSequence = data.nextReportSequence or 1
    data.equipment = data.equipment or { left = nil, right = nil }
    data.movesSinceGps = data.movesSinceGps or 0
    return true
end

function state.load()
    local candidates = {
        { name = "primary", path = config.paths.state },
        { name = "temporary", path = config.paths.state .. ".tmp" },
        { name = "previous", path = config.paths.state .. ".previous" },
        { name = "backup", path = config.paths.state .. ".bak" },
    }
    local errors = {}
    for index, candidate in ipairs(candidates) do
        local loaded, readError = util.readTable(candidate.path)
        local valid, validationError = validate(loaded)
        if valid then
            current = loaded
            if index ~= 1 then
                util.log("WARN", "Recovered worker state", { source = candidate.name })
                if fs.exists(config.paths.state) then fs.delete(config.paths.state) end
                fs.copy(candidate.path, config.paths.state)
            end
            return current
        end
        errors[candidate.name] = validationError or readError
    end

    local foundSave = false
    for _, candidate in ipairs(candidates) do
        if fs.exists(candidate.path) then foundSave = true break end
    end
    if foundSave then
        error("Cannot safely load worker state: " .. textutils.serialize(errors, { compact = true }), 0)
    end
    current = defaults()
    state.save()
    return current
end

function state.get()
    if not current then
        return state.load()
    end
    return current
end

function state.save()
    local data = state.get()
    data.updatedAt = util.now()
    local ok, saveError = util.atomicWriteTable(config.paths.state, data)
    if not ok then
        error("Unable to persist worker state: " .. tostring(saveError), 0)
    end
    return true
end

function state.setStatus(status, detail)
    if not validStatuses[status] then
        error("Invalid worker status: " .. tostring(status), 2)
    end
    local data = state.get()
    data.status = status
    data.statusDetail = detail
    state.save()
end

function state.setError(code, message, context)
    local data = state.get()
    data.lastError = {
        code = code,
        message = message,
        context = context,
        at = util.now(),
    }
    state.save()
end

function state.enqueueTask(task)
    local data = state.get()
    task.id = task.id or util.makeId("task")
    task.createdAt = task.createdAt or util.now()
    for _, existing in ipairs(data.pendingTasks) do
        if task.dedupeKey and existing.dedupeKey == task.dedupeKey then
            return existing.id, false
        end
    end
    table.insert(data.pendingTasks, task)
    state.save()
    return task.id, true
end

return state
