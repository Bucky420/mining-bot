local config = require("config")
local inventory = require("lib.inventory")
local markers = require("lib.markers")
local nav = require("lib.nav")

local scanner = {}

local function findScanner()
    return peripheral.find("geo_scanner") or peripheral.find("geoScanner")
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

-- Keep scanner details without allowing functions, userdata, or cyclic tables
-- into results that may later be serialized.
local function copySerializable(value, active)
    local valueType = type(value)
    if value == nil or valueType == "boolean" or valueType == "number"
        or valueType == "string" then
        return value
    end
    if valueType ~= "table" then return nil end
    active = active or {}
    if active[value] then return nil end
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" or keyType == "boolean" then
            local itemCopy = copySerializable(item, active)
            if itemCopy ~= nil then copy[key] = itemCopy end
        end
    end
    active[value] = nil
    return copy
end

local function copyBlock(block, x, y, z)
    local copy = copySerializable(block) or {}
    copy.name = block.name
    copy.x, copy.y, copy.z = x, y, z
    copy.state = copySerializable(block.state)
    copy.tags = copySerializable(block.tags)
    return copy
end

local function hasTag(tags, wanted)
    if type(tags) ~= "table" then return false end
    if tags[wanted] then return true end
    for _, tag in ipairs(tags) do
        if tag == wanted then return true end
    end
    return false
end

function scanner.scan(radius, blockFilter)
    radius = tonumber(radius) or config.scanner.maxRadius
    if radius < 1 or radius > config.scanner.maxRadius or radius ~= math.floor(radius) then
        return nil, "INVALID_SCAN_RADIUS_1_TO_" .. tostring(config.scanner.maxRadius)
    end
    local equipped, equipError = inventory.ensureGeoScanner()
    if not equipped then return nil, "NEEDS_GEO_SCANNER: " .. tostring(equipError) end
    local device = findScanner()
    if not device then return nil, "GEO_SCANNER_PERIPHERAL_NOT_FOUND" end

    local scanMethod = type(device.scan) == "function" and device.scan or device.scanBlocks
    if type(scanMethod) ~= "function" then
        return nil, "GEO_SCANNER_API_UNSUPPORTED"
    end
    local blocks, scanError
    local attempts = math.max(1, math.floor(config.scanner.retryAttempts or 1))
    for attempt = 1, attempts do
        local called, result, resultError = pcall(scanMethod, radius)
        if called and type(result) == "table" then
            blocks = result
            break
        end
        scanError = called and resultError or result
        if attempt < attempts then sleep(config.scanner.retryDelay or 1) end
    end
    if type(blocks) ~= "table" then return nil, scanError or "GEO_SCAN_FAILED" end

    local origin = nav.getPosition()
    if type(origin) ~= "table" or not isInteger(origin.x) or not isInteger(origin.y)
        or not isInteger(origin.z) then
        return nil, "GEO_SCAN_RETURNED_INVALID_ORIGIN"
    end
    local coordinateMode = "relative"
    local absolutePlausible = true
    local relativePlausible = true
    for _, block in ipairs(blocks) do
        if type(block) ~= "table" or type(block.name) ~= "string"
            or not isInteger(block.x) or not isInteger(block.y)
            or not isInteger(block.z) then
            return nil, "GEO_SCAN_RETURNED_INVALID_BLOCK_DATA"
        end
        if math.abs(block.x) > radius or math.abs(block.y) > radius or math.abs(block.z) > radius then
            relativePlausible = false
        end
        if math.abs(block.x - origin.x) > radius or math.abs(block.y - origin.y) > radius
            or math.abs(block.z - origin.z) > radius then absolutePlausible = false end
    end
    -- Current Advanced Peripherals scan coordinates are relative. Absolute
    -- normalization remains only as a fallback for legacy scanBlocks data.
    if #blocks > 0 and not relativePlausible and not absolutePlausible then
        return nil, "GEO_SCAN_COORDINATES_OUT_OF_RANGE"
    end
    if #blocks > 0 and not relativePlausible and absolutePlausible then
        coordinateMode = "absolute"
    end
    local relativeBlocks = {}
    local normalizedBlocks = {}
    local chestCandidates = {}
    local matches = {}
    local farmCandidates = {}
    local counts = {}
    local occupied = {}
    for _, block in ipairs(blocks) do
        local x, y, z = block.x, block.y, block.z
        if coordinateMode == "absolute" then
            x, y, z = x - origin.x, y - origin.y, z - origin.z
        end
        if x * x + y * y + z * z <= radius * radius then
            local absoluteX, absoluteY, absoluteZ = origin.x + x, origin.y + y, origin.z + z
            local key = ("%d:%d:%d"):format(absoluteX, absoluteY, absoluteZ)
            if occupied[key] then return nil, "GEO_SCAN_DUPLICATE_COORDINATE" end
            occupied[key] = block.name
            table.insert(relativeBlocks, copyBlock(block, x, y, z))
            table.insert(normalizedBlocks, copyBlock(block, absoluteX, absoluteY, absoluteZ))
            counts[block.name] = (counts[block.name] or 0) + 1
            if type(block.name) == "string"
                and block.name:find(config.scanner.chestNameContains, 1, true) then
                table.insert(chestCandidates, copyBlock(block, absoluteX, absoluteY, absoluteZ))
            end
            if type(blockFilter) == "string" and block.name == blockFilter then
                table.insert(matches, copyBlock(block, absoluteX, absoluteY, absoluteZ))
            end
            local taggedCrop = hasTag(block.tags, "minecraft:crops")
                or hasTag(block.tags, "c:crops") or hasTag(block.tags, "forge:crops")
            local configuredCrop = type(block.name) == "string"
                and type(config.scanner.cropNameContains) == "string"
                and block.name:find(config.scanner.cropNameContains, 1, true)
            if taggedCrop or configuredCrop then
                table.insert(farmCandidates, copyBlock(block, absoluteX, absoluteY, absoluteZ))
            end
        end
    end
    -- Advanced Peripherals omits air blocks. Fill only the exact scanned
    -- sphere so known air can be distinguished from unknown cube corners.
    for dx = -radius, radius do
        for dy = -radius, radius do
            for dz = -radius, radius do
                if dx * dx + dy * dy + dz * dz <= radius * radius then
                    local x, y, z = origin.x + dx, origin.y + dy, origin.z + dz
                    local absoluteKey = ("%d:%d:%d"):format(x, y, z)
                    if not occupied[absoluteKey] then
                        normalizedBlocks[#normalizedBlocks + 1] = {
                            x = x, y = y, z = z, name = "minecraft:air",
                        }
                    end
                end
            end
        end
    end
    for _, chest in ipairs(chestCandidates) do
        chest.approaches = {}
        for _, approach in ipairs({
            { x = chest.x - 1, y = chest.y, z = chest.z, direction = "east" },
            { x = chest.x + 1, y = chest.y, z = chest.z, direction = "west" },
            { x = chest.x, y = chest.y, z = chest.z - 1, direction = "south" },
            { x = chest.x, y = chest.y, z = chest.z + 1, direction = "north" },
        }) do
            local key = ("%d:%d:%d"):format(approach.x, approach.y, approach.z)
            if not occupied[key] then table.insert(chest.approaches, approach) end
        end
    end
    return {
        version = config.scanner.surveyVersion,
        origin = origin,
        radius = radius,
        coordinateMode = coordinateMode,
        blocks = normalizedBlocks,
        markers = markers.recognizeScan(relativeBlocks, origin),
        chests = chestCandidates,
        blockFilter = blockFilter,
        matches = matches,
        farmCandidates = farmCandidates,
        blockCounts = counts,
    }
end

return scanner
