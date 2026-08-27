local files, directories = {}, { [""] = true, disk = true, disk2 = true, disk3 = true }
local capacities = { disk = 1000000, disk2 = 1000000, disk3 = 125000 }
local serialized, nextToken = {}, 1

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[copy(key)] = copy(item) end
    return result
end

local function normalize(path)
    return tostring(path):gsub("^/", ""):gsub("/+", "/"):gsub("/$", "")
end

fs = {}
function fs.combine(left, right)
    left, right = normalize(left), normalize(right)
    return left == "" and right or right == "" and left or left .. "/" .. right
end
function fs.getDir(path) return normalize(path):match("^(.*)/[^/]+$") or "" end
function fs.exists(path) path = normalize(path) return files[path] ~= nil or directories[path] == true end
function fs.isDir(path) return directories[normalize(path)] == true end
function fs.isReadOnly() return false end
function fs.makeDir(path)
    path = normalize(path)
    local current = ""
    for part in path:gmatch("[^/]+") do current = fs.combine(current, part) directories[current] = true end
end
function fs.delete(path) files[normalize(path)] = nil end
function fs.move(from, to)
    from, to = normalize(from), normalize(to)
    assert(files[from], "missing source " .. from)
    assert(not files[to], "destination exists " .. to)
    files[to], files[from] = files[from], nil
end
function fs.getCapacity(path)
    local root = normalize(path):match("^[^/]+") or ""
    return capacities[root]
end
function fs.getFreeSpace(path)
    local root = normalize(path):match("^[^/]+") or ""
    local used = 0
    for file, contents in pairs(files) do
        if file == root or file:sub(1, #root + 1) == root .. "/" then used = used + #contents end
    end
    return (capacities[root] or 1000000) - used
end
function fs.open(path, mode)
    path = normalize(path)
    if mode == "r" then
        if not files[path] then return nil end
        return { readAll = function() return files[path] end, close = function() end }
    end
    local buffer = ""
    return {
        write = function(value) buffer = buffer .. tostring(value) end,
        flush = function() end,
        close = function() files[path] = buffer end,
    }
end

textutils = {}
function textutils.serialize(value)
    local token = "serialized-" .. tostring(nextToken)
    nextToken = nextToken + 1
    serialized[token] = copy(value)
    return token
end
function textutils.unserialize(token) return serialized[token] and copy(serialized[token]) or nil end

local drives = {
    drive_a = { mount = "disk", label = "terrain-a" },
    drive_b = { mount = "disk2", label = "terrain-b" },
    drive_floppy = { mount = "disk3", label = "floppy", id = 7 },
}
peripheral = {}
function peripheral.getNames() return { "drive_a", "drive_b", "drive_floppy" } end
function peripheral.getType(name) return drives[name] and "drive" or nil end
function peripheral.wrap(name)
    local value = drives[name]
    return value and {
        hasData = function() return true end,
        getDiskID = function() return value.id end,
        getMountPath = function() return value.mount end,
        getDiskLabel = function() return value.label end,
    } or nil
end
os.getComputerID = function() return 99 end
os.epoch = function() return nextToken * 1000 end

local storage = assert(loadfile("upload-mining-controller/controller_storage.lua"))()
local volumes = storage.describe()
assert(#volumes == 2, "computer volumes should be discovered and floppies excluded")

local farm = {
    revision = 4,
    updatedAt = 100,
    data = {
        farmId = "farm:test", center = { x = 0, z = 0 }, radius = 8,
        cells = {
            ["1:2"] = {
                x = 1, y = 70, z = 2, name = "minecraft:grass_block", class = "grass",
                occupant = "minecraft:wheat", occupantClass = "crop", occupantY = 71,
            },
        },
    },
}
local reference, writeError = storage.writeFarm("farm:test", farm)
assert(reference, writeError)
local loaded, readError = storage.readFarm(reference)
assert(loaded, readError)
assert(loaded.revision == 4 and loaded.data.cells["1:2"].occupant == "minecraft:wheat",
    "terrain region should survive compact storage round trip")

local spatialValue = { version = 1, farmId = "farm:test", chunkKey = "0:4:0", cells = {} }
local spatialReference, spatialError = storage.writeValue(
    "bucky/terrain-3d/farm/chunk.map", spatialValue, nil,
    function(value) return value.version == 1 and type(value.cells) == "table" end
)
assert(spatialReference, spatialError)
local loadedSpatial = assert(storage.readValue(spatialReference, function(value)
    return value.farmId == "farm:test"
end))
assert(loadedSpatial.chunkKey == "0:4:0", "generic 3D storage did not round trip")
local stats = storage.stats(8)
assert(stats.connected == 2 and stats.maximum == 8 and stats.capacity == 2000000,
    "storage statistics did not aggregate mounted computer volumes")

local selectedDrive
for _, volume in ipairs(storage.describe()) do
    if volume.id == reference.volumeId then selectedDrive = volume.drive break end
end
drives[selectedDrive] = nil
local missing, missingError = storage.readFarm(reference)
assert(missing == nil and missingError == "TERRAIN_VOLUME_MISSING",
    "missing mounted computer should not be silently replaced")

print("controller storage tests passed")
