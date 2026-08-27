local route = assert(loadfile("upload-mining-controller/controller_route.lua"))()

local cells = {}
for x = 0, 4 do
    for z = 0, 2 do cells[("%d:%d"):format(x, z)] = { x = x, y = 70, z = z, class = "grass" } end
end
cells["2:0"].class = "fence"
cells["2:1"].occupant = "minecraft:oak_leaves"

local path = route.find(cells, { x = 0, z = 0 }, { x = 4, z = 0 }, "east")
assert(path and #path == 8, "controller should route around unsafe terrain")
local previous = { x = 0, z = 0 }
for _, point in ipairs(path) do
    assert(math.abs(point.x - previous.x) + math.abs(point.z - previous.z) == 1)
    local cell = cells[("%d:%d"):format(point.x, point.z)]
    assert(cell.class ~= "fence" and cell.occupant ~= "minecraft:oak_leaves")
    previous = point
end
assert(previous.x == 4 and previous.z == 0)
assert(route.find(cells, { x = 0, z = 0 }, { x = 2, z = 0 }, "east") == nil,
    "controller should reject an unsafe destination")

local occupied = { ["2:70:0"] = true }
local function read3D(x, y, z)
    if y < 70 or y > 71 or x < 0 or x > 4 or math.abs(z) > 1 then return nil end
    if occupied[("%d:%d:%d"):format(x, y, z)] then return { name = "minecraft:stone" } end
    return { name = "minecraft:air" }
end
local path3D = assert(route.find3D(
    { x = 0, y = 70, z = 0 }, { x = 4, y = 70, z = 0 }, read3D, {}
))
previous = { x = 0, y = 70, z = 0 }
for _, point in ipairs(path3D) do
    assert(math.abs(point.x - previous.x) + math.abs(point.y - previous.y)
        + math.abs(point.z - previous.z) == 1, "3D path contains non-adjacent points")
    assert(not occupied[("%d:%d:%d"):format(point.x, point.y, point.z)],
        "3D route entered an occupied cell")
    previous = point
end
assert(previous.x == 4 and previous.y == 70 and previous.z == 0)

local excluded = { ["1:70:0"] = true, ["1:70:1"] = true, ["1:70:-1"] = true }
local raised = assert(route.find3D(
    { x = 0, y = 70, z = 0 }, { x = 4, y = 70, z = 0 }, read3D, excluded
))
local usedVertical = false
for _, point in ipairs(raised) do if point.y == 71 then usedVertical = true end end
assert(usedVertical, "3D route did not use vertical space around reserved cells")

print("controller route tests passed")
