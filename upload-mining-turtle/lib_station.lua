local map = require("lib.map")
local nav = require("lib.nav")
local inventory = require("lib.inventory")

local station = {}
local directions = { north = true, east = true, south = true, west = true }

local function hasOutputCapacity(wrapped, protectedItems, minimumSlots)
    local contents = wrapped.list()
    local empty = 0
    for slot = 1, wrapped.size() do if not contents[slot] then empty = empty + 1 end end
    local required = math.max(inventory.requiredOutputSlots(protectedItems), minimumSlots or 0)
    return empty >= required
end

local function resolve(value)
    if type(value) == "table" then return value end
    return map.getStation(value)
end

function station.validate(value)
    local found = resolve(value)
    if not found then return nil, "UNKNOWN_SERVICE_STATION: " .. tostring(value) end
    if not directions[found.supplyDirection] or not directions[found.outputDirection] then
        return nil, "STATION_REQUIRES_SUPPLY_AND_OUTPUT_DIRECTIONS"
    end
    return found
end

function station.arrive(value, role, options)
    local found, stationError = station.validate(value)
    if not found then return nil, stationError end
    local arrived, travelError
    if options and options.localNavigation then
        arrived, travelError = nav.gotoXYZ(found.x, found.y, found.z, options)
    else
        arrived, travelError = nav.routeXYZ(
            options and options.mapId or "world", found.x, found.y, found.z, options
        )
    end
    if travelError == "JOB_CANCELLED" then return nil, travelError end
    if not arrived then return nil, "STATION_TRAVEL_FAILED: " .. tostring(travelError) end
    local direction = role == "supply" and found.supplyDirection or found.outputDirection
    local faced, faceError = nav.face(direction)
    if not faced then return nil, "STATION_FACE_FAILED: " .. tostring(faceError) end
    local wrapped = peripheral.wrap("front")
    if not wrapped or type(wrapped.list) ~= "function" or type(wrapped.size) ~= "function" then
        return nil, string.upper(role) .. "_CHEST_NOT_AN_INVENTORY"
    end
    return found
end

function station.pull(value, itemName, amount, options)
    local found, arriveError = station.arrive(value, "supply", options)
    if not found then return false, arriveError end
    return inventory.pullItemFromFront(itemName, amount)
end

function station.unload(value, protectedItems, options)
    local found, arriveError = station.arrive(value, "output", options)
    if not found then return false, arriveError end
    local wrapped = peripheral.wrap("front")
    if not hasOutputCapacity(wrapped, protectedItems) then return false, "OUTPUT_CHEST_CAPACITY_LOW" end
    return inventory.dropNonProtected(protectedItems)
end

function station.verifyOutput(value, protectedItems, options, minimumSlots)
    local found, arriveError = station.arrive(value, "output", options)
    if not found then return nil, arriveError end
    local wrapped = peripheral.wrap("front")
    if not hasOutputCapacity(wrapped, protectedItems, minimumSlots) then
        return nil, "OUTPUT_CHEST_CAPACITY_LOW"
    end
    return wrapped
end

function station.verifyOutputAt(output, protectedItems, options, minimumSlots)
    if type(output) ~= "table" or type(output.approach) ~= "table"
        or not directions[output.direction] then return nil, "INVALID_OUTPUT_CHEST_LOCATION" end
    local arrived, travelError
    if options and options.localNavigation then
        arrived, travelError = nav.gotoXYZ(
            output.approach.x, output.approach.y, output.approach.z, options
        )
    else
        arrived, travelError = nav.routeXYZ(
            options and options.mapId or "world",
            output.approach.x, output.approach.y, output.approach.z, options
        )
    end
    if travelError == "JOB_CANCELLED" then return nil, travelError end
    if not arrived then return nil, "OUTPUT_TRAVEL_FAILED: " .. tostring(travelError) end
    local faced, faceError = nav.face(output.direction)
    if not faced then return nil, "OUTPUT_FACE_FAILED: " .. tostring(faceError) end
    local wrapped = peripheral.wrap("front")
    if not wrapped or type(wrapped.list) ~= "function" or type(wrapped.size) ~= "function" then
        return nil, "OUTPUT_CHEST_NOT_AN_INVENTORY"
    end
    if options and options.validateFront then
        local valid, validationError = options.validateFront()
        if not valid then return nil, validationError or "OUTPUT_CHEST_CHANGED" end
    end
    if not hasOutputCapacity(wrapped, protectedItems, minimumSlots) then
        return nil, "OUTPUT_CHEST_CAPACITY_LOW"
    end
    return wrapped
end

function station.unloadAt(output, protectedItems, options)
    local wrapped, verifyError = station.verifyOutputAt(output, protectedItems, options)
    if not wrapped then return false, verifyError end
    return inventory.dropNonProtected(protectedItems)
end

function station.refuel(value, target, options)
    local level = turtle.getFuelLevel()
    if level == "unlimited" or (type(level) == "number" and level >= target) then return true end
    local found, arriveError = station.arrive(value, "supply", options)
    if not found then return false, arriveError end
    for _, itemName in ipairs(require("config").inventory.fuelItems) do
        inventory.pullItemFromFront(itemName, inventory.countItem(itemName) + 16)
        local fueled = inventory.refuelTo(target)
        if fueled then return true end
    end
    return false, "SUPPLY_MISSING_FUEL"
end

return station
