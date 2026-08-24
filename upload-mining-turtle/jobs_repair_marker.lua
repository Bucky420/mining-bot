local markers = require("lib.markers")
local nav = require("lib.nav")

local repairMarker = {}

function repairMarker.run(job, framework)
    if framework.isCancellationRequested(job) then return false, "JOB_CANCELLED" end
    local p = job.parameters.position or job.parameters
    local markerType = job.parameters.markerType
    if type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then
        return false, "REPAIR_REQUIRES_POSITION"
    end
    if type(markerType) ~= "string" then return false, "REPAIR_REQUIRES_MARKER_TYPE" end

    local arrived, travelError = nav.gotoXYZ(p.x, p.y, p.z, {
        shouldContinue = function() return not framework.isCancellationRequested(job) end,
    })
    if travelError == "JOB_CANCELLED" then return false, travelError end
    if not arrived then return false, "REPAIR_LOCATION_UNREACHABLE: " .. tostring(travelError) end
    local audit, found = markers.audit(markerType, p, { jobId = job.id })
    if audit == "OK" then return true, "MARKER_ALREADY_CORRECT" end
    if audit == "PLAYER_COMMAND" then
        return true, "PLAYER_COMMAND_RECORDED_NOT_REPLACED"
    end
    if found.kind == "ordinary" then
        return false, "REPAIR_BLOCKED_BY_ORDINARY_BLOCK: " .. tostring(found.block)
    end
    if framework.isCancellationRequested(job) then return false, "JOB_CANCELLED" end

    local placed, placeError = markers.place(markerType)
    if not placed then return false, placeError end
    job.progress.placed = true
    if not framework.checkpoint(job, "Marker repaired") then return false, "JOB_CANCELLED" end
    return true, "MARKER_REPAIRED"
end

return repairMarker
