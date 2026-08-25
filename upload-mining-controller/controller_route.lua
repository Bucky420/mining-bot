local route = {}

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

return route
