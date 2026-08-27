-- RAM-only rolling occupancy map and path planner for Geo Scanner movement.
local spatial = {}

local function now()
    return os.epoch and os.epoch("utc") or 0
end

local directions = {
    { x = 1, y = 0, z = 0, cost = 10 },
    { x = -1, y = 0, z = 0, cost = 10 },
    { x = 0, y = 0, z = 1, cost = 10 },
    { x = 0, y = 0, z = -1, cost = 10 },
    { x = 0, y = 1, z = 0, cost = 12 },
    { x = 0, y = -1, z = 0, cost = 12 },
}

local function key(x, y, z)
    return ("%d:%d:%d"):format(x, y, z)
end

local function chunkCoordinate(value)
    return math.floor(value / 16)
end

local function chunkKey(x, y, z)
    return ("%d:%d:%d"):format(chunkCoordinate(x), chunkCoordinate(y), chunkCoordinate(z))
end

local function integer(value)
    return type(value) == "number" and value == math.floor(value)
end

local function insideSphere(point, origin, radius)
    local dx, dy, dz = point.x - origin.x, point.y - origin.y, point.z - origin.z
    return dx * dx + dy * dy + dz * dz <= radius * radius
end

local function isAir(name)
    return name == "minecraft:air" or name == "minecraft:cave_air"
        or name == "minecraft:void_air"
end

local function chunkBounds(position, chunkCount)
    local radius = math.floor(chunkCount / 2)
    local chunkX, chunkZ = math.floor(position.x / 16), math.floor(position.z / 16)
    return {
        minimumX = (chunkX - radius) * 16,
        maximumX = (chunkX + radius + 1) * 16 - 1,
        minimumZ = (chunkZ - radius) * 16,
        maximumZ = (chunkZ + radius + 1) * 16 - 1,
    }
end

local function inBounds(bounds, x, z)
    return x >= bounds.minimumX and x <= bounds.maximumX
        and z >= bounds.minimumZ and z <= bounds.maximumZ
end

local Map = {}
Map.__index = Map

function spatial.new(chunkCount)
    chunkCount = math.floor(tonumber(chunkCount) or 3)
    if chunkCount < 1 or chunkCount % 2 == 0 then chunkCount = 3 end
    return setmetatable({
        chunkCount = chunkCount,
        scans = {},
        known = {},
        knownAt = {},
        chunkVerifiedAt = {},
        chunkChangeCount = {},
        occupied = {},
        bounds = nil,
    }, Map)
end

function spatial.chunkKey(x, y, z)
    return chunkKey(x, y, z)
end

function Map:prune(focus)
    self.bounds = chunkBounds(focus, self.chunkCount)
    for blockKey, block in pairs(self.occupied) do
        if not inBounds(self.bounds, block.x, block.z) then self.occupied[blockKey] = nil end
    end
    for knownKey, block in pairs(self.known) do
        if not inBounds(self.bounds, block.x, block.z) then self.known[knownKey] = nil end
    end
    local retained = {}
    for _, scan in ipairs(self.scans) do
        if scan.x + scan.radius >= self.bounds.minimumX
            and scan.x - scan.radius <= self.bounds.maximumX
            and scan.z + scan.radius >= self.bounds.minimumZ
            and scan.z - scan.radius <= self.bounds.maximumZ then
            retained[#retained + 1] = scan
        end
    end
    self.scans = retained
end

function Map:observe(result, focus)
    if type(result) ~= "table" or type(result.origin) ~= "table"
        or not integer(result.origin.x) or not integer(result.origin.y)
        or not integer(result.origin.z) or not integer(result.radius)
        or result.radius < 1 or type(result.blocks) ~= "table" then
        return false, "INVALID_SPATIAL_SCAN"
    end
    focus = focus or result.origin
    self:prune(focus)

    for blockKey, block in pairs(self.occupied) do
        if insideSphere(block, result.origin, result.radius) then self.occupied[blockKey] = nil end
    end
    for knownKey, block in pairs(self.known) do
        if insideSphere(block, result.origin, result.radius) then self.known[knownKey] = nil end
    end
    for _, block in ipairs(result.blocks) do
        if type(block) ~= "table" or not integer(block.x) or not integer(block.y)
            or not integer(block.z) or type(block.name) ~= "string" then
            return false, "INVALID_SPATIAL_BLOCK"
        end
        if insideSphere(block, result.origin, result.radius)
            and inBounds(self.bounds, block.x, block.z) then
            local blockKey = key(block.x, block.y, block.z)
            self.known[blockKey] = {
                x = block.x, y = block.y, z = block.z, name = block.name,
            }
            self.knownAt[blockKey] = now()
            self.chunkVerifiedAt[chunkKey(block.x, block.y, block.z)] = self.knownAt[blockKey]
            if isAir(block.name) then
                self.occupied[blockKey] = nil
            else
                self.occupied[blockKey] = self.known[blockKey]
            end
        end
    end

    local scanKey = key(result.origin.x, result.origin.y, result.origin.z)
    for index = #self.scans, 1, -1 do
        local scan = self.scans[index]
        if key(scan.x, scan.y, scan.z) == scanKey then table.remove(self.scans, index) end
    end
    self.scans[#self.scans + 1] = {
        x = result.origin.x, y = result.origin.y, z = result.origin.z,
        radius = result.radius,
    }
    return true
end

function Map:markOccupied(point, name)
    if self.bounds and inBounds(self.bounds, point.x, point.z) then
        self.occupied[key(point.x, point.y, point.z)] = {
            x = point.x, y = point.y, z = point.z, name = name or "unknown",
        }
        self.known[key(point.x, point.y, point.z)] = self.occupied[key(point.x, point.y, point.z)]
    end
end

function Map:markChanged(point, name)
    if not self.bounds or not inBounds(self.bounds, point.x, point.z) then return end
    local blockKey = key(point.x, point.y, point.z)
    local block = { x = point.x, y = point.y, z = point.z, name = name or "minecraft:air" }
    self.known[blockKey] = block
    self.knownAt[blockKey] = now()
    self.chunkVerifiedAt[chunkKey(point.x, point.y, point.z)] = self.knownAt[blockKey]
    if isAir(block.name) then self.occupied[blockKey] = nil else self.occupied[blockKey] = block end
end

function Map:isKnown(point)
    if not self.bounds or not inBounds(self.bounds, point.x, point.z) then return false end
    return self.known[key(point.x, point.y, point.z)] ~= nil
end

function Map:isPassable(point)
    return self:isKnown(point) and self.occupied[key(point.x, point.y, point.z)] == nil
end

function Map:nearHorizontalName(point, fragment, radius)
    radius = math.max(0, math.floor(tonumber(radius) or 1))
    for dx = -radius, radius do
        for dz = -radius, radius do
            local block = self.known[key(point.x + dx, point.y, point.z + dz)]
            if block and not isAir(block.name) and block.name:find(fragment, 1, true) then return true end
        end
    end
    return false
end

function Map:chunkKeys(points)
    local result, seen = {}, {}
    for _, point in ipairs(points or {}) do
        local value = chunkKey(point.x, point.y, point.z)
        if not seen[value] then seen[value] = true result[#result + 1] = value end
    end
    return result
end

function Map:chunkCells(value)
    local result = {}
    for _, block in pairs(self.known) do
        if chunkKey(block.x, block.y, block.z) == value then
            result[#result + 1] = { x = block.x, y = block.y, z = block.z, name = block.name }
        end
    end
    table.sort(result, function(a, b)
        return a.x == b.x and (a.y == b.y and a.z < b.z or a.y < b.y) or a.x < b.x
    end)
    return result
end

function Map:chunkAge(value, at)
    local verified = self.chunkVerifiedAt[value]
    if not verified then return math.huge end
    return math.max(0, (tonumber(at) or now()) - verified)
end

function Map:chunkChanges(value)
    return tonumber(self.chunkChangeCount[value]) or 0
end

function Map:frontierGoals(start, target, options)
    options = options or {}
    local minimumY = math.floor(tonumber(options.minimumY) or -64)
    local maximumY = math.floor(tonumber(options.maximumY) or 320)
    local preferredMinimumY = tonumber(options.preferredMinimumY)
    local preferredMaximumY = tonumber(options.preferredMaximumY)
    local excluded = type(options.excluded) == "table" and options.excluded or {}
    local allowNotCloser = options.allowNotCloser == true
    local startDistance = math.abs(start.x - target.x) + math.abs(start.y - target.y)
        + math.abs(start.z - target.z)
    local goals = {}
    local inspected = 0
    for _, block in pairs(self.known) do
        inspected = inspected + 1
        if inspected % 512 == 0 and type(sleep) == "function" then sleep(0) end
        if block.y >= minimumY and block.y <= maximumY and isAir(block.name)
            and not excluded[key(block.x, block.y, block.z)]
            and (block.x ~= start.x or block.y ~= start.y or block.z ~= start.z) then
            local distance = math.abs(block.x - target.x) + math.abs(block.y - target.y)
                + math.abs(block.z - target.z)
            if preferredMinimumY and preferredMaximumY then
                if block.y < preferredMinimumY then distance = distance + (preferredMinimumY - block.y) * 8 end
                if block.y > preferredMaximumY then distance = distance + (block.y - preferredMaximumY) * 8 end
            end
            if allowNotCloser or distance < startDistance then
                goals[#goals + 1] = { x = block.x, y = block.y, z = block.z, penalty = distance }
            end
        end
    end
    table.sort(goals, function(a, b)
        if a.penalty ~= b.penalty then return a.penalty < b.penalty end
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)
    local maximumGoals = math.max(1, math.floor(tonumber(options.maximumGoals) or 64))
    while #goals > maximumGoals do table.remove(goals) end
    return goals
end

function Map:prepare(focus)
    self:prune(focus)
end

function Map:importChunk(value, cells, verifiedAt, changeCount)
    if type(value) ~= "string" or type(cells) ~= "table" then return false, "INVALID_SPATIAL_CHUNK" end
    for _, block in ipairs(cells) do
        if type(block) ~= "table" or not integer(block.x) or not integer(block.y)
            or not integer(block.z) or type(block.name) ~= "string"
            or chunkKey(block.x, block.y, block.z) ~= value then
            return false, "INVALID_SPATIAL_CHUNK_CELL"
        end
    end
    for _, block in ipairs(cells) do
        local blockKey = key(block.x, block.y, block.z)
        -- Fresh local scans win over older controller snapshots. The next
        -- local scan will replace these cells when the chunk is stale.
        if not self.known[blockKey] then
            self.known[blockKey] = { x = block.x, y = block.y, z = block.z, name = block.name }
            self.knownAt[blockKey] = tonumber(verifiedAt) or 0
            if isAir(block.name) then
                self.occupied[blockKey] = nil
            else
                self.occupied[blockKey] = self.known[blockKey]
            end
        end
    end
    self.chunkVerifiedAt[value] = math.max(self.chunkVerifiedAt[value] or 0, tonumber(verifiedAt) or 0)
    self.chunkChangeCount[value] = math.max(
        self.chunkChangeCount[value] or 0, tonumber(changeCount) or 0
    )
    return true
end

local function push(heap, entry)
    heap[#heap + 1] = entry
    local index = #heap
    while index > 1 do
        local parent = math.floor(index / 2)
        if heap[parent].priority <= entry.priority then break end
        heap[index] = heap[parent]
        index = parent
    end
    heap[index] = entry
end

local function pop(heap)
    local result, tail = heap[1], table.remove(heap)
    if #heap == 0 then return result end
    local index = 1
    while index * 2 <= #heap do
        local child = index * 2
        if child < #heap and heap[child + 1].priority < heap[child].priority then child = child + 1 end
        if heap[child].priority >= tail.priority then break end
        heap[index] = heap[child]
        index = child
    end
    heap[index] = tail
    return result
end

function Map:path(start, goals, options)
    options = options or {}
    if type(start) ~= "table" or type(goals) ~= "table" or #goals == 0 then
        return nil, nil, "INVALID_SPATIAL_ROUTE"
    end
    self:prune(start)
    local goalByKey, usableGoals = {}, {}
    for _, goal in ipairs(goals) do
        if integer(goal.x) and integer(goal.y) and integer(goal.z) and self:isPassable(goal) then
            local goalKey = key(goal.x, goal.y, goal.z)
            local penalty = math.max(0, tonumber(goal.penalty) or 0)
            if not goalByKey[goalKey] or penalty < goalByKey[goalKey].penalty then
                goalByKey[goalKey] = { x = goal.x, y = goal.y, z = goal.z, penalty = penalty }
            end
        end
    end
    for _, goal in pairs(goalByKey) do usableGoals[#usableGoals + 1] = goal end
    if #usableGoals == 0 then return nil, nil, "NO_KNOWN_AIR_DESTINATION" end

    local minimumY = math.floor(tonumber(options.minimumY) or -64)
    local maximumY = math.floor(tonumber(options.maximumY) or 320)
    local maximumNodes = math.max(1, math.floor(tonumber(options.maximumNodes) or 24000))
    local function estimate(point)
        local best
        for _, goal in ipairs(usableGoals) do
            local distance = (math.abs(point.x - goal.x) + math.abs(point.z - goal.z)) * 10
                + math.abs(point.y - goal.y) * 12 + goal.penalty
            if not best or distance < best then best = distance end
        end
        return best or 0
    end

    local startKey = key(start.x, start.y, start.z)
    local costs, previous, points = { [startKey] = 0 }, {}, {
        [startKey] = { x = start.x, y = start.y, z = start.z },
    }
    local heap, visited = {}, 0
    push(heap, { key = startKey, cost = 0, priority = estimate(start) })
    while #heap > 0 and visited < maximumNodes do
        if visited % 128 == 0 and type(sleep) == "function" then sleep(0) end
        local entry = pop(heap)
        if entry.cost == costs[entry.key] then
            visited = visited + 1
            local point, goal = points[entry.key], goalByKey[entry.key]
            if goal then
                local path, cursor = {}, entry.key
                while cursor ~= startKey do
                    table.insert(path, 1, points[cursor])
                    cursor = previous[cursor]
                end
                return path, goal
            end
            for _, direction in ipairs(directions) do
                local nextPoint = {
                    x = point.x + direction.x,
                    y = point.y + direction.y,
                    z = point.z + direction.z,
                }
                if nextPoint.y >= minimumY and nextPoint.y <= maximumY
                    and self:isPassable(nextPoint) then
                    local nextKey = key(nextPoint.x, nextPoint.y, nextPoint.z)
                    local nextCost = entry.cost + direction.cost
                    if not costs[nextKey] or nextCost < costs[nextKey] then
                        costs[nextKey], previous[nextKey], points[nextKey] = nextCost, entry.key, nextPoint
                        push(heap, {
                            key = nextKey,
                            cost = nextCost,
                            priority = nextCost + estimate(nextPoint),
                        })
                    end
                end
            end
        end
    end
    return nil, nil, visited >= maximumNodes and "SPATIAL_ROUTE_LIMIT" or "NO_KNOWN_3D_ROUTE"
end

return spatial
