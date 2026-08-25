package.preload["config"] = function()
    return { logging = { level = "INFO", maxFileBytes = 1000 }, paths = { log = "/log" } }
end

local files, failWrite = {}, false
fs = {}
function fs.getDir() return "" end
function fs.exists(path) return files[path] ~= nil end
function fs.isDir() return false end
function fs.makeDir() end
function fs.delete(path) files[path] = nil end
function fs.move(from, to)
    assert(files[from] ~= nil, "missing move source")
    assert(files[to] == nil, "move destination exists")
    files[to], files[from] = files[from], nil
end
function fs.open(path, mode)
    if mode == "r" then
        if files[path] == nil then return nil end
        return { readAll = function() return files[path] end, close = function() end }
    end
    local buffer = ""
    return {
        write = function(value)
            if failWrite then error("No space left") end
            buffer = buffer .. tostring(value)
        end,
        flush = function() end,
        close = function() files[path] = buffer end,
    }
end

textutils = {
    serialize = function(value) return "VALID:" .. tostring(value.value) end,
    unserialize = function(value)
        local number = tostring(value):match("^VALID:(%-?%d+)$")
        return number and { value = tonumber(number) } or nil
    end,
}

local util = assert(loadfile("upload-mining-turtle/lib_util.lua"))()

files["/state"] = "VALID:1"
files["/state.bak"] = "VALID:0"
local saved, saveError = util.atomicWriteTable("/state", { value = 2 })
assert(saved, saveError)
assert(files["/state"] == "VALID:2" and files["/state.bak"] == "VALID:1",
    "valid primary should become the new backup")

files["/state"] = "CORRUPT"
files["/state.bak"] = "VALID:1"
failWrite = true
local failed = util.atomicWriteTable("/state", { value = 3 })
assert(not failed)
assert(files["/state.bak"] == "VALID:1",
    "failed replacement of a corrupt primary must retain the known-good backup")

print("atomic save tests passed")
