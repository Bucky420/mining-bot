local config = require("config")
local map = require("lib.map")
local nav = require("lib.nav")

local configureSite = {}
local directions = { north = true, east = true, south = true, west = true }

function configureSite.run(job)
    local parameters = job.parameters
    local position = nav.getPosition()
    local node = { id = parameters.id, x = position.x, y = position.y, z = position.z }
    if type(node.id) ~= "string" or node.id == "" then return false, "SITE_ID_REQUIRED" end

    if parameters.kind == "station" then
        if not directions[parameters.supplyDirection] or not directions[parameters.outputDirection] then
            return false, "INVALID_STATION_DIRECTIONS"
        end
        if parameters.supplyDirection == parameters.outputDirection then return false, "STATION_CHESTS_MUST_DIFFER" end
        node.type = "service_station"
        node.supplyDirection = parameters.supplyDirection
        node.outputDirection = parameters.outputDirection
        node.marker = "SERVICE"
    elseif parameters.kind == "tunnel" then
        if not directions[parameters.direction] then return false, "INVALID_TUNNEL_DIRECTION" end
        node.width, node.height = tonumber(parameters.width), tonumber(parameters.height)
        if not node.width or not node.height or node.width < 1 or node.height < 1 then
            return false, "INVALID_TUNNEL_DIMENSIONS"
        end
        node.type = "tunnel_entrance"
        node.direction = parameters.direction
        node.profile = parameters.profile or config.defaultProfile
        node.marker = "MAIN_TUNNEL"
    elseif parameters.kind == "farm" then
        if not directions[parameters.direction] then return false, "INVALID_FARM_DIRECTION" end
        if not map.getStation(parameters.stationId) then return false, "UNKNOWN_SERVICE_STATION" end
        node.type = "farm"
        node.width, node.length = tonumber(parameters.width), tonumber(parameters.length)
        node.direction = parameters.direction
        node.crop, node.seed = parameters.crop, parameters.seed
        node.matureAge, node.stationId = tonumber(parameters.matureAge), parameters.stationId
        if not node.width or not node.length or node.width < 1 or node.length < 1
            or type(node.crop) ~= "string" or type(node.seed) ~= "string" then
            return false, "INVALID_FARM_CONFIGURATION"
        end
    elseif parameters.kind == "room" then
        if not directions[parameters.direction] then return false, "INVALID_ROOM_DIRECTION" end
        node.type = "room"
        node.roomType = parameters.roomType or "generic"
        node.direction = parameters.direction
        node.width, node.length, node.height = tonumber(parameters.width), tonumber(parameters.length), tonumber(parameters.height)
        if not node.width or not node.length or not node.height
            or node.width < 1 or node.length < 1 or node.height < 1 then
            return false, "INVALID_ROOM_DIMENSIONS"
        end
        node.marker = "ROOM"
    else
        return false, "UNKNOWN_SITE_KIND"
    end

    local saved, saveError = map.addNode(node)
    if not saved then return false, saveError end
    return true, { node = node }
end

return configureSite
