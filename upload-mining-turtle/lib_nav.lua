local config = require("config")
local inventory = require("lib.inventory")
local markers = require("lib.markers")
local state = require("lib.state")
local util = require("lib.util")

local nav = {}

local headings = { "north", "east", "south", "west" }
local vectors = {
    north = { x = 0, z = -1 },
    east = { x = 1, z = 0 },
    south = { x = 0, z = 1 },
    west = { x = -1, z = 0 },
}

local movementApi = {
    forward = { move = turtle.forward, inspect = turtle.inspect, dig = turtle.dig, attack = turtle.attack },
    back = { move = turtle.back },
    up = { move = turtle.up, inspect = turtle.inspectUp, dig = turtle.digUp, attack = turtle.attackUp },
    down = { move = turtle.down, inspect = turtle.inspectDown, dig = turtle.digDown, attack = turtle.attackDown },
}

local function headingIndex(direction)
    for index, value in ipairs(headings) do
        if value == direction then
            return index
        end
    end
    return nil
end

local function rounded(value)
    return math.floor(value + 0.5)
end

local function gpsLocate()
    local x, y, z = gps.locate(config.gps.timeout, config.gps.debug)
    if not x then
        return nil, "GPS_UNAVAILABLE"
    end
    return { x = rounded(x), y = rounded(y), z = rounded(z) }
end

local function samePosition(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function classifyFailure(api)
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel <= 0 then
        return "NO_FUEL"
    end
    if api.inspect then
        local hasBlock, block = api.inspect()
        if hasBlock then
            return "BLOCK", block
        end
        return "ENTITY_OR_TRANSIENT"
    end
    return "ENTITY_OR_TRANSIENT"
end

local function positionAfter(kind, position, heading)
    local result = { x = position.x, y = position.y, z = position.z }
    if kind == "up" then
        result.y = result.y + 1
    elseif kind == "down" then
        result.y = result.y - 1
    else
        local vector = vectors[heading]
        local sign = kind == "back" and -1 or 1
        result.x = result.x + vector.x * sign
        result.z = result.z + vector.z * sign
    end
    return result
end

function nav.getPosition()
    return util.copy(state.get().position)
end

function nav.getHeading()
    return state.get().heading
end

function nav.syncGps(required)
    if not inventory.hasPeripheralType("modem") then
        if not required then
            return false, "MODEM_NOT_EQUIPPED"
        end
        local modemOk, modemError = inventory.ensureModem()
        if not modemOk then
            return false, modemError
        end
    end
    local actual, gpsError = gpsLocate()
    if not actual then
        return false, gpsError
    end

    local data = state.get()
    local expected = data.position
    local drifted = expected and not samePosition(expected, actual)
    if drifted then
        data.recoveryObservedPosition = actual
        state.setError("GPS_POSITION_MISMATCH", "GPS does not match committed local position", {
            expected = expected,
            actual = actual,
        })
        return false, "GPS_POSITION_MISMATCH", true
    end
    data.position = actual
    data.recoveryObservedPosition = nil
    data.positionVerifiedAt = util.now()
    data.movesSinceGps = 0
    data.pendingMove = nil
    state.save()
    return true, actual, false
end

local function determineHeading()
    local data = state.get()
    local origin = data.position
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and (type(fuel) ~= "number" or fuel <= 0) then
        return false, "NO_FUEL"
    end
    local blocked = {}
    for attempt = 1, 4 do
        local movedForward = false
        local moveError
        for retry = 1, config.movement.retries do
            data.pendingMove = { kind = "heading_probe", from = util.copy(origin), at = util.now() }
            state.save()
            local moved
            moved, moveError = turtle.forward()
            if moved then
                movedForward = true
                break
            end
            local hasBlock, block = turtle.inspect()
            if hasBlock then
                blocked[attempt] = block and block.name or "BLOCK"
                break
            end
            sleep(config.movement.retryDelay)
        end
        if movedForward then
            local moved, gpsError = gpsLocate()
            if not moved then
                return false, gpsError
            end
            local dx, dz = moved.x - origin.x, moved.z - origin.z
            local found
            for direction, vector in pairs(vectors) do
                if vector.x == dx and vector.z == dz and moved.y == origin.y then
                    found = direction
                    break
                end
            end
            if not found then
                return false, "GPS_HEADING_PROBE_INVALID_DELTA"
            end

            local returned = false
            for retry = 1, config.movement.retries do
                if turtle.back() then
                    returned = true
                    break
                end
                sleep(config.movement.retryDelay)
            end
            data.heading = found
            data.position = returned and origin or moved
            data.positionVerifiedAt = util.now()
            data.pendingMove = nil
            data.movesSinceGps = 0
            state.save()
            if not returned then
                util.log("WARN", "Heading probe could not return to its origin", { position = moved })
            end
            return true, found
        end

        data.pendingMove = nil
        state.save()
        blocked[attempt] = blocked[attempt] or moveError or "ENTITY_OR_TRANSIENT"
        if attempt < 4 then
            if not turtle.turnRight() then
                return false, "HEADING_PROBE_TURN_FAILED"
            end
        end
    end
    return false, "HEADING_UNDETERMINED: " .. table.concat(blocked, ", ")
end

local function pendingPositionMatches(pending, actual)
    if not pending then return false end
    if samePosition(pending.from, actual) or samePosition(pending.target, actual) then return true end
    if pending.kind == "heading_probe" and pending.from and actual.y == pending.from.y then
        return math.abs(actual.x - pending.from.x) + math.abs(actual.z - pending.from.z) == 1
    end
    return false
end

function nav.bootstrap(allowDisplacement)
    state.setStatus("RECOVERING", "Acquiring GPS position and heading")
    local equipmentOk, equipmentError = inventory.reconcile()
    if not equipmentOk then
        state.setError("EQUIPMENT_RECOVERY_FAILED", tostring(equipmentError))
        return false, equipmentError
    end
    inventory.refuelTo(config.inventory.startupFuel)
    local modemOk, modemError = inventory.ensureModem()
    if not modemOk then
        state.setError("GPS_BOOT_FAILED", tostring(modemError))
        return false, modemError
    end
    local actual, gpsError = gpsLocate()
    if not actual then
        state.setError("GPS_BOOT_FAILED", tostring(gpsError))
        return false, gpsError
    end

    local data = state.get()
    local committed = data.position
    local unexplained = committed and not samePosition(committed, actual)
        and not pendingPositionMatches(data.pendingMove, actual)
    if unexplained and not allowDisplacement then
        data.recoveryObservedPosition = actual
        state.setError("UNEXPLAINED_GPS_DISPLACEMENT", "Manual recovery approval required", {
            committed = committed,
            actual = actual,
        })
        return false, ("UNEXPLAINED_GPS_DISPLACEMENT saved=(%d,%d,%d) actual=(%d,%d,%d); run 'worker recover'"):format(
            committed.x, committed.y, committed.z, actual.x, actual.y, actual.z
        )
    end
    if unexplained and data.currentJob then
        data.currentJob.status = "FAILED"
        data.currentJob.failureReason = "POSITION_CHANGED_DURING_MANUAL_RECOVERY"
    end
    data.position = actual
    data.recoveryObservedPosition = nil
    data.positionVerifiedAt = util.now()
    data.movesSinceGps = 0
    data.pendingMove = nil
    state.save()

    local headingOk, headingOrError = determineHeading()
    if not headingOk then
        state.setError("HEADING_BOOT_FAILED", tostring(headingOrError), { position = actual })
        if headingOrError == "NO_FUEL" then
            state.setStatus("NEEDS_FUEL", "Add fuel, run 'refuel all', then type 'setup'")
        else
            state.setStatus("RECOVERING", tostring(headingOrError) .. "; fix the problem, then type 'setup'")
        end
        return false, headingOrError
    end
    if data.currentJob and data.currentJob.status == "FAILED" then
        state.setStatus("JOB_FAILED", data.currentJob.failureReason)
    else
        state.setStatus("IDLE")
    end
    if not data.home then
        data.home = {
            position = util.copy(data.position),
            heading = data.heading,
            setAt = util.now(),
        }
        state.save()
        util.log("INFO", "Set initial turtle home", data.home)
    end
    util.log("INFO", "Navigation initialized", {
        position = state.get().position,
        heading = headingOrError,
    })
    return true
end

local function move(kind, options)
    options = options or {}
    local api = movementApi[kind]
    if not api then
        return false, "INVALID_MOVEMENT"
    end
    local data = state.get()
    if not data.position or not data.heading then
        return false, "NAVIGATION_NOT_INITIALIZED"
    end

    local retries = options.dig and config.movement.digRetries or config.movement.retries
    local target = positionAfter(kind, data.position, data.heading)
    data.pendingMove = {
        kind = kind,
        from = util.copy(data.position),
        target = util.copy(target),
        at = util.now(),
    }
    state.save()

    local lastReason, lastBlock
    for attempt = 1, retries do
        if api.move() then
            data.position = target
            data.pendingMove = nil
            data.movesSinceGps = (data.movesSinceGps or 0) + 1
            state.save()
            if data.movesSinceGps >= config.gps.resyncMoves then
                local syncOk, syncError = nav.syncGps(false)
                if not syncOk then
                    util.log("WARN", "Periodic GPS synchronization deferred", { reason = syncError })
                end
            end
            return true
        end

        lastReason, lastBlock = classifyFailure(api)
        if lastReason == "NO_FUEL" then
            data.pendingMove = nil
            state.save()
            state.setStatus("NEEDS_FUEL", "Movement requires fuel")
            return false, lastReason
        end

        if lastReason == "BLOCK" and options.dig and api.dig then
            if lastBlock and markers.isProtectedBlock(lastBlock.name) then
                data.pendingMove = nil
                state.save()
                return false, "PROTECTED_MARKER", lastBlock
            end
            local dug, digError = api.dig()
            if not dug then
                if inventory.freeSlots() == 0 then
                    lastReason = "NEEDS_INVENTORY_SPACE"
                    data.pendingMove = nil
                    state.save()
                    state.setStatus("NEEDS_INVENTORY_SPACE", "No empty inventory slot while digging")
                    return false, lastReason, lastBlock
                end
                lastReason = "UNBREAKABLE_BLOCK"
                if digError then
                    lastReason = lastReason .. ": " .. tostring(digError)
                end
                sleep(config.movement.retryDelay)
            end
        elseif lastReason == "BLOCK" then
            break
        else
            state.setStatus("WAITING_BLOCKED", "Possible turtle or entity in path")
            sleep(config.movement.retryDelay)
        end
    end

    data.pendingMove = nil
    state.save()
    local syncOk, syncError = nav.syncGps(false)
    if not syncOk then
        util.log("WARN", "GPS unavailable after movement failure", { reason = syncError })
    end
    return false, lastReason or "MOVEMENT_FAILED", lastBlock
end

function nav.forward(options) return move("forward", options) end
function nav.back(options) return move("back", options) end
function nav.up(options) return move("up", options) end
function nav.down(options) return move("down", options) end

function nav.turnLeft()
    local data = state.get()
    if not data.heading then return false, "HEADING_UNKNOWN" end
    if not turtle.turnLeft() then return false, "TURN_FAILED" end
    local index = headingIndex(data.heading)
    data.heading = headings[((index + 2) % 4) + 1]
    state.save()
    return true
end

function nav.turnRight()
    local data = state.get()
    if not data.heading then return false, "HEADING_UNKNOWN" end
    if not turtle.turnRight() then return false, "TURN_FAILED" end
    local index = headingIndex(data.heading)
    data.heading = headings[(index % 4) + 1]
    state.save()
    return true
end

function nav.face(direction)
    local target = headingIndex(direction)
    local current = headingIndex(state.get().heading)
    if not target then return false, "INVALID_DIRECTION" end
    if not current then return false, "HEADING_UNKNOWN" end
    local delta = (target - current) % 4
    if delta == 0 then return true end
    if delta == 1 then return nav.turnRight() end
    if delta == 3 then return nav.turnLeft() end
    local first, firstError = nav.turnRight()
    if not first then return false, firstError end
    return nav.turnRight()
end

local function travelAxis(axis, target, options)
    while state.get().position[axis] ~= target do
        if options and options.shouldContinue and not options.shouldContinue() then
            return false, "JOB_CANCELLED"
        end
        local current = state.get().position[axis]
        local ok, reason, block
        if axis == "y" then
            if target > current then ok, reason, block = nav.up(options)
            else ok, reason, block = nav.down(options) end
        else
            local direction
            if axis == "x" then direction = target > current and "east" or "west"
            else direction = target > current and "south" or "north" end
            local faced, faceError = nav.face(direction)
            if not faced then return false, faceError end
            ok, reason, block = nav.forward(options)
        end
        if not ok then return false, reason, block end
    end
    return true
end

function nav.gotoXYZ(x, y, z, options)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return false, "INVALID_DESTINATION"
    end
    local targets = { x = x, y = y, z = z }
    for _, axis in ipairs((options and options.routeOrder) or config.movement.routeOrder) do
        local ok, reason, block = travelAxis(axis, targets[axis], options)
        if not ok then return false, reason, block end
    end
    return true
end

function nav.overflyXYZ(x, y, z, options)
    options = options or {}
    local maximumY = tonumber(options.maximumY)
    if not maximumY or maximumY ~= math.floor(maximumY) then
        return false, "INVALID_OVERFLIGHT_MAXIMUM"
    end
    local horizontalOptions = {
        shouldContinue = options.shouldContinue,
        routeOrder = { "x", "z" },
    }
    local verticalOptions = {
        shouldContinue = options.shouldContinue,
        routeOrder = { "y" },
    }
    while true do
        local current = nav.getPosition()
        local crossed, crossError, block = nav.gotoXYZ(
            x, current.y, z, horizontalOptions
        )
        if crossed then
            local descended, descendError, descendBlock = nav.gotoXYZ(
                x, y, z, verticalOptions
            )
            if descended then return true end
            if descendError == "BLOCK" then
                return false, "OVERFLIGHT_DESTINATION_BLOCKED", descendBlock
            end
            return false, descendError, descendBlock
        end
        if crossError ~= "BLOCK" then return false, crossError, block end
        current = nav.getPosition()
        if current.y >= maximumY then return false, "OVERFLIGHT_LIMIT", block end
        local raised, raiseError, raiseBlock = nav.up({
            shouldContinue = options.shouldContinue,
        })
        if not raised then
            if raiseError == "BLOCK" then
                return false, "OVERFLIGHT_ASCENT_BLOCKED", raiseBlock
            end
            return false, raiseError, raiseBlock
        end
    end
end

function nav.directionVector(direction)
    return util.copy(vectors[direction])
end

return nav
