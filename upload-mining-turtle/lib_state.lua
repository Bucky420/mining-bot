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
    WAITING_CHEST = true,
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
        navigationReady = false,
        navigationError = nil,
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

local function eachFarmProgress(data, callback)
    local jobs = { data.currentJob, data.lastJob }
    for _, pending in ipairs(data.pendingTasks or {}) do jobs[#jobs + 1] = pending end
    for _, job in ipairs(jobs) do
        if type(job) == "table" and job.type == "FARM_SERVICE" and type(job.progress) == "table" then
            callback(job.progress)
        end
    end
end

local function encodeMap(values, includeValue)
    local entries = {}
    for key, value in pairs(values or {}) do
        if not includeValue or value == true then
            entries[#entries + 1] = includeValue and tostring(key) or tostring(key) .. "=" .. tostring(value)
        end
    end
    table.sort(entries)
    return table.concat(entries, "|")
end

local function decodeMap(blob, includeValue)
    local result = {}
    for entry in tostring(blob or ""):gmatch("[^|]+") do
        if includeValue then result[entry] = true
        else
            local key, value = entry:match("^([^=]+)=(.*)$")
            if key then result[key] = value end
        end
    end
    return result
end

local function compactProgress(progress)
    if type(progress.scanTiles) == "table" then
        while #progress.scanTiles > 4 do table.remove(progress.scanTiles, 1) end
        local retained = {}
        for _, keys in ipairs(progress.scanTiles) do
            for _, key in ipairs(type(keys) == "table" and keys or {}) do retained[key] = true end
        end
        for key in pairs(type(progress.surfaceColumns) == "table" and progress.surfaceColumns or {}) do
            if not retained[key] then progress.surfaceColumns[key] = nil end
        end
    end
    if type(progress.surfaceColumns) == "table" then
        progress.surfaceColumnBlob = encodeMap(progress.surfaceColumns, false)
        progress.surfaceColumns = nil
    end
    if type(progress.navAllowed) == "table" then
        progress.navAllowedBlob = encodeMap(progress.navAllowed, true)
        progress.navAllowed = nil
    end
    if type(progress.plan) == "table" then
        local cells = {}
        for _, cell in ipairs(progress.plan) do
            local fields = {}
            for index = 1, #cell do fields[index] = tostring(cell[index]) end
            cells[#cells + 1] = table.concat(fields, ",")
        end
        progress.planBlob = table.concat(cells, "|")
        progress.plan = nil
    end
end

local function expandProgress(progress)
    if progress.surfaceColumns == nil and type(progress.surfaceColumnBlob) == "string" then
        progress.surfaceColumns = decodeMap(progress.surfaceColumnBlob, false)
    end
    if progress.navAllowed == nil and type(progress.navAllowedBlob) == "string" then
        progress.navAllowed = decodeMap(progress.navAllowedBlob, true)
    end
    if progress.plan == nil and type(progress.planBlob) == "string" then
        progress.plan = {}
        for encoded in progress.planBlob:gmatch("[^|]+") do
            local cell, index = {}, 1
            for field in (encoded .. ","):gmatch("(.-),") do
                if index == 4 or index == 5 or index == 9 then cell[index] = field
                else cell[index] = tonumber(field) end
                index = index + 1
            end
            progress.plan[#progress.plan + 1] = cell
        end
    end
    progress.surfaceColumnBlob = nil
    progress.navAllowedBlob = nil
    progress.planBlob = nil
end

local function compactReports(data)
    for _, message in ipairs(data.reportOutbox or {}) do
        local payload = type(message) == "table" and message.payload
        if message.type == "FARM_MAP" and type(payload) == "table" and type(payload.delta) == "table" then
            local names, nameIds, rows = {}, {}, {}
            local function nameId(name)
                if not name then return 0 end
                if not nameIds[name] then
                    names[#names + 1] = name
                    nameIds[name] = #names
                end
                return nameIds[name]
            end
            for _, cell in ipairs(payload.delta) do
                rows[#rows + 1] = table.concat({
                    cell.x, cell.y, cell.z, nameId(cell.name), tostring(cell.class or "unknown"),
                    nameId(cell.occupant), tostring(cell.occupantClass or "-"),
                    cell.occupantY or 0, cell.verticalStructure and 1 or 0,
                }, ",")
            end
            payload.deltaNames = names
            payload.deltaBlob = table.concat(rows, "|")
            payload.delta = nil
        end
    end
end

local function expandReports(data)
    for _, message in ipairs(data.reportOutbox or {}) do
        local payload = type(message) == "table" and message.payload
        if message.type == "FARM_MAP" and type(payload) == "table"
            and payload.delta == nil and type(payload.deltaBlob) == "string" then
            payload.delta = {}
            local names = type(payload.deltaNames) == "table" and payload.deltaNames or {}
            for row in payload.deltaBlob:gmatch("[^|]+") do
                local fields = {}
                for field in (row .. ","):gmatch("(.-),") do fields[#fields + 1] = field end
                payload.delta[#payload.delta + 1] = {
                    x = tonumber(fields[1]), y = tonumber(fields[2]), z = tonumber(fields[3]),
                    name = names[tonumber(fields[4])], class = fields[5],
                    occupant = names[tonumber(fields[6])],
                    occupantClass = fields[7] ~= "-" and fields[7] or nil,
                    occupantY = tonumber(fields[8]) ~= 0 and tonumber(fields[8]) or nil,
                    verticalStructure = tonumber(fields[9]) == 1,
                }
            end
            payload.deltaBlob = nil
            payload.deltaNames = nil
        end
    end
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
    if data.navigationReady == nil then data.navigationReady = false end
    expandReports(data)
    eachFarmProgress(data, expandProgress)
    eachFarmProgress(data, function(progress)
        if progress.columns or progress.plan and progress.planFormat ~= 1 then
            -- Early farm-service builds persisted raw Geo Scanner records.
            -- Restart that survey using the compact column format.
            progress.columns = nil
            progress.reportedSurface = nil
            progress.surfaceColumns = nil
            progress.surfaceNames = nil
            progress.surveyNavigationReady = nil
            progress.plan = nil
            progress.planNames = nil
            progress.surveyIndex = 1
            progress.surveyComplete = false
            progress.phase = "SURVEY"
        end
        if progress.phase == "SURVEY" and type(progress.surfaceColumns) == "table"
            and type(progress.scanTiles) ~= "table" then
            -- Migrate the old full-survey cache. Canonical survey deltas already
            -- live on the controller, and the worker will rebuild its local window.
            progress.surfaceColumns = {}
            progress.surfaceNames = {}
            progress.navAllowed = nil
            progress.surveyNavigationReady = nil
        end
    end)
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
    local snapshot = util.detachedCopy(data)
    eachFarmProgress(snapshot, compactProgress)
    compactReports(snapshot)
    local ok, saveError = util.atomicWriteTable(config.paths.state, snapshot)
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
