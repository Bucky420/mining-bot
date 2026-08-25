local stored

package.preload["config"] = function()
    return {
        schemaVersion = 1,
        paths = { state = "/data/worker.state" },
    }
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("cycle") end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    seen[value] = nil
    return result
end

package.preload["lib.util"] = function()
    return {
        now = function() return 1000 end,
        detachedCopy = copy,
        atomicWriteTable = function(_, value) stored = copy(value) return true end,
        readTable = function() return stored and copy(stored) or nil, "missing" end,
        log = function() end,
    }
end

fs = {
    exists = function(path) return path == "/data/worker.state" and stored ~= nil end,
    delete = function() end,
    copy = function() end,
}
os.getComputerID = function() return 12 end

local state = assert(loadfile("upload-mining-turtle/lib_state.lua"))()
local data = state.load()
data.status = "WORKING"
data.currentJob = {
    id = "farm", type = "FARM_SERVICE", status = "RUNNING",
    progress = {
        surfaceColumns = { ["1:2"] = "70,g,1,-,0,0,0" },
        navAllowed = { ["1:2"] = true, ["2:2"] = false },
        planFormat = 1,
        plan = { { 1, 2, 70, "g", "-", 0, 1, 0, "-", 0, 0 } },
    },
}
data.reportOutbox = {
    {
        type = "FARM_MAP",
        payload = {
            delta = {
                {
                    x = 1, y = 70, z = 2, name = "minecraft:grass_block", class = "grass",
                    occupant = "minecraft:wheat", occupantClass = "crop", occupantY = 71,
                    verticalStructure = false,
                },
            },
        },
    },
}
state.save()

local savedProgress = stored.currentJob.progress
assert(savedProgress.surfaceColumns == nil and type(savedProgress.surfaceColumnBlob) == "string")
assert(savedProgress.navAllowed == nil and type(savedProgress.navAllowedBlob) == "string")
assert(savedProgress.plan == nil and type(savedProgress.planBlob) == "string")
assert(stored.reportOutbox[1].payload.delta == nil)
assert(type(stored.reportOutbox[1].payload.deltaBlob) == "string")

package.loaded["lib.state"] = nil
local reloadedState = assert(loadfile("upload-mining-turtle/lib_state.lua"))()
local reloaded = reloadedState.load()
local progress = reloaded.currentJob.progress
assert(progress.surfaceColumns["1:2"] == "70,g,1,-,0,0,0")
assert(progress.navAllowed["1:2"] == true and progress.navAllowed["2:2"] == nil)
assert(progress.plan[1][1] == 1 and progress.plan[1][4] == "g")
assert(reloaded.reportOutbox[1].payload.delta[1].name == "minecraft:grass_block")
assert(reloaded.reportOutbox[1].payload.delta[1].occupantClass == "crop"
    and reloaded.reportOutbox[1].payload.delta[1].occupantY == 71)

print("state compaction tests passed")
