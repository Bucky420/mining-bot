local map = require("lib.map")
local markers = require("lib.markers")
local nav = require("lib.nav")

local travel = {}

function travel.run(job, framework)
    if framework.isCancellationRequested(job) then return false, "JOB_CANCELLED" end
    local parameters = job.parameters
    local destination
    local node
    if parameters.nodeId then
        node = map.getNode(parameters.nodeId)
        if not node then return false, "UNKNOWN_NODE: " .. tostring(parameters.nodeId) end
        destination = { x = node.x, y = node.y, z = node.z }
    else
        destination = { x = parameters.x, y = parameters.y, z = parameters.z }
    end
    if type(destination.x) ~= "number" or type(destination.y) ~= "number" or type(destination.z) ~= "number" then
        return false, "TRAVEL_REQUIRES_DESTINATION"
    end

    if not job.progress.started then
        local syncOk, syncError = nav.syncGps(true)
        if not syncOk then return false, "GPS_BEFORE_TRAVEL_FAILED: " .. tostring(syncError) end
        job.progress.started = true
        job.progress.destination = destination
        if not framework.checkpoint(job, "Travel started") then return false, "JOB_CANCELLED" end
    end

    local ok, reason, block = nav.routeXYZ(
        parameters.mapId or parameters.farmId or "world",
        destination.x, destination.y, destination.z, {
        shouldContinue = function() return not framework.isCancellationRequested(job) end,
    })
    if not ok then
        if reason == "JOB_CANCELLED" then return false, reason end
        return false, ("TRAVEL_BLOCKED: %s%s"):format(
            tostring(reason), block and (" (" .. tostring(block.name) .. ")") or ""
        )
    end
    local syncOk, syncError = nav.syncGps(true)
    if not syncOk then return false, "GPS_AT_DESTINATION_FAILED: " .. tostring(syncError) end

    node = node or map.findNodeAt(destination.x, destination.y, destination.z)
    if node then
        markers.audit(map.expectedMarker(node), destination, { nodeId = node.id, jobId = job.id })
    else
        markers.audit(nil, destination, { jobId = job.id })
    end
    job.progress.arrived = true
    if not framework.checkpoint(job, "Arrived") then return false, "JOB_CANCELLED" end
    return true, { destination = destination, nodeId = node and node.id or nil }
end

return travel
