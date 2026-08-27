local spatial = assert(loadfile("upload-mining-turtle/lib_spatial_map.lua"))()

local function check(condition, message)
    if not condition then error("spatial map test failed: " .. message, 0) end
end

local function scan(origin, radius, blocks)
    local result = {}
    for x = -radius, radius do
        for y = -radius, radius do
            for z = -radius, radius do
                if x * x + y * y + z * z <= radius * radius then
                    result[#result + 1] = {
                        x = origin.x + x, y = origin.y + y, z = origin.z + z,
                        name = "minecraft:air",
                    }
                end
            end
        end
    end
    for _, block in ipairs(blocks or {}) do result[#result + 1] = block end
    return { origin = origin, radius = radius, blocks = result }
end

local map = spatial.new(3)
local observed, observeError = map:observe(scan({ x = 0, y = 5, z = 0 }, 8, {
    { x = 2, y = 5, z = 0, name = "minecraft:spruce_log" },
    { x = 2, y = 6, z = 0, name = "minecraft:spruce_log" },
}), { x = 0, y = 5, z = 0 })
check(observed, tostring(observeError))

local path, destination, pathError = map:path(
    { x = 0, y = 5, z = 0 },
    { { x = 6, y = 5, z = 0 } },
    { minimumY = 4, maximumY = 8 }
)
check(path ~= nil and destination.x == 6, tostring(pathError))
local previous = { x = 0, y = 5, z = 0 }
for _, point in ipairs(path) do
    check(math.abs(point.x - previous.x) + math.abs(point.y - previous.y)
        + math.abs(point.z - previous.z) == 1, "route contains a non-adjacent move")
    check(not (point.x == 2 and point.z == 0 and (point.y == 5 or point.y == 6)),
        "route entered a scanned obstacle")
    previous = point
end

local alternatePath, alternate = map:path(
    { x = 0, y = 5, z = 0 },
    {
        { x = 2, y = 5, z = 0, penalty = 0 },
        { x = 2, y = 5, z = 1, penalty = 5 },
    },
    { minimumY = 4, maximumY = 8 }
)
check(alternatePath ~= nil and alternate.z == 1,
    "blocked scan center did not select nearby known air")

check(map:isKnown({ x = 8, y = 5, z = 0 }), "scan sphere boundary is known")
check(not map:isKnown({ x = 8, y = 6, z = 0 }), "outside of scan sphere is unknown")
check(not map:isPassable({ x = 2, y = 5, z = 0 }), "occupied cell is not passable")

map:observe(scan({ x = 0, y = 5, z = 0 }, 8, {}), { x = 0, y = 5, z = 0 })
check(map:isPassable({ x = 2, y = 5, z = 0 }), "new scan clears stale occupancy")

map:observe(scan({ x = 48, y = 5, z = 0 }, 8, {}), { x = 48, y = 5, z = 0 })
check(not map:isKnown({ x = 0, y = 5, z = 0 }), "rolling three-chunk window evicts distant scans")
local frontier = map:frontierGoals(
    { x = 48, y = 5, z = 0 }, { x = 60, y = 5, z = 0 }, { minimumY = 4, maximumY = 8 }
)
check(#frontier > 0 and frontier[1].x > 48,
    "frontier navigation did not select known air closer to the survey target")
check(#frontier <= 64, "frontier navigation returned an unbounded A* goal set")
local escape = map:frontierGoals(
    { x = 48, y = 5, z = 0 }, { x = 40, y = 5, z = 0 },
    { minimumY = 4, maximumY = 8, allowNotCloser = true }
)
check(#escape > 0, "escape navigation could not select known air when progress was blocked")
map:markOccupied({ x = 49, y = 5, z = 0 }, "minecraft:spruce_leaves")
check(map:nearHorizontalName({ x = 48, y = 5, z = 0 }, "leaves", 1),
    "survey map did not identify a leaf-enclosed scan center")
local preferredFrontier = map:frontierGoals(
    { x = 48, y = 5, z = 0 }, { x = 60, y = 5, z = 0 },
    { minimumY = 4, maximumY = 8, preferredMinimumY = 6, preferredMaximumY = 7 }
)
check(#preferredFrontier > 0 and preferredFrontier[1].y >= 6,
    "frontier navigation did not prefer the survey cruise band")
local excludedKey = ("%d:%d:%d"):format(
    preferredFrontier[1].x, preferredFrontier[1].y, preferredFrontier[1].z
)
local nextFrontier = map:frontierGoals(
    { x = 48, y = 5, z = 0 }, { x = 60, y = 5, z = 0 },
    { minimumY = 4, maximumY = 8, excluded = { [excludedKey] = true } }
)
check(#nextFrontier == 0 or nextFrontier[1].x ~= preferredFrontier[1].x
    or nextFrontier[1].y ~= preferredFrontier[1].y
    or nextFrontier[1].z ~= preferredFrontier[1].z,
    "frontier navigation selected an already-scanned center")

local imported = spatial.new(3)
imported:prepare({ x = 0, y = 5, z = 0 })
local importedOk, importedError = imported:importChunk("0:0:0", {
    { x = 1, y = 1, z = 1, name = "minecraft:air" },
}, 100, 3)
check(importedOk, tostring(importedError))
check(imported:isKnown({ x = 1, y = 1, z = 1 }), "controller chunk imports known air")
check(imported:chunkAge("0:0:0", 101) == 1, "chunk freshness age is tracked")
check(imported:chunkChanges("0:0:0") == 3, "chunk change history is tracked")

print("spatial map tests passed")
