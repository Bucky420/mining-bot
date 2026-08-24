local config = require("config")
local inventory = require("lib.inventory")
local state = require("lib.state")
local util = require("lib.util")

local markers = {}
local blockTypes = {}
for markerType, blockName in pairs(config.markers) do
    blockTypes[blockName] = markerType
end

local directions = {
    north = { x = 0, z = -1 },
    east = { x = 1, z = 0 },
    south = { x = 0, z = 1 },
    west = { x = -1, z = 0 },
}

local function rightVector(direction)
    if direction == "north" then return { x = 1, z = 0 } end
    if direction == "east" then return { x = 0, z = 1 } end
    if direction == "south" then return { x = -1, z = 0 } end
    return { x = 0, z = -1 }
end

function markers.isProtectedBlock(blockName)
    if blockTypes[blockName] then return true end
    return blockName == config.markerPattern.inward or blockName == config.markerPattern.right
end

function markers.recognizeScan(blocks, origin)
    origin = origin or { x = 0, y = 0, z = 0 }
    local byPosition = {}
    local candidates = {}
    for _, block in ipairs(blocks or {}) do
        if type(block.x) == "number" and type(block.y) == "number" and type(block.z) == "number" then
            local key = ("%d:%d:%d"):format(block.x, block.y, block.z)
            byPosition[key] = block.name
            if blockTypes[block.name] then table.insert(candidates, block) end
        end
    end

    local found = {}
    for _, anchor in ipairs(candidates) do
        for direction, vector in pairs(directions) do
            local right = rightVector(direction)
            local inwardKey = ("%d:%d:%d"):format(anchor.x + vector.x, anchor.y, anchor.z + vector.z)
            local rightKey = ("%d:%d:%d"):format(anchor.x + right.x, anchor.y, anchor.z + right.z)
            if byPosition[inwardKey] == config.markerPattern.inward
                and byPosition[rightKey] == config.markerPattern.right then
                table.insert(found, {
                    markerType = blockTypes[anchor.name],
                    heading = direction,
                    position = {
                        x = origin.x + anchor.x,
                        y = origin.y + anchor.y + 1,
                        z = origin.z + anchor.z,
                    },
                    floorPosition = {
                        x = origin.x + anchor.x,
                        y = origin.y + anchor.y,
                        z = origin.z + anchor.z,
                    },
                    confidence = "exact",
                })
            end
        end
    end
    return found
end

function markers.inspectFloor()
    local found, detail = turtle.inspectDown()
    if not found then
        return { kind = "missing" }
    end
    local markerType = blockTypes[detail.name]
    if markerType then
        return { kind = "marker", markerType = markerType, block = detail.name, detail = detail }
    end
    return { kind = "ordinary", block = detail.name, detail = detail }
end

function markers.isCap()
    local result = markers.inspectFloor()
    return result.kind == "marker" and result.markerType == "END", result
end

local function commandTask(found, position, context)
    local taskType = "MAP_AREA"
    if found == "BUILD" then taskType = "BUILD_BRANCH" end
    if found == "PROFILE_CHANGE" then taskType = "MAP_AREA" end
    return {
        type = taskType,
        source = "PLAYER_MARKER",
        markerType = found,
        position = util.copy(position),
        context = context,
        dedupeKey = ("player-marker:%s:%d:%d:%d"):format(found, position.x, position.y, position.z),
    }
end

function markers.audit(expected, position, context)
    local result = markers.inspectFloor()
    if not expected then
        if result.kind == "marker" and (result.markerType == "BUILD" or result.markerType == "PROFILE_CHANGE") then
            state.enqueueTask(commandTask(result.markerType, position, context))
            return "PLAYER_COMMAND", result
        end
        return "UNMANAGED", result
    end
    if result.kind == "marker" and result.markerType == expected then
        return "OK", result
    end
    if result.kind == "marker" then
        state.enqueueTask(commandTask(result.markerType, position, context))
        util.log("INFO", "Marker differs from map; recorded player command", {
            expected = expected,
            found = result.markerType,
            position = position,
        })
        return "PLAYER_COMMAND", result
    end

    state.enqueueTask({
        type = "REPAIR_MARKER",
        source = "MARKER_AUDIT",
        markerType = expected,
        position = util.copy(position),
        foundBlock = result.block,
        context = context,
        dedupeKey = ("repair-marker:%s:%d:%d:%d"):format(expected, position.x, position.y, position.z),
    })
    util.log("WARN", "Expected marker is damaged or missing", {
        expected = expected,
        found = result.block or "air",
        position = position,
    })
    return "DAMAGED", result
end

function markers.place(markerType)
    local blockName = config.markers[markerType]
    if not blockName then return false, "UNKNOWN_MARKER_TYPE" end
    local existing = markers.inspectFloor()
    if existing.kind == "marker" and existing.markerType == markerType then return true end
    if existing.kind ~= "missing" then
        return false, "FLOOR_OCCUPIED_BY_" .. tostring(existing.block)
    end
    local slot = inventory.selectItem(blockName)
    if not slot then return false, "MISSING_MARKER_ITEM: " .. blockName end
    local previous = turtle.getSelectedSlot()
    turtle.select(slot)
    local ok, placeError = turtle.placeDown()
    turtle.select(previous)
    if not ok then return false, "PLACE_FAILED: " .. tostring(placeError) end
    return true
end

return markers
