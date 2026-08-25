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

print("controller route tests passed")
