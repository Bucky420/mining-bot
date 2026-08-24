local config = require("config")
local inventory = require("lib.inventory")
local markers = require("lib.markers")
local nav = require("lib.nav")

local scanner = {}

local function findScanner()
    return peripheral.find("geo_scanner") or peripheral.find("geoScanner")
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

    local blocks, scanError
    if type(device.scan) == "function" then
        blocks, scanError = device.scan(radius)
    elseif type(device.scanBlocks) == "function" then
        blocks, scanError = device.scanBlocks(radius)
    else
        return nil, "GEO_SCANNER_API_UNSUPPORTED"
    end
    if type(blocks) ~= "table" then return nil, scanError or "GEO_SCAN_FAILED" end

    local origin = nav.getPosition()
    local absolutePlausible = true
    local relativePlausible = true
    for _, block in ipairs(blocks) do
        if type(block) ~= "table" or type(block.name) ~= "string"
            or type(block.x) ~= "number" or type(block.y) ~= "number"
            or type(block.z) ~= "number" then
            return nil, "GEO_SCAN_RETURNED_INVALID_BLOCK_DATA"
        end
        if math.abs(block.x) > radius or math.abs(block.y) > radius or math.abs(block.z) > radius then
            relativePlausible = false
        end
        if math.abs(block.x - origin.x) > radius or math.abs(block.y - origin.y) > radius
            or math.abs(block.z - origin.z) > radius then absolutePlausible = false end
    end
    if absolutePlausible == relativePlausible then
        return nil, absolutePlausible and "GEO_SCAN_COORDINATE_MODE_AMBIGUOUS"
            or "GEO_SCAN_COORDINATES_OUT_OF_RANGE"
    end
    if absolutePlausible then
        local normalized = {}
        for _, block in ipairs(blocks) do
            local copy = {}
            for key, value in pairs(block) do copy[key] = value end
            copy.x, copy.y, copy.z = block.x - origin.x, block.y - origin.y, block.z - origin.z
            table.insert(normalized, copy)
        end
        blocks = normalized
    end
    local chestCandidates = {}
    local matches = {}
    local farmCandidates = {}
    local counts = {}
    local occupied = {}
    for _, block in ipairs(blocks) do
        counts[block.name] = (counts[block.name] or 0) + 1
        occupied[("%d:%d:%d"):format(origin.x + block.x, origin.y + block.y, origin.z + block.z)] = block.name
        if type(block.name) == "string"
            and block.name:find(config.scanner.chestNameContains, 1, true) then
            table.insert(chestCandidates, {
                name = block.name,
                x = origin.x + block.x,
                y = origin.y + block.y,
                z = origin.z + block.z,
            })
        end
        if type(blockFilter) == "string" and block.name == blockFilter then
            table.insert(matches, {
                name = block.name,
                x = origin.x + block.x,
                y = origin.y + block.y,
                z = origin.z + block.z,
                state = block.state,
            })
        end
        if type(block.name) == "string" and block.name:find(config.scanner.cropNameContains, 1, true) then
            table.insert(farmCandidates, {
                name = block.name,
                x = origin.x + block.x,
                y = origin.y + block.y,
                z = origin.z + block.z,
                state = block.state,
            })
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
        origin = origin,
        radius = radius,
        markers = markers.recognizeScan(blocks, origin),
        chests = chestCandidates,
        blockFilter = blockFilter,
        matches = matches,
        farmCandidates = farmCandidates,
        blockCounts = counts,
    }
end

return scanner
