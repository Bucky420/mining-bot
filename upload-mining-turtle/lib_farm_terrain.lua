-- Pure terrain classification and farm planning helpers.
local terrain = {}

local function lower(value)
    return type(value) == "string" and value:lower() or ""
end

local function hasTag(tags, wanted)
    if type(tags) ~= "table" then return false end
    wanted = lower(wanted)
    if tags[wanted] == true or tags[wanted:gsub("^minecraft:", "")] == true then
        return true
    end
    for key, tag in pairs(tags) do
        local value = type(key) == "number" and tag or (tag == true and key)
        if lower(value) == wanted or lower(value) == wanted:gsub("^minecraft:", "") then
            return true
        end
    end
    return false
end

local function hasAnyTag(tags, names)
    for _, name in ipairs(names) do
        if hasTag(tags, name) then return true end
    end
    return false
end

function terrain.key(x, z) return tostring(x) .. ":" .. tostring(z) end

function terrain.inRadius(cx, cz, x, z, radius)
    if type(cx) ~= "number" or type(cz) ~= "number" or type(x) ~= "number"
        or type(z) ~= "number" or type(radius) ~= "number" or radius < 0 then return false end
    local dx, dz = x - cx, z - cz
    return dx * dx + dz * dz <= radius * radius
end

function terrain.surveySweepPoints(center, radius, step, y)
    center, radius, step = center or {}, tonumber(radius), tonumber(step)
    if type(center.x) ~= "number" or type(center.z) ~= "number"
        or center.x ~= math.floor(center.x) or center.z ~= math.floor(center.z)
        or not radius or radius < 1 or radius ~= math.floor(radius)
        or not step or step < 1 or step ~= math.floor(step)
        or type(y) ~= "number" or y ~= math.floor(y) then return {} end
    local result = {}
    local function append(x, z)
        local previous = result[#result]
        if not previous or previous.x ~= x or previous.z ~= z then
            result[#result + 1] = { x = x, y = y, z = z }
        end
    end

    local minimumX, maximumX = center.x - radius, center.x + radius
    local xRows = {}
    for x = minimumX, maximumX, step do xRows[#xRows + 1] = x end
    if xRows[#xRows] < maximumX then xRows[#xRows + 1] = maximumX end

    -- Scan a straight corridor from the known center to the first sweep row.
    local leadX = center.x - step
    while leadX > minimumX do
        append(leadX, center.z)
        leadX = leadX - step
    end
    append(minimumX, center.z)

    local currentZ = center.z
    local direction = 1
    for index, x in ipairs(xRows) do
        local dx = x - center.x
        local halfWidth = math.floor(math.sqrt(math.max(0, radius * radius - dx * dx)))
        local nextHalfWidth = halfWidth
        if xRows[index + 1] then
            local nextDx = xRows[index + 1] - center.x
            nextHalfWidth = math.floor(math.sqrt(math.max(0, radius * radius - nextDx * nextDx)))
        end
        local reachableHalfWidth = math.min(halfWidth, nextHalfWidth)
        currentZ = math.max(center.z - halfWidth, math.min(center.z + halfWidth, currentZ))
        append(x, currentZ)
        local targetZ = center.z + direction * reachableHalfWidth
        while math.abs(targetZ - currentZ) > step do
            currentZ = currentZ + (targetZ > currentZ and step or -step)
            append(x, currentZ)
        end
        currentZ = targetZ
        append(x, currentZ)
        direction = -direction
    end
    return result
end

function terrain.retainScanTiles(columns, tiles, newKeys, limit)
    columns = type(columns) == "table" and columns or {}
    tiles = type(tiles) == "table" and tiles or {}
    newKeys = type(newKeys) == "table" and newKeys or {}
    limit = math.max(1, math.floor(tonumber(limit) or 4))
    tiles[#tiles + 1] = newKeys
    while #tiles > limit do table.remove(tiles, 1) end
    local retained = {}
    for _, keys in ipairs(tiles) do
        for _, columnKey in ipairs(keys) do retained[columnKey] = true end
    end
    for columnKey in pairs(columns) do
        if not retained[columnKey] then columns[columnKey] = nil end
    end
    return columns, tiles
end

function terrain.turnEfficientPath(allowed, start, target, startHeading, turnCost)
    if type(allowed) ~= "table" or type(start) ~= "table" or type(target) ~= "table" then return nil end
    local directions = {
        north = { x = 0, z = -1, index = 0 },
        east = { x = 1, z = 0, index = 1 },
        south = { x = 0, z = 1, index = 2 },
        west = { x = -1, z = 0, index = 3 },
    }
    if not directions[startHeading] then startHeading = "north" end
    turnCost = math.max(0, tonumber(turnCost) or 2)
    local function stateKey(x, z, heading) return ("%d:%d:%s"):format(x, z, heading) end
    local function cellKey(x, z) return ("%d:%d"):format(x, z) end
    local function turns(from, to)
        local difference = math.abs(directions[from].index - directions[to].index)
        return math.min(difference, 4 - difference)
    end
    local function less(a, b)
        return a.priority == b.priority and a.cost < b.cost or a.priority < b.priority
    end
    local heap = {}
    local function push(node)
        heap[#heap + 1] = node
        local index = #heap
        while index > 1 do
            local parent = math.floor(index / 2)
            if not less(heap[index], heap[parent]) then break end
            heap[index], heap[parent] = heap[parent], heap[index]
            index = parent
        end
    end
    local function pop()
        local result = heap[1]
        heap[1] = heap[#heap]
        heap[#heap] = nil
        local index = 1
        while heap[index] do
            local left, right = index * 2, index * 2 + 1
            local child = left
            if heap[right] and less(heap[right], heap[left]) then child = right end
            if not heap[child] or not less(heap[child], heap[index]) then break end
            heap[index], heap[child] = heap[child], heap[index]
            index = child
        end
        return result
    end

    -- The turtle may already occupy a column which a later scan excluded. Its
    -- current cell is a valid origin, but every cell it enters must be allowed.
    local startKey = stateKey(start.x, start.z, startHeading)
    local costs, previous, nodes = { [startKey] = 0 }, {}, {
        [startKey] = { x = start.x, z = start.z, heading = startHeading },
    }
    push({ key = startKey, cost = 0, priority = math.abs(target.x - start.x) + math.abs(target.z - start.z) })
    while #heap > 0 do
        local currentEntry = pop()
        if currentEntry.cost == costs[currentEntry.key] then
            local current = nodes[currentEntry.key]
            if current.x == target.x and current.z == target.z then
                local path, cursor = {}, currentEntry.key
                while cursor ~= startKey do
                    local node = nodes[cursor]
                    table.insert(path, 1, { x = node.x, z = node.z })
                    cursor = previous[cursor]
                end
                return path
            end
            for _, heading in ipairs({ "north", "east", "south", "west" }) do
                local vector = directions[heading]
                local x, z = current.x + vector.x, current.z + vector.z
                if allowed[cellKey(x, z)] then
                    local nextKey = stateKey(x, z, heading)
                    local cost = currentEntry.cost + 1 + turns(current.heading, heading) * turnCost
                    if costs[nextKey] == nil or cost < costs[nextKey] then
                        local heuristic = math.abs(target.x - x) + math.abs(target.z - z)
                        costs[nextKey], previous[nextKey] = cost, currentEntry.key
                        nodes[nextKey] = { x = x, z = z, heading = heading }
                        push({ key = nextKey, cost = cost, priority = cost + heuristic })
                    end
                end
            end
        end
    end
    return nil
end

function terrain.classifyBlock(block)
    if type(block) ~= "table" or type(block.name) ~= "string" then return "unknown" end
    local name, tags = lower(block.name), block.tags
    local state = type(block.state) == "table" and block.state or {}
    if name == "minecraft:air" or name == "minecraft:cave_air" or name == "minecraft:void_air"
        or hasAnyTag(tags, { "air", "minecraft:air" }) then return "air" end
    if hasAnyTag(tags, { "water", "minecraft:water" }) or name:find("water", 1, true) then return "water" end
    if hasAnyTag(tags, { "lava", "minecraft:lava" }) or name:find("lava", 1, true) then return "lava" end
    if state.age ~= nil or hasAnyTag(tags, { "crops", "minecraft:crops", "c:crops", "forge:crops" }) or name:find("crop", 1, true)
        or name:find("wheat", 1, true) or name:find("carrot", 1, true)
        or name:find("potato", 1, true) or name:find("beetroot", 1, true) then return "crop" end
    if name == "minecraft:farmland" or hasTag(tags, "farmland") then return "farmland" end
    if name == "minecraft:grass_block" or name == "minecraft:grass" or hasTag(tags, "grass_block") then return "grass" end
    if name == "minecraft:dirt" or name:find("dirt", 1, true) or hasTag(tags, "dirt") then return "dirt" end
    if hasAnyTag(tags, { "logs", "log", "minecraft:logs" }) or name:find("log", 1, true)
        or name:find("stem", 1, true) then return "tree_log" end
    if hasAnyTag(tags, { "leaves", "leaf", "minecraft:leaves" }) or name:find("leaves", 1, true)
        or name:find("leaf", 1, true) then return "tree_leaves" end
    if hasAnyTag(tags, { "flowers", "flower", "tall_grass", "replaceable_plants" })
        or name:find("flower", 1, true) or name:find("grass", 1, true)
        or name:find("fern", 1, true) or name:find("plant", 1, true) then return "vegetation" end
    if hasAnyTag(tags, { "fences", "fence", "minecraft:fences" }) or name:find("fence", 1, true) then return "fence" end
    if name:find("sand", 1, true) or hasTag(tags, "sand") then return "sand" end
    if hasAnyTag(tags, { "stone", "minecraft:stone" }) or name:find("stone", 1, true) then return "stone" end
    return "unknown"
end

local ground = { grass = true, dirt = true, farmland = true, sand = true, stone = true,
    water = true, lava = true, fence = true, hard = true, unknown = true }
local farmable = { grass = true, dirt = true, farmland = true, crop = true, vegetation = true }
local hard = { hard = true, fence = true, lava = true, unknown = true }

local function clone(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

function terrain.buildSurface(blocks, center, radius, baseY, maxOffset)
    local columns, result = {}, {}
    center, radius, baseY = center or {}, tonumber(radius) or 0, tonumber(baseY) or 0
    maxOffset = tonumber(maxOffset) or 3
    for _, record in ipairs(blocks or {}) do
        if type(record) == "table" and type(record.x) == "number" and type(record.y) == "number"
            and type(record.z) == "number" and terrain.inRadius(center.x or 0, center.z or 0, record.x, record.z, radius) then
            local class = terrain.classifyBlock(record)
            local key = terrain.key(record.x, record.z)
            local column = columns[key] or { x = record.x, z = record.z, records = {} }
            local item = clone(record); item.class = class
            table.insert(column.records, item)
            columns[key] = column
        end
    end
    for _, column in pairs(columns) do
        table.sort(column.records, function(a, b) return a.y < b.y end)
        local surface
        for _, item in ipairs(column.records) do
            if ground[item.class] then
                if not surface or item.y > surface.y then surface = item end
            end
        end
        if not surface and #column.records > 0 then
            local air = column.records[#column.records]
            if air.class == "air" then surface = air end
        end
        if surface then
            local occupants = {}
            for _, item in ipairs(column.records) do
                if item.class ~= "air" and not ground[item.class] and item.y > surface.y then
                    table.insert(occupants, item)
                end
            end
            local cell = clone(surface)
            cell.surfaceY, cell.height = surface.y, surface.y - baseY
            cell.ground = { class = surface.class, name = surface.name, y = surface.y,
                state = surface.state, tags = surface.tags }
            cell.occupant = occupants[1]
            cell.occupants = occupants
            cell.clearance = { blocked = #occupants > 0, records = occupants }
            cell.inRange = math.abs(cell.surfaceY - baseY) <= maxOffset
            table.insert(result, cell)
        end
    end
    table.sort(result, function(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end)
    return result
end

local function marked(set, cell)
    if type(set) ~= "table" then return false end
    if set[terrain.key(cell.x, cell.z)] or (set[cell.x] and set[cell.x][cell.z]) then return true end
    for _, point in ipairs(set) do
        if type(point) == "table" and point.x == cell.x and point.z == cell.z then return true end
    end
    return false
end

local function copyList(list)
    local result = {}
    for _, value in ipairs(list or {}) do table.insert(result, value) end
    return result
end

function terrain.plan(surface, options)
    options = options or {}
    local map, cells, excluded, wormCenters = {}, {}, {}, {}
    local center = options.center or {}
    local radius = tonumber(options.radius)
    local baseY = tonumber(options.baseY or options.baseHeight) or 0
    local maxOffset = tonumber(options.maxOffset) or 3
    local margin = tonumber(options.margin) or 3
    local reserved = options.excluded or {}
    local chests, access, irrigation = options.chest or options.chests or {}, options.access or {}, options.irrigation or {}
    local hardClasses = options.hardClasses or hard
    local replaceable = {}
    for _, source in ipairs(surface or {}) do
        if type(source) == "table" and type(source.x) == "number" and type(source.z) == "number" then
            map[terrain.key(source.x, source.z)] = clone(source)
        end
    end
    local function neighbor(cell, dx, dz) return map[terrain.key(cell.x + dx, cell.z + dz)] end
    local function hasMargin(cell)
        for dx = -margin, margin do for dz = -margin, margin do
            if math.max(math.abs(dx), math.abs(dz)) > 0 and math.max(math.abs(dx), math.abs(dz)) <= margin then
                local other = neighbor(cell, dx, dz)
                if other and (hardClasses[other.class] or other.class == "fence" or other.class == "lava"
                    or (other.class == "sand" or other.class == "stone")
                        and not replaceable[terrain.key(other.x, other.z)]
                    or (other.surfaceY and math.abs(other.surfaceY - baseY) > maxOffset)) then return true end
            end
        end end
        return false
    end
    local visited = {}
    for key, start in pairs(map) do
        if (start.class == "sand" or start.class == "stone") and not visited[key] then
            local queue, component, enclosedComponent = { start }, {}, true
            visited[key] = true
            while #queue > 0 do
                local current = table.remove(queue, 1)
                table.insert(component, current)
                for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local other = neighbor(current, d[1], d[2])
                    if not other then enclosedComponent = false
                    elseif hardClasses[other.class] or other.clearance and other.clearance.blocked then enclosedComponent = false
                    elseif other.class == start.class then
                        local otherKey = terrain.key(other.x, other.z)
                        if not visited[otherKey] then visited[otherKey] = true; table.insert(queue, other) end
                    end
                end
            end
            for _, item in ipairs(component) do
                if item.verticalStructure or item.clearance and item.clearance.blocked then
                    enclosedComponent = false
                    break
                end
            end
            if enclosedComponent then for _, item in ipairs(component) do replaceable[terrain.key(item.x, item.z)] = true end end
        end
    end
    local function fillable(cell)
        if cell.class ~= "air" and not farmable[cell.class] then return false end
        local targetY
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local other = neighbor(cell, d[1], d[2])
            if not other or not farmable[other.class] then return false end
            local otherY = other.surfaceY or baseY
            targetY = targetY or otherY
            if otherY ~= targetY then return false end
        end
        local depth = targetY - (cell.surfaceY or baseY)
        if depth < 1 or depth > 3 then return false end
        return true, targetY
    end
    local function wormCenter(cell)
        local tx, tz = math.floor(cell.x / 3), math.floor(cell.z / 3)
        return math.floor(tx * 3 + 1) == cell.x and math.floor(tz * 3 + 1) == cell.z
    end
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local source, cell = map[key], clone(map[key])
        cell.surfaceY = tonumber(cell.surfaceY or cell.y)
        cell.action, cell.status = nil, "excluded"
        local reason
        local isFillable, fillTarget = fillable(cell)
        if radius and not terrain.inRadius(center.x or 0, center.z or 0, cell.x, cell.z, radius) then reason = "outside_radius"
        elseif marked(reserved, cell) or marked(chests, cell) or marked(access, cell) or marked(irrigation, cell) then reason = "reserved"
        elseif cell.class == "tree_log" or cell.class == "tree_leaves" or (cell.clearance and cell.clearance.blocked and cell.occupant and (cell.occupant.class == "tree_log" or cell.occupant.class == "tree_leaves")) then reason = "tree_clearance"
        elseif not cell.surfaceY or math.abs(cell.surfaceY - baseY) > maxOffset then reason = "out_of_range"
        elseif hardClasses[cell.class] or cell.class == "fence" or cell.class == "lava" then reason = "hard"
        elseif cell.class == "water" then reason = "irrigation_reserved"
        elseif (cell.class == "sand" or cell.class == "stone") and replaceable[key]
            and not hasMargin(cell) then cell.action, cell.status, reason = "replace", "usable", "enclosed_surface"
        elseif isFillable and not hasMargin(cell) then
            cell.action, cell.status, reason, cell.targetY = "fill", "usable", "enclosed_hole", fillTarget
        elseif farmable[cell.class] then
            if hasMargin(cell) then reason = "hard_margin"
            elseif wormCenter(cell) then reason = "worm_center"
            else cell.action, cell.status, reason = (cell.occupant and "clear" or "farm"), "usable", "contour"
            end
        else reason = "unsafe_surface" end
        if cell.status == "usable" then table.insert(cells, cell) else cell.reason = reason; table.insert(excluded, cell) end
    end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, cell in ipairs(cells) do
        minX, maxX, minZ, maxZ = math.min(minX, cell.x), math.max(maxX, cell.x), math.min(minZ, cell.z), math.max(maxZ, cell.z)
    end
    if minX ~= math.huge then
        local excludedByKey = {}
        for _, cell in ipairs(excluded) do excludedByKey[terrain.key(cell.x, cell.z)] = cell end
        for x = math.floor(minX / 3) * 3 + 1, maxX, 3 do for z = math.floor(minZ / 3) * 3 + 1, maxZ, 3 do
            local centerCell = map[terrain.key(x, z)]
            local excludedCenter = excludedByKey[terrain.key(x, z)]
            if centerCell and excludedCenter and excludedCenter.reason == "worm_center"
                and farmable[centerCell.class] and not hasMargin(centerCell)
                and math.abs((centerCell.surfaceY or baseY) - baseY) <= maxOffset then
                table.insert(wormCenters, {
                    x = x, y = centerCell.surfaceY, z = z,
                    class = centerCell.class,
                    name = centerCell.ground and centerCell.ground.name or centerCell.name,
                    occupant = centerCell.occupant and {
                        name = centerCell.occupant.name,
                        class = centerCell.occupant.class,
                        y = centerCell.occupant.y,
                    } or nil,
                })
            end
        end end
    end
    table.sort(cells, function(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end)
    return { cells = cells, usable = copyList(cells), wormCenters = wormCenters, excluded = excluded,
        bounds = minX == math.huge and {} or { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
        summary = { usable = #cells, excluded = #excluded, wormCenters = #wormCenters, baseY = baseY, maxOffset = maxOffset } }
end

function terrain.alternatingRows(cells, cropIds)
    local result, rows = {}, {}
    if type(cropIds) ~= "table" or #cropIds == 0 then return result end
    for _, source in ipairs(cells or {}) do rows[source.z] = true end
    local rowKeys = {}; for z in pairs(rows) do table.insert(rowKeys, z) end; table.sort(rowKeys)
    local rowNumber = {}; for i, z in ipairs(rowKeys) do rowNumber[z] = i - 1 end
    for _, source in ipairs(cells or {}) do local cell = clone(source); cell.cropId = cropIds[(rowNumber[cell.z] % #cropIds) + 1]; table.insert(result, cell) end
    table.sort(result, function(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end)
    return result
end

function terrain.rebalancePlan(existingCounts, seedCounts, capacity)
    existingCounts, seedCounts = existingCounts or {}, seedCounts or {}
    capacity = math.max(0, math.floor(tonumber(capacity) or 0))
    local names, total = {}, 0
    for name in pairs(existingCounts) do names[name] = true end
    for name in pairs(seedCounts) do names[name] = true end
    local ids = {}; for name in pairs(names) do table.insert(ids, name) end; table.sort(ids)
    local desired, replacements = {}, {}
    local active = {}; for _, name in ipairs(ids) do if (tonumber(existingCounts[name]) or 0) > 0 or (tonumber(seedCounts[name]) or 0) > 0 then table.insert(active, name) end end
    local existingTotal, seedTotal = 0, 0
    for _, name in ipairs(active) do
        existingTotal = existingTotal + math.max(0, math.floor(tonumber(existingCounts[name]) or 0))
        seedTotal = seedTotal + math.max(0, math.floor(tonumber(seedCounts[name]) or 0))
    end
    local target = math.min(capacity, existingTotal + seedTotal)
    for i, name in ipairs(active) do desired[name] = math.floor(target / #active) + (i <= target % #active and 1 or 0); total = total + desired[name] end
    for _, name in ipairs(ids) do
        local have = math.max(0, math.floor(tonumber(existingCounts[name]) or 0))
        local available = math.max(0, math.floor(tonumber(seedCounts[name]) or 0))
        replacements[name] = math.min(available, math.max(0, (desired[name] or 0) - have))
    end
    return { desired = desired, replacements = replacements, capacity = capacity, active = active, target = target }
end

return terrain
