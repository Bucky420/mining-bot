local config = require("config")
local inventory = require("lib.inventory")
local markers = require("lib.markers")
local nav = require("lib.nav")
local util = require("lib.util")

local digTunnel = {}

local directions = { north = true, east = true, south = true, west = true }

local function rightVector(direction)
    if direction == "north" then return { x = 1, z = 0 } end
    if direction == "east" then return { x = 0, z = 1 } end
    if direction == "south" then return { x = -1, z = 0 } end
    return { x = 0, z = -1 }
end

local function profileFor(parameters)
    local profileName = parameters.profile or config.defaultProfile
    local configured = config.profiles[profileName]
    if not configured then return nil, "UNKNOWN_PROFILE: " .. tostring(profileName) end
    local width = tonumber(parameters.width) or configured.width
    local height = tonumber(parameters.height) or configured.height
    if width < 1 or height < 1 or width ~= math.floor(width) or height ~= math.floor(height) then
        return nil, "INVALID_TUNNEL_DIMENSIONS"
    end
    return { name = profileName, width = width, height = height }
end

local function sliceTargets(origin, direction, depth, width, height)
    local forward = nav.directionVector(direction)
    local right = rightVector(direction)
    local firstOffset = -math.floor((width - 1) / 2)
    local lastOffset = firstOffset + width - 1
    local targets = {}

    for level = 0, height - 1 do
        if level % 2 == 0 then
            for offset = firstOffset, lastOffset do
                table.insert(targets, {
                    x = origin.x + forward.x * depth + right.x * offset,
                    y = origin.y + level,
                    z = origin.z + forward.z * depth + right.z * offset,
                })
            end
        else
            for offset = lastOffset, firstOffset, -1 do
                table.insert(targets, {
                    x = origin.x + forward.x * depth + right.x * offset,
                    y = origin.y + level,
                    z = origin.z + forward.z * depth + right.z * offset,
                })
            end
        end
    end
    table.insert(targets, {
        x = origin.x + forward.x * depth,
        y = origin.y,
        z = origin.z + forward.z * depth,
    })
    return targets
end

function digTunnel.run(job, framework)
    local parameters = job.parameters
    local direction = string.lower(tostring(parameters.direction or ""))
    if not directions[direction] then return false, "INVALID_TUNNEL_DIRECTION" end
    local length = tonumber(parameters.length)
    if not length or length < 1 or length ~= math.floor(length) then
        return false, "TUNNEL_LENGTH_MUST_BE_POSITIVE_INTEGER"
    end
    local profile = job.progress.profile
    if not profile then
        local profileError
        profile, profileError = profileFor(parameters)
        if not profile then return false, profileError end
        job.progress.profile = profile
    end

    local toolOk, toolError = inventory.ensureMiningTool()
    if not toolOk then return false, "NEEDS_TOOL: " .. tostring(toolError) end

    job.progress.origin = job.progress.origin or nav.getPosition()
    job.progress.depth = job.progress.depth or 0
    job.progress.cell = job.progress.cell or 1
    if not framework.checkpoint(job, "Mining tunnel") then return false, "JOB_CANCELLED" end

    while job.progress.depth < length do
        local depth = job.progress.depth
        local center = sliceTargets(job.progress.origin, direction, depth, 1, 1)[1]
        local atCenter, centerError = nav.gotoXYZ(center.x, center.y, center.z, {
            dig = true,
            shouldContinue = function() return not framework.isCancellationRequested(job) end,
        })
        if centerError == "JOB_CANCELLED" then return false, centerError end
        if not atCenter then return false, "CANNOT_REACH_SLICE_CENTER: " .. tostring(centerError) end

        if job.progress.cell == 1 then
            local capped, marker = markers.isCap()
            if capped then
                job.progress.stoppedByCap = true
                job.progress.capPosition = nav.getPosition()
                if not framework.checkpoint(job, "Stopped at intentional cap") then return false, "JOB_CANCELLED" end
                inventory.ensureModem()
                nav.syncGps(false)
                return true, {
                    minedLength = depth,
                    requestedLength = length,
                    stoppedByCap = true,
                    marker = marker.block,
                }
            end
        end

        local targets = sliceTargets(job.progress.origin, direction, depth + 1, profile.width, profile.height)
        while job.progress.cell <= #targets do
            local target = targets[job.progress.cell]
            local moved, moveError, block = nav.gotoXYZ(target.x, target.y, target.z, {
                dig = true,
                shouldContinue = function() return not framework.isCancellationRequested(job) end,
            })
            if moveError == "JOB_CANCELLED" then return false, moveError end
            if not moved then
                return false, ("DIG_FAILED_AT_DEPTH_%d_CELL_%d: %s%s"):format(
                    depth + 1,
                    job.progress.cell,
                    tostring(moveError),
                    block and (" (" .. tostring(block.name) .. ")") or ""
                )
            end
            job.progress.cell = job.progress.cell + 1
            if not framework.checkpoint(job, ("Tunnel depth %d/%d"):format(depth + 1, length)) then
                return false, "JOB_CANCELLED"
            end
        end
        job.progress.depth = depth + 1
        job.progress.cell = 1
        if not framework.checkpoint(job, ("Completed tunnel slice %d/%d"):format(job.progress.depth, length)) then
            return false, "JOB_CANCELLED"
        end
    end

    local modemOk, modemError = inventory.ensureModem()
    if modemOk then
        nav.syncGps(false)
    else
        util.log("WARN", "Tunnel complete but modem could not be restored", { reason = modemError })
    end
    return true, {
        minedLength = length,
        profile = profile.name,
        width = profile.width,
        height = profile.height,
        stoppedByCap = false,
    }
end

return digTunnel
