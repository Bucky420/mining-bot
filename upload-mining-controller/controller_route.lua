local route = {}

local directions3D = {
    { 1, 0, 0, 10 }, { -1, 0, 0, 10 }, { 0, 0, 1, 10 }, { 0, 0, -1, 10 },
    { 0, 1, 0, 12 }, { 0, -1, 0, 12 },
}

local function pointKey(x, y, z) return ("%d:%d:%d"):format(x, y, z) end
local function air(cell)
    return cell and (cell.name == "minecraft:air" or cell.name == "minecraft:cave_air"
        or cell.name == "minecraft:void_air")
end

local function heapPush(heap, entry)
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

local function heapPop(heap)
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

local vectors = {
    north = { x = 0, z = -1, index = 0 },
    east = { x = 1, z = 0, index = 1 },
    south = { x = 0, z = 1, index = 2 },
    west = { x = -1, z = 0, index = 3 },
}

local function safe(cell)
    if type(cell) ~= "table" or cell.verticalStructure then return false end
    if ({
        unknown = true, hard = true, fence = true, lava = true,
        tree_log = true, tree_leaves = true,
    })[cell.class] then return false end
    local occupant = tostring(cell.occupant or cell.occupantName or ""):lower()
    return not occupant:find("log", 1, true) and not occupant:find("leaves", 1, true)
        and not occupant:find("leaf", 1, true) and not occupant:find("stem", 1, true)
end

function route.find(cells, start, target, startHeading)
    if type(cells) ~= "table" or type(start) ~= "table" or type(target) ~= "table" then return nil end
    if not vectors[startHeading] then startHeading = "north" end
    local function cellKey(x, z) return ("%d:%d"):format(x, z) end
    local function nodeKey(x, z, heading) return ("%d:%d:%s"):format(x, z, heading) end
    if start.x == target.x and start.z == target.z then return {} end
    if not safe(cells[cellKey(target.x, target.z)]) then return nil end
    local function turnCount(from, to)
        local difference = math.abs(vectors[from].index - vectors[to].index)
        return math.min(difference, 4 - difference)
    end
    local startKey = nodeKey(start.x, start.z, startHeading)
    local open = { { key = startKey, x = start.x, z = start.z, heading = startHeading, cost = 0 } }
    local costs, previous, nodes = { [startKey] = 0 }, {}, {
        [startKey] = { x = start.x, z = start.z, heading = startHeading },
    }
    while #open > 0 do
        local best = 1
        for index = 2, #open do
            local a, b = open[index], open[best]
            local ah = math.abs(target.x - a.x) + math.abs(target.z - a.z)
            local bh = math.abs(target.x - b.x) + math.abs(target.z - b.z)
            if a.cost + ah < b.cost + bh then best = index end
        end
        local current = table.remove(open, best)
        if current.cost == costs[current.key] then
            if current.x == target.x and current.z == target.z then
                local result, cursor = {}, current.key
                while cursor ~= startKey do
                    local node = nodes[cursor]
                    table.insert(result, 1, { x = node.x, z = node.z })
                    cursor = previous[cursor]
                end
                return result
            end
            for _, heading in ipairs({ "north", "east", "south", "west" }) do
                local vector = vectors[heading]
                local x, z = current.x + vector.x, current.z + vector.z
                if safe(cells[cellKey(x, z)]) then
                    local nextKey = nodeKey(x, z, heading)
                    local cost = current.cost + 1 + turnCount(current.heading, heading) * 2
                    if costs[nextKey] == nil or cost < costs[nextKey] then
                        costs[nextKey], previous[nextKey] = cost, current.key
                        nodes[nextKey] = { x = x, z = z, heading = heading }
                        open[#open + 1] = {
                            key = nextKey, x = x, z = z, heading = heading, cost = cost,
                        }
                    end
                end
            end
        end
    end
    return nil
end

function route.find3D(start, target, readCell, excluded, options)
    options = options or {}
    if type(start) ~= "table" or type(target) ~= "table" or type(readCell) ~= "function" then
        return nil, "INVALID_3D_ROUTE"
    end
    for _, point in ipairs({ start, target }) do
        if type(point.x) ~= "number" or type(point.y) ~= "number" or type(point.z) ~= "number"
            or point.x ~= math.floor(point.x) or point.y ~= math.floor(point.y)
            or point.z ~= math.floor(point.z) then return nil, "INVALID_3D_ROUTE" end
    end
    local startKey, targetKey = pointKey(start.x, start.y, start.z), pointKey(target.x, target.y, target.z)
    if startKey == targetKey then return {} end
    excluded = excluded or {}
    if excluded[targetKey] or not air(readCell(target.x, target.y, target.z)) then
        return nil, "DESTINATION_NOT_KNOWN_AIR"
    end
    local margin = math.max(4, math.floor(tonumber(options.margin) or 24))
    local minimumX, maximumX = math.min(start.x, target.x) - margin, math.max(start.x, target.x) + margin
    local minimumY, maximumY = math.max(-64, math.min(start.y, target.y) - margin),
        math.min(320, math.max(start.y, target.y) + margin)
    local minimumZ, maximumZ = math.min(start.z, target.z) - margin, math.max(start.z, target.z) + margin
    local maximumNodes = math.max(1, math.floor(tonumber(options.maximumNodes) or 30000))
    local function estimate(x, y, z)
        return (math.abs(target.x - x) + math.abs(target.z - z)) * 10
            + math.abs(target.y - y) * 12
    end
    local open = {}
    heapPush(open, {
        key = startKey, x = start.x, y = start.y, z = start.z,
        cost = 0, priority = estimate(start.x, start.y, start.z),
    })
    local costs, previous, points = { [startKey] = 0 }, {}, {
        [startKey] = { x = start.x, y = start.y, z = start.z },
    }
    local visited = 0
    while #open > 0 and visited < maximumNodes do
        local current = heapPop(open)
        if current.cost == costs[current.key] then
            visited = visited + 1
            if current.key == targetKey then
                local result, cursor = {}, targetKey
                while cursor ~= startKey do
                    table.insert(result, 1, points[cursor])
                    cursor = previous[cursor]
                end
                return result
            end
            for _, direction in ipairs(directions3D) do
                local x, y, z = current.x + direction[1], current.y + direction[2], current.z + direction[3]
                local nextKey = pointKey(x, y, z)
                if x >= minimumX and x <= maximumX and y >= minimumY and y <= maximumY
                    and z >= minimumZ and z <= maximumZ and not excluded[nextKey]
                    and air(readCell(x, y, z)) then
                    local nextCost = current.cost + direction[4]
                    if not costs[nextKey] or nextCost < costs[nextKey] then
                        costs[nextKey], previous[nextKey] = nextCost, current.key
                        points[nextKey] = { x = x, y = y, z = z }
                        heapPush(open, {
                            key = nextKey, x = x, y = y, z = z,
                            cost = nextCost, priority = nextCost + estimate(x, y, z),
                        })
                    end
                end
            end
        end
    end
    return nil, visited >= maximumNodes and "ROUTE_SEARCH_LIMIT" or "NO_KNOWN_3D_ROUTE"
end

return route
