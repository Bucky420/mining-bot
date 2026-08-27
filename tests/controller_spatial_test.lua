local stored = {}
package.loaded["lib.controller_storage"] = {
    writeValue = function(file, value)
        stored[file] = value
        return { volumeId = "volume-test", file = file }
    end,
    readValue = function(entry, validator)
        local value = stored[entry.file]
        if value and (not validator or validator(value)) then return value end
        return nil, "STORAGE_FILE_INVALID"
    end,
}
fs = {
    combine = function(a, b) return tostring(a) .. "/" .. tostring(b) end,
    exists = function() return false end,
    isDir = function() return false end,
}
os.epoch = function() return 1000 end

local spatial = assert(loadfile("upload-mining-controller/controller_spatial.lua"))()
local index = {}
spatial.configure(index)

local cells = {}
for x = 7, 9 do
    for z = 7, 9 do
        cells[#cells + 1] = { x = x, y = 69, z = z, name = "minecraft:stone" }
        for y = 70, 78 do
            cells[#cells + 1] = { x = x, y = y, z = z, name = "minecraft:air" }
        end
    end
end
assert(spatial.write({
    farmId = "farm", chunkKey = "0:4:0", revision = 1,
    verifiedAt = 1000, cells = cells,
}))
assert(index.farm and index.farm["0:4:0"].volumeId == "volume-test",
    "3D chunk was not indexed by stable volume ID")
assert(spatial.classify("farm", 8, 70, 8) == "surface",
    "known open column was not classified as surface")
local oldPlan = spatial.surveyPlan("farm", 8, 8, 65, 8, 8, { x = 8, z = 8 })
assert(#oldPlan == 3, "legacy 3D data incorrectly satisfied current survey coverage")

assert(spatial.write({
    farmId = "farm", chunkKey = "0:4:0", revision = 2, verifiedAt = 2000,
    surveyVersion = 2, surveyOrigin = { x = 8, y = 70, z = 8 }, surveyRadius = 8,
    cells = cells,
}))
local currentPlan, surveyVersion = spatial.surveyPlan(
    "farm", 8, 8, 65, 8, 8, { x = 8, z = 8 }
)
assert(surveyVersion == 2 and #currentPlan == 2,
    "current scan origin did not reduce the missing-pose plan")

for _, cell in ipairs(cells) do
    if cell.y == 73 and cell.z == 8 and cell.x >= 7 and cell.x <= 9 then
        cell.name = "minecraft:stone"
    end
end
assert(spatial.write({
    farmId = "farm", chunkKey = "0:4:0", revision = 3,
    verifiedAt = 3000, cells = cells,
}))
assert(spatial.classify("farm", 8, 70, 8) == "cave",
    "known overhead terrain was not classified as cave")

local slice = spatial.slice("farm", 8, 8, 70, 4)
local tunnel
for _, cell in ipairs(slice) do
    if cell.x == 8 and cell.z == 8 then tunnel = cell break end
end
assert(tunnel and tunnel.class == "tunnel", "3D slice did not project walkable tunnel floor")

print("controller spatial tests passed")
