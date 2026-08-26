local data = {
    position = { x = 0, y = 5, z = 0 },
    heading = "east",
    movesSinceGps = 0,
}

local config = {
    gps = { timeout = 0, debug = false, resyncMoves = 1000 },
    movement = { retries = 1, retryDelay = 0, digRetries = 1, routeOrder = { "x", "z", "y" } },
    inventory = { startupFuel = 0 },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

package.preload["config"] = function() return config end
package.preload["lib.inventory"] = function()
    return {
        hasPeripheralType = function() return true end,
        freeSlots = function() return 16 end,
    }
end
package.preload["lib.markers"] = function()
    return { isProtectedBlock = function() return false end }
end
package.preload["lib.state"] = function()
    return {
        get = function() return data end,
        save = function() return true end,
        setStatus = function() end,
        setError = function() end,
    }
end
package.preload["lib.util"] = function()
    return { copy = copy, now = function() return 1 end, log = function() end }
end

local occupied = {}
local successfulPositions = {}
local vectors = {
    north = { x = 0, z = -1 }, east = { x = 1, z = 0 },
    south = { x = 0, z = 1 }, west = { x = -1, z = 0 },
}
local function key(x, y, z) return table.concat({ x, y, z }, ":") end
local function target(kind)
    local position = data.position
    if kind == "up" then return position.x, position.y + 1, position.z end
    if kind == "down" then return position.x, position.y - 1, position.z end
    local vector = vectors[data.heading]
    return position.x + vector.x, position.y, position.z + vector.z
end
local function move(kind)
    local x, y, z = target(kind)
    if occupied[key(x, y, z)] then return false end
    successfulPositions[#successfulPositions + 1] = { x = x, y = y, z = z }
    return true
end
local function inspect(kind)
    local x, y, z = target(kind)
    if occupied[key(x, y, z)] then return true, { name = "test:obstacle" } end
    return false
end

turtle = {
    forward = function() return move("forward") end,
    back = function() return false end,
    up = function() return move("up") end,
    down = function() return move("down") end,
    inspect = function() return inspect("forward") end,
    inspectUp = function() return inspect("up") end,
    inspectDown = function() return inspect("down") end,
    dig = function() return false end,
    digUp = function() return false end,
    digDown = function() return false end,
    attack = function() return false end,
    attackUp = function() return false end,
    attackDown = function() return false end,
    turnLeft = function() return true end,
    turnRight = function() return true end,
    getFuelLevel = function() return "unlimited" end,
}
gps = { locate = function() return data.position.x, data.position.y, data.position.z end }
sleep = function() end

for y = 5, 8 do occupied[key(2, y, 0)] = true end
local nav = assert(loadfile("upload-mining-turtle/lib_nav.lua"))()
local ok, reason = nav.overflyXYZ(4, 5, 0, { maximumY = 12 })
assert(ok, tostring(reason))
assert(data.position.x == 4 and data.position.y == 5 and data.position.z == 0,
    "overflight did not reach and descend at the destination")
local furthestX = -math.huge
for _, position in ipairs(successfulPositions) do
    assert(position.x >= furthestX, "overflight backtracked horizontally")
    furthestX = position.x
end
assert(furthestX == 4, "overflight did not cross the obstacle")

data.position, data.heading, data.movesSinceGps = { x = 0, y = 5, z = 0 }, "east", 0
successfulPositions = {}
occupied = {
    [key(1, 5, 0)] = true,
    [key(0, 6, 0)] = true,
}
ok, reason = nav.overflyXYZ(2, 5, 0, { maximumY = 12 })
assert(not ok and reason == "OVERFLIGHT_ASCENT_BLOCKED", tostring(reason))
assert(#successfulPositions == 0, "blocked overflight should not guess a route")

print("navigation overflight test passed")
