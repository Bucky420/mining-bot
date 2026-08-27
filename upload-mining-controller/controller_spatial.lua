local spatial = {}
local storage = require("lib.controller_storage")

local ROOT = "/data/farm-3d"
local MOUNTED_ROOT = "bucky/terrain-3d"
local SURVEY_VERSION = 2
local spatialIndex = {}

local function safe(value)
    local text, checksum = tostring(value), 0
    for index = 1, #text do checksum = (checksum * 131 + text:byte(index)) % 2147483647 end
    return (text:gsub("[^%w_.-]", "_"):sub(1, 48) .. "-" .. tostring(checksum))
end

local function path(farmId, chunkKey)
    return fs.combine(fs.combine(ROOT, safe(farmId)), safe(chunkKey) .. ".map")
end

local function read(pathname)
    if not fs.exists(pathname) or fs.isDir(pathname) then return nil end
    local handle = fs.open(pathname, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
end

local function write(pathname, value)
    local parent = fs.getDir(pathname)
    if not fs.exists(parent) then fs.makeDir(parent) end
    local temporary, previous = pathname .. ".tmp", pathname .. ".previous"
    if fs.exists(temporary) then fs.delete(temporary) end
    local handle = fs.open(temporary, "w")
    if not handle then return false, "SPATIAL_TEMPORARY_OPEN_FAILED" end
    local ok, errorMessage = pcall(function()
        handle.write(textutils.serialize(value, { compact = true }))
        handle.flush()
        handle.close()
    end)
    if not ok then pcall(handle.close) if fs.exists(temporary) then fs.delete(temporary) end return false, tostring(errorMessage) end
    if not read(temporary) then fs.delete(temporary) return false, "SPATIAL_TEMPORARY_INVALID" end
    if fs.exists(previous) then fs.delete(previous) end
    if fs.exists(pathname) then fs.move(pathname, previous) end
    local moved, moveError = pcall(fs.move, temporary, pathname)
    if not moved then
        if not fs.exists(pathname) and fs.exists(previous) then pcall(fs.move, previous, pathname) end
        return false, tostring(moveError)
    end
    return true
end

local function validChunk(chunk)
    if type(chunk) ~= "table" or type(chunk.farmId) ~= "string"
        or type(chunk.chunkKey) ~= "string" or type(chunk.cells) ~= "table" then return false end
    for _, cell in ipairs(chunk.cells) do
        if type(cell) ~= "table" or type(cell.x) ~= "number" or type(cell.y) ~= "number"
            or type(cell.z) ~= "number" or type(cell.name) ~= "string" then return false end
    end
    for _, origin in ipairs(chunk.surveyOrigins or {}) do
        if type(origin) ~= "table" or type(origin.x) ~= "number" or type(origin.y) ~= "number"
            or type(origin.z) ~= "number" or type(origin.verifiedAt) ~= "number"
            or type(origin.version) ~= "number" then return false end
    end
    return true
end

local function chunkCoordinates(chunkKey)
    if type(chunkKey) ~= "string" then return nil end
    local x, y, z = chunkKey:match("^(-?%d+):(-?%d+):(-?%d+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z)
end

local function validCompactChunk(value)
    if type(value) ~= "table" or value.format ~= 2 or type(value.f) ~= "string"
        or type(value.k) ~= "string" or type(value.n) ~= "table"
        or type(value.d) ~= "table" or type(value.o) ~= "table" then return false end
    if not chunkCoordinates(value.k) then return false end
    for _, name in ipairs(value.n) do
        if type(name) ~= "string" then return false end
    end
    local previousEnd = -1
    for _, run in ipairs(value.d) do
        local start, length, nameId = tonumber(run[1]), tonumber(run[2]), tonumber(run[3])
        if not start or start ~= math.floor(start) or start <= previousEnd or start < 0
            or not length or length ~= math.floor(length) or length < 1 or start + length > 4096
            or not nameId or nameId ~= math.floor(nameId) or type(value.n[nameId]) ~= "string" then
            return false
        end
        previousEnd = start + length - 1
    end
    for _, origin in ipairs(value.o) do
        if type(origin) ~= "table" or type(origin[1]) ~= "number"
            or type(origin[2]) ~= "number" or type(origin[3]) ~= "number"
            or type(origin[4]) ~= "number" or type(origin[6]) ~= "number" then return false end
    end
    return true
end

local function validStoredChunk(value)
    return validChunk(value) or validCompactChunk(value)
end

local function compactChunk(chunk)
    local chunkX, chunkY, chunkZ = chunkCoordinates(chunk.chunkKey)
    if not chunkX then return nil, "INVALID_SPATIAL_CHUNK_KEY" end
    local names, byOffset = {}, {}
    for _, cell in ipairs(chunk.cells) do
        local localX, localY, localZ = cell.x - chunkX * 16, cell.y - chunkY * 16, cell.z - chunkZ * 16
        if localX < 0 or localX > 15 or localY < 0 or localY > 15 or localZ < 0 or localZ > 15
            or localX ~= math.floor(localX) or localY ~= math.floor(localY)
            or localZ ~= math.floor(localZ) then return nil, "SPATIAL_CELL_OUTSIDE_CHUNK" end
        local offset = localY * 256 + localZ * 16 + localX
        byOffset[offset], names[cell.name] = cell.name, true
    end
    local palette = {}
    for name in pairs(names) do palette[#palette + 1] = name end
    table.sort(palette)
    local nameIds = {}
    for index, name in ipairs(palette) do nameIds[name] = index end
    local offsets = {}
    for offset in pairs(byOffset) do offsets[#offsets + 1] = offset end
    table.sort(offsets)
    local runs = {}
    for _, offset in ipairs(offsets) do
        local nameId = nameIds[byOffset[offset]]
        local previous = runs[#runs]
        if previous and previous[1] + previous[2] == offset and previous[3] == nameId then
            previous[2] = previous[2] + 1
        else
            runs[#runs + 1] = { offset, 1, nameId }
        end
    end
    local origins = {}
    for _, origin in ipairs(chunk.surveyOrigins or {}) do
        origins[#origins + 1] = {
            origin.version, origin.x, origin.y, origin.z,
            origin.radius or 0, origin.verifiedAt,
        }
    end
    return {
        format = 2,
        f = chunk.farmId,
        k = chunk.chunkKey,
        r = chunk.revision or 0,
        t = chunk.verifiedAt or 0,
        c = chunk.changeCount or 0,
        n = palette,
        d = runs,
        o = origins,
    }
end

local function expandChunk(value)
    if type(value) ~= "table" or value.format ~= 2 then return value end
    local chunkX, chunkY, chunkZ = chunkCoordinates(value.k)
    local cells = {}
    for _, run in ipairs(value.d) do
        for offset = run[1], run[1] + run[2] - 1 do
            local localX = offset % 16
            local localZ = math.floor(offset / 16) % 16
            local localY = math.floor(offset / 256)
            cells[#cells + 1] = {
                x = chunkX * 16 + localX,
                y = chunkY * 16 + localY,
                z = chunkZ * 16 + localZ,
                name = value.n[run[3]],
            }
        end
    end
    local origins = {}
    for _, origin in ipairs(value.o) do
        origins[#origins + 1] = {
            version = origin[1], x = origin[2], y = origin[3], z = origin[4],
            radius = origin[5], verifiedAt = origin[6],
        }
    end
    return {
        version = 1,
        farmId = value.f,
        chunkKey = value.k,
        revision = value.r,
        verifiedAt = value.t,
        changeCount = value.c,
        cells = cells,
        surveyOrigins = origins,
    }
end

function spatial.configure(index)
    spatialIndex = type(index) == "table" and index or {}
end

local function indexFor(farmId)
    spatialIndex[farmId] = spatialIndex[farmId] or {}
    return spatialIndex[farmId]
end

local function mountedFile(farmId, chunkKey)
    return fs.combine(fs.combine(MOUNTED_ROOT, safe(farmId)), safe(chunkKey) .. ".map")
end

function spatial.read(farmId, chunkKey)
    local entry = spatialIndex[farmId] and spatialIndex[farmId][chunkKey]
    if entry then
        local value, readError = storage.readValue(entry, validStoredChunk)
        if not value then return nil, readError end
        value = expandChunk(value)
        if value.farmId ~= farmId or value.chunkKey ~= chunkKey then
            return nil, "SPATIAL_CHUNK_ID_MISMATCH"
        end
        return value
    end
    local value = read(path(farmId, chunkKey))
    if not value then return nil, "SPATIAL_CHUNK_NOT_FOUND" end
    if value.farmId ~= farmId or value.chunkKey ~= chunkKey or not validChunk(value) then
        return nil, "SPATIAL_CHUNK_INVALID"
    end
    return value
end

function spatial.write(chunk)
    if not validChunk(chunk) then return false, "INVALID_SPATIAL_CHUNK" end
    local previous = spatial.read(chunk.farmId, chunk.chunkKey)
    local changes = 0
    if previous then
        local old = {}
        for _, cell in ipairs(previous.cells) do
            old[("%d:%d:%d"):format(cell.x, cell.y, cell.z)] = cell.name
        end
        for _, cell in ipairs(chunk.cells) do
            local cellKey = ("%d:%d:%d"):format(cell.x, cell.y, cell.z)
            if old[cellKey] and old[cellKey] ~= cell.name then changes = changes + 1 end
            old[cellKey] = nil
        end
    end
    local origins, originKeys = {}, {}
    for _, origin in ipairs(previous and previous.surveyOrigins or {}) do
        local originKey = ("%d:%d:%d:%d"):format(origin.version, origin.x, origin.y, origin.z)
        origins[#origins + 1], originKeys[originKey] = origin, #origins + 1
    end
    if type(chunk.surveyOrigin) == "table" and tonumber(chunk.surveyVersion) then
        local origin = {
            version = math.floor(chunk.surveyVersion),
            x = math.floor(chunk.surveyOrigin.x), y = math.floor(chunk.surveyOrigin.y),
            z = math.floor(chunk.surveyOrigin.z),
            radius = math.floor(tonumber(chunk.surveyRadius) or 0),
            verifiedAt = tonumber(chunk.verifiedAt) or os.epoch("utc"),
        }
        local originKey = ("%d:%d:%d:%d"):format(origin.version, origin.x, origin.y, origin.z)
        if originKeys[originKey] then origins[originKeys[originKey]] = origin
        else origins[#origins + 1] = origin end
    end
    local value = {
        version = 1,
        farmId = chunk.farmId,
        chunkKey = chunk.chunkKey,
        revision = tonumber(chunk.revision) or 0,
        verifiedAt = tonumber(chunk.verifiedAt) or os.epoch("utc"),
        changeCount = math.max(
            tonumber(chunk.changeCount) or 0,
            (previous and tonumber(previous.changeCount) or 0) + changes
        ),
        cells = chunk.cells,
        surveyOrigins = origins,
    }
    local compact, compactError = compactChunk(value)
    if not compact then return false, compactError end
    local farmIndex = indexFor(chunk.farmId)
    local entry, writeError = storage.writeValue(
        mountedFile(chunk.farmId, chunk.chunkKey), compact,
        farmIndex[chunk.chunkKey], validCompactChunk
    )
    if not entry then return false, writeError end
    entry.revision, entry.verifiedAt = value.revision, value.verifiedAt
    farmIndex[chunk.chunkKey] = entry
    return true
end

function spatial.compactIndexed()
    local changed = false
    for farmId, farmIndex in pairs(spatialIndex) do
        for chunkKey, indexEntry in pairs(farmIndex) do
            local stored = storage.readValue(indexEntry, validStoredChunk)
            if stored and stored.format ~= 2 then
                local chunk = expandChunk(stored)
                local first = spatial.write(chunk)
                if first then
                    -- A second atomic rotation replaces the retained verbose rollback copy.
                    local second = spatial.write(chunk)
                    if second then changed = true end
                end
            end
            if type(sleep) == "function" then sleep(0) end
        end
    end
    return changed
end

local function surveySweepPoints(centerX, centerZ, radius, step, y)
    local result, seen, minimumX, maximumX = {}, {}, centerX - radius, centerX + radius
    local function append(x, z)
        local pointKey = ("%d:%d"):format(x, z)
        if not seen[pointKey] then
            result[#result + 1] = { x = x, y = y, z = z }
            seen[pointKey] = true
        end
    end
    local rows = {}
    for x = minimumX, maximumX, step do rows[#rows + 1] = x end
    if rows[#rows] < maximumX then rows[#rows + 1] = maximumX end
    local leadX = centerX - step
    while leadX > minimumX do append(leadX, centerZ) leadX = leadX - step end
    append(minimumX, centerZ)
    local currentZ, direction = centerZ, 1
    for index, x in ipairs(rows) do
        local halfWidth = math.floor(math.sqrt(math.max(0, radius * radius - (x - centerX) ^ 2)))
        local nextHalfWidth = halfWidth
        if rows[index + 1] then
            nextHalfWidth = math.floor(math.sqrt(math.max(
                0, radius * radius - (rows[index + 1] - centerX) ^ 2
            )))
        end
        local reachable = math.min(halfWidth, nextHalfWidth)
        currentZ = math.max(centerZ - halfWidth, math.min(centerZ + halfWidth, currentZ))
        append(x, currentZ)
        local targetZ = centerZ + direction * reachable
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

function spatial.surveyPlan(farmId, centerX, centerZ, baseY, radius, step, start)
    local origins, originKeys = {}, {}
    for chunkKey in pairs(spatialIndex[farmId] or {}) do
        local chunk = spatial.read(farmId, chunkKey)
        for _, origin in ipairs(chunk and chunk.surveyOrigins or {}) do
            if origin.version == SURVEY_VERSION then
                local originKey = ("%d:%d:%d"):format(origin.x, origin.y, origin.z)
                if not originKeys[originKey] then origins[#origins + 1], originKeys[originKey] = origin, true end
            end
        end
    end
    local missing = {}
    for _, point in ipairs(surveySweepPoints(centerX, centerZ, radius, step, baseY + 5)) do
        local covered = false
        for _, origin in ipairs(origins) do
            if math.abs(origin.x - point.x) + math.abs(origin.z - point.z) <= 2
                and math.abs(origin.y - point.y) <= 1 then covered = true break end
        end
        if not covered then missing[#missing + 1] = point end
    end
    local ordered, cursor = {}, { x = start.x, z = start.z }
    while #missing > 0 do
        local bestIndex, bestDistance
        for index, point in ipairs(missing) do
            local distance = math.abs(point.x - cursor.x) + math.abs(point.z - cursor.z)
            if not bestDistance or distance < bestDistance then
                bestIndex, bestDistance = index, distance
            end
        end
        local point = table.remove(missing, bestIndex)
        ordered[#ordered + 1], cursor = point, point
    end
    return ordered, SURVEY_VERSION
end

function spatial.migrateLegacy()
    if not fs.exists(ROOT) or not fs.isDir(ROOT) then return false end
    local changed = false
    for _, farmDirectory in ipairs(fs.list(ROOT)) do
        local directory = fs.combine(ROOT, farmDirectory)
        if fs.isDir(directory) then
            for _, file in ipairs(fs.list(directory)) do
                local value = read(fs.combine(directory, file))
                if validChunk(value) and not (spatialIndex[value.farmId]
                    and spatialIndex[value.farmId][value.chunkKey]) then
                    local migrated = spatial.write(value)
                    if migrated then changed = true end
                end
            end
        end
    end
    return changed
end

local function isAir(cell)
    return cell and (cell.name == "minecraft:air" or cell.name == "minecraft:cave_air"
        or cell.name == "minecraft:void_air")
end

local function isSurfaceVegetation(cell)
    return cell and type(cell.name) == "string"
        and (cell.name:find("grass", 1, true) or cell.name:find("fern", 1, true))
end

local function isTreeCanopy(cell)
    return cell and type(cell.name) == "string"
        and (cell.name:find("leaves", 1, true) or cell.name:find("log", 1, true))
end

function spatial.slice(farmId, centerX, centerZ, layerY, radius)
    centerX, centerZ, layerY, radius = math.floor(centerX), math.floor(centerZ),
        math.floor(layerY), math.floor(radius)
    local cells = {}
    local minimumX, maximumX = centerX - radius, centerX + radius
    local minimumZ, maximumZ = centerZ - radius, centerZ + radius
    local minimumChunkX, maximumChunkX = math.floor(minimumX / 16), math.floor(maximumX / 16)
    local minimumChunkZ, maximumChunkZ = math.floor(minimumZ / 16), math.floor(maximumZ / 16)
    local minimumChunkY, maximumChunkY = math.floor((layerY - 1) / 16), math.floor((layerY + 1) / 16)
    local known = {}
    for chunkX = minimumChunkX, maximumChunkX do
        for chunkY = minimumChunkY, maximumChunkY do
            for chunkZ = minimumChunkZ, maximumChunkZ do
                local chunk = spatial.read(farmId, ("%d:%d:%d"):format(chunkX, chunkY, chunkZ))
                for _, cell in ipairs(chunk and chunk.cells or {}) do
                    if cell.x >= minimumX and cell.x <= maximumX
                        and cell.z >= minimumZ and cell.z <= maximumZ
                        and cell.y >= layerY - 1 and cell.y <= layerY + 1 then
                        known[("%d:%d:%d"):format(cell.x, cell.y, cell.z)] = cell
                    end
                end
            end
        end
    end
    for x = minimumX, maximumX do
        for z = minimumZ, maximumZ do
            if (x - centerX) ^ 2 + (z - centerZ) ^ 2 <= radius * radius then
                local below = known[("%d:%d:%d"):format(x, layerY - 1, z)]
                local body = known[("%d:%d:%d"):format(x, layerY, z)]
                local above = known[("%d:%d:%d"):format(x, layerY + 1, z)]
                local projection
                if body and not isAir(body) then
                    projection = { x = x, y = layerY, z = z, name = body.name, class = "wall" }
                elseif body and above and not isAir(above) then
                    projection = { x = x, y = layerY, z = z, name = above.name, class = "ceiling" }
                elseif body and above and isAir(body) and isAir(above) and below then
                    projection = {
                        x = x, y = layerY, z = z,
                        name = below.name,
                        class = isAir(below) and "pit" or "tunnel",
                    }
                end
                if projection then cells[#cells + 1] = projection end
            end
        end
    end
    return cells
end

function spatial.cellReader(farmId)
    local chunks = {}
    return function(x, y, z)
        local chunkKey = ("%d:%d:%d"):format(
            math.floor(x / 16), math.floor(y / 16), math.floor(z / 16)
        )
        if chunks[chunkKey] == nil then
            chunks[chunkKey] = spatial.read(farmId, chunkKey) or false
            if not chunks[chunkKey] and farmId == "world" then
                for candidateFarm in pairs(spatialIndex) do
                    local candidate = spatial.read(candidateFarm, chunkKey)
                    if candidate then chunks[chunkKey] = candidate break end
                end
            end
        end
        local chunk = chunks[chunkKey]
        if not chunk then return nil end
        for _, cell in ipairs(chunk.cells) do
            if cell.x == x and cell.y == y and cell.z == z then return cell end
        end
        return nil
    end
end

function spatial.classify(farmId, x, y, z)
    local readCell = spatial.cellReader(farmId)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    for dx = -8, 8 do
        for dz = -8, 8 do
            if dx * dx + dz * dz <= 64 then
                for dy = -8, 8 do
                    if isSurfaceVegetation(readCell(x + dx, y + dy, z + dz)) then return "surface" end
                end
            end
        end
    end
    local ceilingColumns = 0
    for dx = -1, 1 do
        for dz = -1, 1 do
            local knownColumn, ceiling = true, false
            for dy = 0, 8 do
                local cell = readCell(x + dx, y + dy, z + dz)
                if not cell then knownColumn = false break end
                if not isAir(cell) and not isTreeCanopy(cell) then ceiling = true break end
            end
            if ceiling then ceilingColumns = ceilingColumns + 1
            elseif not knownColumn and dx == 0 and dz == 0 then return "unknown" end
        end
    end
    if ceilingColumns >= 3 then return "cave" end
    local centerOpen = true
    for dy = 0, 8 do
        local cell = readCell(x, y + dy, z)
        if not cell then return "unknown" end
        if not isAir(cell) then centerOpen = false break end
    end
    return centerOpen and "surface" or "unknown"
end

function spatial.updateCell(farmId, point, name)
    if type(point) ~= "table" or type(name) ~= "string" then return false, "INVALID_SPATIAL_CHANGE" end
    local chunkKey = ("%d:%d:%d"):format(
        math.floor(point.x / 16), math.floor(point.y / 16), math.floor(point.z / 16)
    )
    local chunk = spatial.read(farmId, chunkKey)
    if not chunk and farmId == "world" then
        for candidateFarm in pairs(spatialIndex) do
            chunk = spatial.read(candidateFarm, chunkKey)
            if chunk then break end
        end
    end
    chunk = chunk or {
        version = 1, farmId = farmId, chunkKey = chunkKey,
        revision = 0, verifiedAt = 0, changeCount = 0, cells = {},
    }
    chunk.farmId = farmId
    local replaced = false
    for _, cell in ipairs(chunk.cells) do
        if cell.x == point.x and cell.y == point.y and cell.z == point.z then
            cell.name, replaced = name, true
            break
        end
    end
    if not replaced then
        chunk.cells[#chunk.cells + 1] = { x = point.x, y = point.y, z = point.z, name = name }
    end
    chunk.revision = (tonumber(chunk.revision) or 0) + 1
    chunk.verifiedAt = os.epoch("utc")
    chunk.changeCount = (tonumber(chunk.changeCount) or 0) + 1
    return spatial.write(chunk)
end

return spatial
