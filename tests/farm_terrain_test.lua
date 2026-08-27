local modulePath = "upload-mining-turtle/lib_farm_terrain.lua"
local loadTerrain = assert(loadfile(modulePath))
local terrain = loadTerrain()

local function check(condition, message)
    if not condition then error("farm terrain test failed: " .. message, 0) end
end

local function count(list)
    return #list
end

local function hasCell(list, x, z, predicate)
    for _, cell in ipairs(list) do
        if cell.x == x and cell.z == z and (not predicate or predicate(cell)) then return true end
    end
    return false
end

local function surface(x, z, class, extra)
    local result = { x = x, y = 0, z = z, surfaceY = 0, class = class, name = "minecraft:" .. class }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
end

check(terrain.inRadius(0, 0, 3, 0, 3), "circle includes radius boundary")
check(terrain.inRadius(0, 0, 0, 3, 3), "circle includes the other radius boundary")
check(not terrain.inRadius(0, 0, 3, 1, 3), "circle rejects a diagonal outside point")
check(terrain.classifyBlock({ name = "minecraft:grass_block" }) == "grass",
    "grass_block is ground, not vegetation")

local marginPlan = terrain.plan({
    surface(0, 0, "grass"), surface(3, 0, "fence"), surface(-3, 0, "grass"),
    surface(0, 1, "grass"), surface(0, -1, "grass"),
}, { center = { x = 0, z = 0 }, margin = 3 })
check(not hasCell(marginPlan.cells, 0, 0), "hard boundary applies a margin of three")
check(hasCell(marginPlan.cells, -3, 0), "negative three remains a valid circle coordinate")

local radiusPlan = terrain.plan({
    surface(-4, 0, "grass"), surface(-3, 0, "grass"), surface(3, 0, "grass"), surface(4, 0, "grass"),
}, { center = { x = 0, z = 0 }, radius = 3, margin = 0 })
check(hasCell(radiusPlan.cells, -3, 0) and hasCell(radiusPlan.cells, 3, 0),
    "plus and minus three are accepted")
check(not hasCell(radiusPlan.cells, -4, 0) and not hasCell(radiusPlan.cells, 4, 0),
    "plus and minus four are excluded by the radius")

local verticalPlan = terrain.plan({
    surface(0, 0, "grass", { surfaceY = 3 }),
    surface(1, 0, "grass", { surfaceY = -3 }),
    surface(10, 0, "grass", { surfaceY = 4 }),
    surface(13, 0, "grass", { surfaceY = 0 }),
}, { baseY = 0, maxOffset = 3, margin = 3 })
check(hasCell(verticalPlan.cells, 0, 0) and hasCell(verticalPlan.cells, 1, 0),
    "terrain within plus or minus three remains usable")
check(not hasCell(verticalPlan.cells, 10, 0), "terrain above the vertical limit is excluded")
check(not hasCell(verticalPlan.cells, 13, 0), "vertical exclusion receives a three-block margin")

local treePlan = terrain.plan({
    surface(0, 0, "grass", { clearance = { blocked = true }, occupant = { class = "tree_leaves" } }),
    surface(1, 0, "grass"),
}, { margin = 0 })
check(not hasCell(treePlan.cells, 0, 0) and hasCell(treePlan.cells, 1, 0),
    "tree canopy cell is excluded even with zero margin")
local trunkPlan = terrain.plan({
    surface(0, 0, "tree_log"), surface(1, 0, "grass"),
}, { margin = 3 })
check(hasCell(trunkPlan.cells, 1, 0), "trees do not impose a horizontal farm margin")

local waterPlan = terrain.plan({ surface(0, 0, "water"), surface(1, 0, "grass") }, { margin = 0 })
check(not hasCell(waterPlan.cells, 0, 0) and hasCell(waterPlan.cells, 1, 0),
    "water is reserved without imposing a hard margin")

local threeByThree = {}
for x = 0, 2 do for z = 0, 2 do table.insert(threeByThree, surface(x, z, "grass")) end end
local farmPlan = terrain.plan(threeByThree, { margin = 0 })
check(count(farmPlan.cells) == 8 and count(farmPlan.wormCenters) == 1,
    "valid three by three keeps all non-center cells and reserves its worm center")
check(not hasCell(farmPlan.cells, 1, 1), "worm center is not a crop cell")

local rows = terrain.alternatingRows({
    surface(0, 0, "grass"), surface(1, 0, "grass"), surface(0, 1, "grass"), surface(1, 1, "grass"),
}, { "wheat", "carrot" })
check(hasCell(rows, 0, 0, function(cell) return cell.cropId == "wheat" end)
    and hasCell(rows, 1, 1, function(cell) return cell.cropId == "carrot" end),
    "alternating rows assign one crop per row")
local oneCrop = terrain.alternatingRows({ surface(0, 0, "grass"), surface(0, 1, "grass") }, { "wheat" })
check(#oneCrop == 2 and oneCrop[1].cropId == "wheat" and oneCrop[2].cropId == "wheat",
    "one crop assigns every cell")

local rebalance = terrain.rebalancePlan({ wheat = 2, carrot = 2 }, { wheat = 1, carrot = 5 }, 6)
check(rebalance.desired.wheat == 3 and rebalance.desired.carrot == 3,
    "rebalance equalizes active crops")
check(rebalance.replacements.wheat <= 1 and rebalance.replacements.carrot <= 5,
    "rebalance replacements are bounded by seeds")

local island = { surface(0, 0, "stone") }
for _, point in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    table.insert(island, surface(point[1], point[2], "grass"))
end
local islandPlan = terrain.plan(island, { margin = 0 })
check(hasCell(islandPlan.cells, 0, 0, function(cell) return cell.action == "replace" end),
    "enclosed one-cell stone island is replaceable")
local openPlan = terrain.plan({ surface(0, 0, "stone"), surface(1, 0, "grass"), surface(0, 1, "grass") }, { margin = 0 })
check(not hasCell(openPlan.cells, 0, 0), "open stone is not replaceable")
local openMarginPlan = terrain.plan({
    surface(0, 0, "stone"), surface(3, 0, "grass"),
}, { margin = 3 })
check(not hasCell(openMarginPlan.cells, 3, 0), "unsafe stone receives a three-block margin")
local structurePlan = terrain.plan({
    surface(0, 0, "stone", { verticalStructure = true }),
    surface(1, 0, "grass"), surface(-1, 0, "grass"),
    surface(0, 1, "grass"), surface(0, -1, "grass"),
}, { margin = 0 })
check(not hasCell(structurePlan.cells, 0, 0), "vertical stone structures are never islands")

local hole = { surface(0, 0, "air", { surfaceY = 0 }) }
for _, point in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    table.insert(hole, surface(point[1], point[2], "grass", { surfaceY = 3 }))
end
local holePlan = terrain.plan(hole, { margin = 0, baseY = 0, maxOffset = 3 })
check(hasCell(holePlan.cells, 0, 0, function(cell) return cell.action == "fill" end),
    "enclosed depth-three hole is fillable")

local sweep = terrain.surveySweepPoints({ x = 0, z = 0 }, 32, 6, 5)
check(#sweep > 20, "survey sweep covers a radius-32 farm")
local longestRun, currentRun, previousDirection = 0, 0
for index, point in ipairs(sweep) do
    check(terrain.inRadius(0, 0, point.x, point.z, 32), "survey waypoint remains inside farm radius")
    check(point.y == 5, "survey waypoint keeps cruise altitude")
    if index > 1 then
        local previous = sweep[index - 1]
        local dx, dz = point.x - previous.x, point.z - previous.z
        check(dx == 0 or dz == 0, "survey joins waypoints with L-shaped axis segments")
        check(math.abs(dx) + math.abs(dz) <= 6, "survey waypoint remains inside scanner overlap")
        local direction = dx > 0 and "east" or dx < 0 and "west"
            or dz > 0 and "south" or "north"
        if direction == previousDirection then currentRun = currentRun + 1
        else currentRun = 1 previousDirection = direction end
        longestRun = math.max(longestRun, currentRun)
    end
end
check(longestRun >= 5, "survey sweep contains long straight runs")
local reducedOverlapSweep = terrain.surveySweepPoints({ x = 0, z = 0 }, 32, 8, 5)
check(#reducedOverlapSweep < #sweep,
    "radius-eight survey spacing reduces redundant scan centers")
for index = 2, #reducedOverlapSweep do
    local previous, point = reducedOverlapSweep[index - 1], reducedOverlapSweep[index]
    check(math.abs(point.x - previous.x) + math.abs(point.z - previous.z) <= 8,
        "reduced-overlap survey remains reachable from the previous scan")
end
check(#terrain.surveySweepPoints({ x = 0.5, z = 0 }, 32, 6, 5) == 0,
    "survey sweep rejects fractional Minecraft coordinates")
local shortScannerSweep = terrain.surveySweepPoints({ x = 0, z = 0 }, 3, 1, 5)
for index = 2, #shortScannerSweep do
    local previous, point = shortScannerSweep[index - 1], shortScannerSweep[index]
    check(math.abs(point.x - previous.x) + math.abs(point.z - previous.z) <= 1,
        "radius-one scanner sweep retains overlap")
end

local openCells = {}
for x = 0, 5 do for z = 0, 5 do openCells[("%d:%d"):format(x, z)] = true end end
local lPath = terrain.turnEfficientPath(openCells, { x = 0, z = 0 }, { x = 5, z = 5 }, "east", 2)
local pathTurns, previousHeading = 0
local previousPoint = { x = 0, z = 0 }
for _, point in ipairs(lPath) do
    local heading = point.x > previousPoint.x and "east" or point.x < previousPoint.x and "west"
        or point.z > previousPoint.z and "south" or "north"
    if previousHeading and heading ~= previousHeading then pathTurns = pathTurns + 1 end
    previousHeading, previousPoint = heading, point
end
check(pathTurns == 1, "open navigation uses one large L with a single turn")

local routeChoices = {}
for _, point in ipairs({
    { 0, 0 }, { 1, 0 }, { 1, -1 }, { 2, -1 }, { 3, -1 }, { 3, 0 }, { 4, 0 },
    { 0, 1 }, { 0, 2 }, { 1, 2 }, { 2, 2 }, { 3, 2 }, { 4, 2 }, { 4, 1 },
}) do routeChoices[("%d:%d"):format(point[1], point[2])] = true end
local lowTurnPath = terrain.turnEfficientPath(
    routeChoices, { x = 0, z = 0 }, { x = 4, z = 0 }, "south", 2
)
check(hasCell(lowTurnPath, 2, 2), "navigation prefers a longer route when it avoids repeated turns")
local recoveryPath = terrain.turnEfficientPath(
    { ["1:0"] = true, ["2:0"] = true }, { x = 0, z = 0 }, { x = 2, z = 0 }, "east", 2
)
check(#recoveryPath == 2 and recoveryPath[1].x == 1,
    "navigation can safely leave a current cell which was later excluded")
check(terrain.turnEfficientPath(
    { ["1:0"] = true }, { x = 0, z = 0 }, { x = 2, z = 0 }, "east", 2
) == nil, "navigation rejects disconnected or disallowed destinations")
for index, point in ipairs(lowTurnPath) do
    check(routeChoices[("%d:%d"):format(point.x, point.z)], "navigation path only enters allowed cells")
    local previous = index == 1 and { x = 0, z = 0 } or lowTurnPath[index - 1]
    check(math.abs(point.x - previous.x) + math.abs(point.z - previous.z) == 1,
        "navigation path moves through adjacent cells")
end

local cachedColumns, cachedTiles = {}, {}
for scan = 1, 6 do
    local columnKey = tostring(scan) .. ":0"
    cachedColumns[columnKey] = "surface-" .. tostring(scan)
    cachedColumns, cachedTiles = terrain.retainScanTiles(
        cachedColumns, cachedTiles, { columnKey }, 4
    )
end
check(#cachedTiles == 4, "scan cache retains exactly four newest tiles")
check(cachedColumns["1:0"] == nil and cachedColumns["2:0"] == nil
    and cachedColumns["3:0"] ~= nil and cachedColumns["6:0"] ~= nil,
    "scan cache evicts columns no longer referenced by a retained tile")
cachedColumns["shared:0"] = "newest"
cachedColumns, cachedTiles = terrain.retainScanTiles(
    cachedColumns, cachedTiles, { "shared:0" }, 4
)
cachedColumns, cachedTiles = terrain.retainScanTiles(
    cachedColumns, cachedTiles, { "shared:0", "latest:0" }, 4
)
check(cachedColumns["shared:0"] == "newest",
    "overlapping scan columns survive while any retained tile references them")

print("farm terrain tests passed")
