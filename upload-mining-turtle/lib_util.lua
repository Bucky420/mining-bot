local config = require("config")

local util = {}

local levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

function util.copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[util.copy(key, seen)] = util.copy(item, seen)
    end
    return result
end

-- Persistent CC:Tweaked tables cannot contain repeated table identities.
-- Duplicate aliases into independent tables while still rejecting cycles.
function util.detachedCopy(value, ancestors)
    if type(value) ~= "table" then return value end
    ancestors = ancestors or {}
    if ancestors[value] then return "<cyclic table>" end
    ancestors[value] = true
    local result = {}
    for key, item in pairs(value) do
        result[util.detachedCopy(key, ancestors)] = util.detachedCopy(item, ancestors)
    end
    ancestors[value] = nil
    return result
end

function util.contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then
            return true
        end
    end
    return false
end

function util.now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

function util.makeId(prefix)
    return ("%s-%d-%d"):format(prefix or "id", os.getComputerID(), util.now())
end

function util.readTable(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil, "file does not exist"
    end
    local handle, openError = fs.open(path, "r")
    if not handle then
        return nil, openError or "unable to open file"
    end
    local contents = handle.readAll()
    handle.close()
    local value = textutils.unserialize(contents)
    if type(value) ~= "table" then
        return nil, "file does not contain a serialized table"
    end
    return value
end

function util.atomicWriteTable(path, value, preserveBackup)
    ensureParent(path)
    local temporary = path .. ".tmp"
    local backup = path .. ".bak"
    local previous = path .. ".previous"
    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local handle, openError = fs.open(temporary, "w")
    if not handle then
        return false, openError or "unable to open temporary file"
    end
    handle.write(textutils.serialize(util.detachedCopy(value), { compact = true }))
    handle.flush()
    handle.close()

    local check, checkError = util.readTable(temporary)
    if not check then
        fs.delete(temporary)
        return false, "temporary save validation failed: " .. tostring(checkError)
    end

    if fs.exists(previous) then
        fs.delete(previous)
    end
    if fs.exists(path) then
        fs.copy(path, previous)
        fs.delete(path)
    end
    fs.move(temporary, path)

    local installed, installedError = util.readTable(path)
    if not installed then
        return false, "installed save validation failed: " .. tostring(installedError)
    end

    if not preserveBackup and fs.exists(previous) then
        local validPrevious = util.readTable(previous)
        if validPrevious then
            if fs.exists(backup) then fs.delete(backup) end
            fs.move(previous, backup)
        end
    end
    if fs.exists(previous) then fs.delete(previous) end
    return true
end

function util.loadTableWithBackup(path)
    local value, primaryError = util.readTable(path)
    if value then
        return value, false
    end
    local backup, backupError = util.readTable(path .. ".bak")
    if backup then
        return backup, true
    end
    return nil, false, ("primary: %s; backup: %s"):format(
        tostring(primaryError), tostring(backupError)
    )
end

function util.log(level, message, context)
    level = levels[level] and level or "INFO"
    if levels[level] < (levels[config.logging.level] or levels.INFO) then
        return
    end
    local suffix = ""
    if context ~= nil then
        suffix = " " .. textutils.serialize(util.detachedCopy(context), { compact = true })
    end
    local line = ("[%s] [%s] %s%s"):format(
        os.date and os.date("!%Y-%m-%dT%H:%M:%SZ") or tostring(util.now()),
        level,
        tostring(message),
        suffix
    )
    print(line)

    ensureParent(config.paths.log)
    if fs.exists(config.paths.log) and fs.getSize(config.paths.log) >= config.logging.maxFileBytes then
        local old = config.paths.log .. ".old"
        if fs.exists(old) then
            fs.delete(old)
        end
        fs.move(config.paths.log, old)
    end
    local handle = fs.open(config.paths.log, "a")
    if handle then
        handle.writeLine(line)
        handle.close()
    end
end

function util.parseInteger(value, name)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then
        return nil, (name or "value") .. " must be an integer"
    end
    return number
end

return util
