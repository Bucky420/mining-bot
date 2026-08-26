local config = require("config")
local inventory = require("lib.inventory")
local map = require("lib.map")
local nav = require("lib.nav")
local network = require("lib.network")
local scanner = require("lib.scanner")
local state = require("lib.state")
local station = require("lib.station")
local terrain = require("lib.farm_terrain")
local util = require("lib.util")

local service = {}
local SURVEY_INTERVAL_MS = 300000
local HARVEST_INTERVAL_MS = 60000
local SCAN_CACHE_LIMIT = 4
local classCodes = {
    air = "a", grass = "g", dirt = "d", farmland = "f", vegetation = "v",
    tree_log = "l", tree_leaves = "e", fence = "n", water = "w", lava = "x",
    sand = "s", stone = "t", crop = "c", unknown = "u", hard = "h",
}
local codeClasses = {}
for name, code in pairs(classCodes) do codeClasses[code] = name end
local vectors = {
    north = { x = 0, z = -1 },
    east = { x = 1, z = 0 },
    south = { x = 0, z = 1 },
    west = { x = -1, z = 0 },
}

local function copy(value) return util.detachedCopy(value) end
local function key(x, z) return terrain.key(x, z) end

local function shouldContinue(job, framework)
    return not framework.isCancellationRequested(job)
end

local function checkpoint(job, framework, detail)
    return framework.checkpoint(job, detail)
end

local function addAlert(progress, message)
    progress.alerts = progress.alerts or {}
    progress.alerts[#progress.alerts + 1] = tostring(message)
    while #progress.alerts > 100 do table.remove(progress.alerts, 1) end
end

local function currentFrontAnchor()
    local wrapped = peripheral.wrap("front")
    if not wrapped or type(wrapped.list) ~= "function" or type(wrapped.size) ~= "function" then
        return nil
    end
    local blockPresent, block = turtle.inspect()
    if not blockPresent or type(block) ~= "table" or type(block.name) ~= "string"
        or not block.name:find(config.scanner.chestNameContains, 1, true) then return nil end
    local position, vector = nav.getPosition(), vectors[nav.getHeading()]
    if not position or not vector then return nil end
    return {
        name = peripheral.getType("front") or "inventory",
        x = position.x + vector.x,
        y = position.y,
        z = position.z + vector.z,
        approach = copy(position),
        direction = nav.getHeading(),
    }
end

local function nearestAnchor(result)
    local position = nav.getPosition()
    local best, bestDistance
    for _, chest in ipairs(result and result.chests or {}) do
        for _, approach in ipairs(chest.approaches or {}) do
            local distance = math.abs(position.x - approach.x)
                + math.abs(position.y - approach.y) + math.abs(position.z - approach.z)
            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                best = {
                    name = chest.name, x = chest.x, y = chest.y, z = chest.z,
                    approach = { x = approach.x, y = approach.y, z = approach.z },
                    direction = approach.direction,
                }
            end
        end
    end
    return best
end

local function findAnchor(job, framework)
    local direct = currentFrontAnchor()
    if direct then return direct end
    local result, scanError = scanner.scan(config.scanner.maxRadius)
    if not result then return nil, "NEEDS_SCANNER: " .. tostring(scanError) end
    local candidate = nearestAnchor(result)
    if not candidate then return nil, "FARM_ANCHOR_NOT_FOUND" end
    local arrived, travelError = nav.gotoXYZ(
        candidate.approach.x, candidate.approach.y, candidate.approach.z,
        { shouldContinue = function() return shouldContinue(job, framework) end }
    )
    if not arrived then return nil, "FARM_ANCHOR_UNREACHABLE: " .. tostring(travelError) end
    local faced, faceError = nav.face(candidate.direction)
    if not faced then return nil, "FARM_ANCHOR_FACE_FAILED: " .. tostring(faceError) end
    if not currentFrontAnchor() then return nil, "FARM_ANCHOR_NOT_INVENTORY" end
    return candidate
end

local function plannedPath(progress, start, target)
    if type(progress.navAllowed) ~= "table" then return nil end
    if start.x == target.x and start.z == target.z then return {} end
    if not progress.navAllowed[key(target.x, target.z)] then return nil end
    return terrain.turnEfficientPath(progress.navAllowed, start, target, nav.getHeading(), 2)
end

local opposite = { north = "south", east = "west", south = "north", west = "east" }

local function orderedDirections(position, target)
    local result = { "north", "east", "south", "west" }
    table.sort(result, function(a, b)
        local av, bv = vectors[a], vectors[b]
        local ad = math.abs(position.x + av.x - target.x) + math.abs(position.z + av.z - target.z)
        local bd = math.abs(position.x + bv.x - target.x) + math.abs(position.z + bv.z - target.z)
        return ad == bd and a < b or ad < bd
    end)
    return result
end

local function insideNavigationBoundary(progress, x, z)
    return terrain.inRadius(progress.anchor.x, progress.anchor.z, x, z, progress.radius + 3)
end

local function riseThroughCanopy(progress, cruiseY, target, continueRoute, maximumVisits)
    local visited, visits = {}, 0
    local options = {
        shouldContinue = continueRoute,
        routeOrder = { "y" },
    }
    local function search()
        if not continueRoute() then return false, "JOB_CANCELLED" end
        local current = nav.getPosition()
        local raised, raiseError = nav.gotoXYZ(current.x, cruiseY, current.z, options)
        if raised then return true end
        if raiseError ~= "BLOCK" then return false, raiseError end
        current = nav.getPosition()
        local currentKey = ("%d:%d:%d"):format(current.x, current.y, current.z)
        if visited[currentKey] or visits >= maximumVisits then return false, "CANOPY_ESCAPE_EXHAUSTED" end
        visited[currentKey], visits = true, visits + 1
        for _, direction in ipairs(orderedDirections(current, target)) do
            local vector = vectors[direction]
            local nextX, nextZ = current.x + vector.x, current.z + vector.z
            local nextKey = ("%d:%d:%d"):format(nextX, current.y, nextZ)
            if not visited[nextKey] and insideNavigationBoundary(progress, nextX, nextZ) then
                local faced, faceError = nav.face(direction)
                if not faced then return false, faceError end
                local blocked = turtle.inspect()
                if not blocked then
                    local parent = nav.getPosition()
                    local moved, moveError = nav.forward(options)
                    if moved then
                        local found, escapeError = search()
                        if found then return true end
                        local descended, descendError = nav.gotoXYZ(
                            nav.getPosition().x, parent.y, nav.getPosition().z,
                            { routeOrder = { "y" } }
                        )
                        if not descended then
                            return false, "CANOPY_BACKTRACK_HEIGHT_FAILED: " .. tostring(descendError)
                        end
                        local returnedFace, returnedFaceError = nav.face(opposite[direction])
                        if not returnedFace then return false, returnedFaceError end
                        local returned, returnError = nav.forward()
                        if not returned then
                            return false, "CANOPY_BACKTRACK_FAILED: " .. tostring(returnError)
                        end
                        if escapeError == "JOB_CANCELLED" then return false, escapeError end
                    elseif moveError == "JOB_CANCELLED" then
                        return false, moveError
                    end
                end
            end
        end
        return false, "CANOPY_ESCAPE_EXHAUSTED"
    end
    return search()
end

local function travelCruise(progress, x, y, z, job, framework, ignoreCancellation)
    local options = {
        shouldContinue = function()
            return ignoreCancellation == true or shouldContinue(job, framework)
        end,
        routeOrder = { "y", "x", "z" },
    }
    local position = nav.getPosition()
    if position.y == y and math.abs(position.x - x) + math.abs(position.z - z) == 1 then
        return nav.gotoXYZ(x, y, z, {
            shouldContinue = options.shouldContinue,
            routeOrder = { "x", "z", "y" },
        })
    end
    local cruiseY = progress.baseY + 5
    if position.y < cruiseY then
        local raised, raiseError = riseThroughCanopy(
            progress, cruiseY, { x = x, z = z }, options.shouldContinue, 64
        )
        if not raised then return false, raiseError end
    end
    local crossed, crossError
    if progress.navAllowed then
        for _ = 1, 4 do
            local current = nav.getPosition()
            local path = plannedPath(progress, current, { x = x, z = z })
            if not path then break end
            crossed = true
            for _, point in ipairs(path) do
                crossed, crossError = nav.gotoXYZ(point.x, cruiseY, point.z, {
                    shouldContinue = options.shouldContinue,
                    routeOrder = { "x", "z", "y" },
                })
                if not crossed then
                    progress.navAllowed[key(point.x, point.z)] = false
                    break
                end
            end
            if crossed then break end
        end
        if not crossed then
            local route, routeError, routeRevision = network.requestFarmRoute(
                progress.farm and progress.farm.id,
                nav.getPosition(), { x = x, z = z }, nav.getHeading(), progress.farmRevision
            )
            if route then
                crossed = true
                progress.controllerRouteRevision = routeRevision
                for _, point in ipairs(route) do
                    crossed, crossError = nav.gotoXYZ(point.x, cruiseY, point.z, {
                        shouldContinue = options.shouldContinue,
                        routeOrder = { "x", "z", "y" },
                    })
                    if not crossed then
                        progress.navAllowed[key(point.x, point.z)] = false
                        break
                    end
                end
            else
                crossError = routeError
            end
        end
        if not crossed then
            crossed, crossError = nav.overflyXYZ(x, y, z, {
                shouldContinue = options.shouldContinue,
                maximumY = cruiseY + config.farming.maxOverflightRise,
            })
        end
    else
        if progress.farm then
            local route, routeError, routeRevision = network.requestFarmRoute(
                progress.farm.id, nav.getPosition(), { x = x, z = z }, nav.getHeading(),
                progress.farmRevision
            )
            if route then
                crossed = true
                progress.controllerRouteRevision = routeRevision
                for _, point in ipairs(route) do
                    crossed, crossError = nav.gotoXYZ(point.x, cruiseY, point.z, {
                        shouldContinue = options.shouldContinue,
                        routeOrder = { "x", "z", "y" },
                    })
                    if not crossed then break end
                end
            else
                crossError = routeError
            end
        else
            crossed, crossError = nav.gotoXYZ(x, cruiseY, z, {
                shouldContinue = options.shouldContinue, routeOrder = { "x", "z", "y" },
            })
        end
        if not crossed then
            crossed, crossError = nav.overflyXYZ(x, y, z, {
                shouldContinue = options.shouldContinue,
                maximumY = cruiseY + config.farming.maxOverflightRise,
            })
        end
    end
    if not crossed then return false, crossError or "NO_SAFE_ROUTE_AROUND_BOUNDARY" end
    return nav.gotoXYZ(x, y, z, options)
end

local function arriveAnchor(progress, job, framework)
    local anchor = progress.anchor
    local arrived, travelError = travelCruise(
        progress, anchor.approach.x, anchor.approach.y, anchor.approach.z, job, framework
    )
    if not arrived then return false, "ANCHOR_TRAVEL_FAILED: " .. tostring(travelError) end
    local faced, faceError = nav.face(anchor.direction)
    if not faced then return false, "ANCHOR_FACE_FAILED: " .. tostring(faceError) end
    local verified = currentFrontAnchor()
    if not verified or verified.x ~= anchor.x or verified.y ~= anchor.y or verified.z ~= anchor.z then
        return false, "ANCHOR_CHEST_CHANGED"
    end
    local wrapped = peripheral.wrap("front")
    if not wrapped or type(wrapped.list) ~= "function" then return false, "ANCHOR_NOT_INVENTORY" end
    return true, wrapped
end

local function serviceFailure(progress, job, framework, reason)
    local wasCancelled = tostring(reason):find("JOB_CANCELLED", 1, true) ~= nil
        or not shouldContinue(job, framework)
    if wasCancelled and progress.anchor then
        local anchor = progress.anchor
        local returned, returnError = travelCruise(
            progress, anchor.approach.x, anchor.approach.y, anchor.approach.z,
            job, framework, true
        )
        if returned then nav.face(anchor.direction)
        else addAlert(progress, "CANCEL_RETURN_FAILED: " .. tostring(returnError)) end
    end
    return false, wasCancelled and "JOB_CANCELLED" or reason
end

local function seedDetail(detail)
    if type(detail) ~= "table" or type(detail.name) ~= "string" then return false end
    local name = detail.name:lower()
    return inventory.itemHasAnyTag(detail, {
        "minecraft:seeds", "c:seeds", "forge:seeds", "seeds",
    }) or name:find("seed", 1, true) ~= nil
        or name == "minecraft:carrot" or name == "minecraft:potato"
end

local function wormDetail(detail)
    return type(detail) == "table" and type(detail.name) == "string"
        and detail.name:lower():find("actuallyadditions:", 1, true) ~= nil
        and detail.name:lower():find("worm", 1, true) ~= nil
end

local function supplyDetail(detail)
    if seedDetail(detail) or wormDetail(detail) then return true end
    local name = detail and detail.name
    if name == "minecraft:dirt" or name == "minecraft:water_bucket"
        or name == "minecraft:bucket" or name == "minecraft:diamond_pickaxe"
        or name == "minecraft:diamond_hoe" then return true end
    for _, fuel in ipairs(config.inventory.fuelItems) do
        if name == fuel then return true end
    end
    return false
end

local function chestItems(wrapped)
    local result = {}
    for slot, summary in pairs(wrapped.list()) do
        local detail = summary
        if type(wrapped.getItemDetail) == "function" then
            local ok, found = pcall(wrapped.getItemDetail, slot)
            if ok and type(found) == "table" then detail = found end
        end
        if type(detail) == "table" and type(detail.name) == "string" then
            detail.count = tonumber(detail.count) or tonumber(summary.count) or 0
            if not result[detail.name] then
                result[detail.name] = detail
                result[detail.name].count = detail.count
            else
                result[detail.name].count = result[detail.name].count + detail.count
            end
        end
    end
    return result
end

local function desiredSupply(name, detail)
    if seedDetail(detail) or wormDetail(detail) then return math.min(detail.count, 64) end
    if name == "minecraft:dirt" then return 64 end
    if name == "minecraft:water_bucket" or name == "minecraft:bucket"
        or name == "minecraft:diamond_pickaxe" or name == "minecraft:diamond_hoe" then return 1 end
    return 64
end

local function pollSupplies(progress, job, framework)
    local arrived, wrappedOrError = arriveAnchor(progress, job, framework)
    if not arrived then return false, wrappedOrError end
    local wrapped = wrappedOrError
    for name, detail in pairs(chestItems(wrapped)) do
        if supplyDetail(detail) and inventory.freeSlots() > 0 then
            local target = inventory.countItem(name) + desiredSupply(name, detail)
            inventory.pullItemFromFront(name, target)
        end
    end
    -- The service returns to the chest before its reserve becomes unsafe, so it
    -- only needs a useful work batch here rather than fuel for the whole farm.
    local fuelTarget = math.max(1000,
        progress.radius * 32 + config.inventory.jobFuelReserve)
    local fuelLimit = turtle.getFuelLimit()
    if type(fuelLimit) == "number" then fuelTarget = math.min(fuelTarget, fuelLimit) end
    local fueled, level = inventory.refuelTo(fuelTarget)
    for _ = 1, 16 do
        if fueled then break end
        local gained = false
        for _, fuelName in ipairs(config.inventory.fuelItems) do
            local before = inventory.countItem(fuelName)
            inventory.pullItemFromFront(fuelName, before + 64)
            if inventory.countItem(fuelName) > before then gained = true end
        end
        fueled, level = inventory.refuelTo(fuelTarget)
        if not gained then break end
    end
    if not fueled then return false, "NEEDS_FUEL_RESERVE: " .. tostring(level)
        .. "/" .. tostring(fuelTarget) end
    return true
end

local function seedStock()
    local stock = {}
    for _, detail in ipairs(inventory.listItemsDetailed()) do
        if seedDetail(detail) and not inventory.isProtectedItem(detail.name) then
            stock[detail.name] = (stock[detail.name] or 0) + detail.count
        end
    end
    return stock
end

local function actionableStock()
    local stock = {}
    for _, detail in ipairs(inventory.listItemsDetailed()) do
        if supplyDetail(detail) then stock[detail.name] = (stock[detail.name] or 0) + detail.count end
    end
    return stock
end

local function stockIncreased(previous, current)
    if type(previous) ~= "table" then return false end
    for name, count in pairs(current or {}) do
        if count > (tonumber(previous[name]) or 0) then return true end
    end
    return false
end

local function returnFuelRequired(progress)
    local position, anchor = nav.getPosition(), progress.anchor.approach
    return math.abs(position.x - anchor.x) + math.abs(position.y - anchor.y)
        + math.abs(position.z - anchor.z) + progress.radius * 4
        + config.inventory.jobFuelReserve
end

local function refuelIfNeeded(progress, job, framework)
    local level = turtle.getFuelLevel()
    if level == "unlimited" or type(level) == "number" and level >= returnFuelRequired(progress) + 256 then
        return true
    end
    return pollSupplies(progress, job, framework)
end

local function selected(slot, callback)
    local previous = turtle.getSelectedSlot()
    turtle.select(slot)
    local results = table.pack(callback())
    turtle.select(previous)
    return table.unpack(results, 1, results.n)
end

local function nameId(progress, name)
    progress.surfaceNames = progress.surfaceNames or {}
    name = tostring(name or "")
    for index, existing in ipairs(progress.surfaceNames) do
        if existing == name then return index end
    end
    progress.surfaceNames[#progress.surfaceNames + 1] = name
    return #progress.surfaceNames
end

local function encodeSurface(progress, surface)
    local occupant = surface.occupant
    return table.concat({
        tostring(surface.surfaceY),
        classCodes[surface.class] or classCodes.unknown,
        tostring(nameId(progress, surface.ground and surface.ground.name or surface.name)),
        occupant and (classCodes[occupant.class] or classCodes.unknown) or "-",
        occupant and tostring(nameId(progress, occupant.name)) or "0",
        occupant and tostring(occupant.y) or "0",
        surface.verticalStructure and "1" or "0",
    }, ",")
end

local function decodeSurface(progress, columnKey, encoded)
    local fields = {}
    for field in (encoded .. ","):gmatch("(.-),") do fields[#fields + 1] = field end
    local x, z = columnKey:match("^(-?%d+):(-?%d+)$")
    local surfaceY = tonumber(fields[1])
    local class = codeClasses[fields[2]] or "unknown"
    local groundName = progress.surfaceNames[tonumber(fields[3]) or 0] or "unknown"
    local occupantClass = fields[4] ~= "-" and (codeClasses[fields[4]] or "unknown") or nil
    local occupantName = occupantClass and progress.surfaceNames[tonumber(fields[5]) or 0] or nil
    local occupant = occupantClass and {
        class = occupantClass, name = occupantName, y = tonumber(fields[6]),
    } or nil
    return {
        x = tonumber(x), y = surfaceY, surfaceY = surfaceY, z = tonumber(z),
        class = class, name = groundName,
        ground = { class = class, name = groundName, y = surfaceY },
        occupant = occupant,
        clearance = { blocked = occupant ~= nil },
        verticalStructure = fields[7] == "1",
    }
end

local function mergeScan(progress, result)
    progress.surfaceColumns = progress.surfaceColumns or {}
    local relevant = {}
    for _, block in ipairs(result.blocks or {}) do
        if block.y >= progress.baseY - 4 and block.y <= progress.baseY + 8
            and terrain.inRadius(progress.anchor.x, progress.anchor.z,
                block.x, block.z, progress.radius) then
            relevant[#relevant + 1] = block
        end
    end
    local surfaces = terrain.buildSurface(
        relevant, progress.anchor, progress.radius, progress.baseY, 3
    )
    local delta, tileKeys = {}, {}
    for _, surface in ipairs(surfaces) do
        local columnKey = key(surface.x, surface.z)
        local encoded = encodeSurface(progress, surface)
        progress.surfaceColumns[columnKey] = encoded
        tileKeys[#tileKeys + 1] = columnKey
        delta[#delta + 1] = {
            x = surface.x, y = surface.surfaceY, z = surface.z,
            name = surface.ground and surface.ground.name or surface.name,
            class = surface.class,
            occupant = surface.occupant and surface.occupant.name or nil,
            occupantClass = surface.occupant and surface.occupant.class or nil,
            occupantY = surface.occupant and surface.occupant.y or nil,
            verticalStructure = surface.verticalStructure == true,
        }
    end
    progress.surfaceColumns, progress.scanTiles = terrain.retainScanTiles(
        progress.surfaceColumns, progress.scanTiles, tileKeys, SCAN_CACHE_LIMIT
    )
    progress.cacheColumnCount = 0
    for _ in pairs(progress.surfaceColumns) do
        progress.cacheColumnCount = progress.cacheColumnCount + 1
    end
    return delta
end

local function decodedSurfaces(progress)
    local surfaces = {}
    for columnKey, encoded in pairs(progress.surfaceColumns or {}) do
        surfaces[#surfaces + 1] = decodeSurface(progress, columnKey, encoded)
    end
    return surfaces
end

local function applyNavigationMap(progress, surfaces, planResult)
    progress.navAllowed = {}
    for _, surface in ipairs(surfaces) do
        progress.navAllowed[key(surface.x, surface.z)] = true
    end
    for _, excluded in ipairs(planResult.excluded or {}) do
        if excluded.reason == "hard" or excluded.reason == "hard_margin"
            or excluded.reason == "out_of_range" or excluded.reason == "tree_clearance"
            or excluded.reason == "unsafe_surface" then
            progress.navAllowed[key(excluded.x, excluded.z)] = false
        end
    end
    progress.navAllowed[key(progress.anchor.x, progress.anchor.z)] = false
    progress.navAllowed[key(progress.anchor.approach.x, progress.anchor.approach.z)] = true
end

local function refreshSurveyNavigation(progress)
    local surfaces = decodedSurfaces(progress)
    local provisional = terrain.plan(surfaces, {
        center = { x = progress.anchor.x, z = progress.anchor.z },
        radius = progress.radius,
        baseY = progress.baseY,
        maxOffset = 3,
        margin = 3,
        chests = { { x = progress.anchor.x, z = progress.anchor.z } },
        access = { progress.anchor.approach },
    })
    applyNavigationMap(progress, surfaces, provisional)
end

local function reportMap(progress, job, delta)
    progress.farmRevision = (progress.farmRevision or 0) + 1
    return network.report("FARM_MAP", {
        farmId = progress.farm.id,
        revision = progress.farmRevision,
        jobId = job.id,
        phase = progress.phase,
        center = { x = progress.anchor.x, y = progress.baseY, z = progress.anchor.z },
        radius = progress.radius,
        autoExpand = progress.autoExpand,
        cacheColumns = progress.cacheColumnCount or 0,
        summary = progress.planSummary,
        delta = copy(delta or {}),
        alerts = copy(progress.alerts),
    })
end

local function reportMapChunks(progress, job, delta)
    if #(delta or {}) == 0 then return reportMap(progress, job, {}) end
    for start = 1, #delta, 64 do
        local chunk = {}
        for index = start, math.min(start + 63, #delta) do chunk[#chunk + 1] = delta[index] end
        local reported, reportError = reportMap(progress, job, chunk)
        if not reported then return false, reportError end
    end
    return true
end

local function streamSurveyDelta(progress, job, delta)
    local restored, restoreError = inventory.ensureModem()
    if not restored then return false, "SURVEY_MODEM_RESTORE_FAILED: " .. tostring(restoreError) end
    network.flushReports(true)
    return reportMapChunks(progress, job, delta)
end

local function surveyPoints(progress)
    -- Six-block spacing keeps the next center inside the previously scanned
    -- safe area even when the scanner is several blocks above the surface.
    local step = math.max(1, config.scanner.maxRadius - 2)
    return terrain.surveySweepPoints(
        { x = progress.anchor.x, z = progress.anchor.z },
        progress.radius,
        step,
        progress.baseY + 5
    )
end

local function surveyRouteKey(progress)
    return ("sweep-v3:%d:%d:%d:%d:%d:%d"):format(
        progress.anchor.x,
        progress.anchor.z,
        progress.baseY,
        progress.radius,
        config.scanner.maxRadius,
        math.max(1, config.scanner.maxRadius - 2)
    )
end

local function survey(progress, job, framework)
    progress.phase = "SURVEY"
    progress.surfaceColumns = progress.surfaceColumns or {}
    progress.surfaceNames = progress.surfaceNames or {}
    if network.reportBacklogFull() then
        local restored, restoreError = inventory.ensureModem()
        if not restored then
            return false, "SURVEY_BACKLOG_MODEM_FAILED: " .. tostring(restoreError)
        end
        local flushed, flushError = network.flushReports(true)
        if not flushed then
            return false, "SURVEY_REPORT_BACKLOG_FULL: " .. tostring(flushError)
        end
    end
    if not progress.surveyNavigationReady then
        if next(progress.surfaceColumns) then refreshSurveyNavigation(progress) end
        local initial, initialError = scanner.scan(config.scanner.maxRadius)
        if not initial then return false, "INITIAL_FARM_SCAN_FAILED: " .. tostring(initialError) end
        local initialDelta = mergeScan(progress, initial)
        refreshSurveyNavigation(progress)
        local streamed, streamError = streamSurveyDelta(progress, job, initialDelta)
        if not streamed then return false, streamError end
        progress.surveyNavigationReady = true
        if not checkpoint(job, framework, "Farm survey initialized safely") then
            return false, "JOB_CANCELLED"
        end
    end
    local points = surveyPoints(progress)
    local routeKey = surveyRouteKey(progress)
    if progress.surveyRouteKey ~= routeKey then
        progress.surveyRouteKey = routeKey
        progress.surveyIndex = 1
        progress.surveyWaypointAttempts = nil
    end
    if type(progress.surveyIndex) ~= "number" or progress.surveyIndex ~= math.floor(progress.surveyIndex)
        or progress.surveyIndex < 1 or progress.surveyIndex > #points + 1 then progress.surveyIndex = 1 end
    progress.surveyIndex = progress.surveyIndex or 1
    while progress.surveyIndex <= #points do
        if not shouldContinue(job, framework) then return false, "JOB_CANCELLED" end
        local point = points[progress.surveyIndex]
        local arrived, travelError = travelCruise(progress, point.x, point.y, point.z, job, framework)
        local waypointError
        if arrived then
            local result, scanError = scanner.scan(config.scanner.maxRadius)
            if result then
                local delta = mergeScan(progress, result)
                refreshSurveyNavigation(progress)
                progress.surveyCount = (progress.surveyCount or 0) + 1
                local streamed, streamError = streamSurveyDelta(progress, job, delta)
                if not streamed then return false, streamError end
                progress.surveyWaypointAttempts = nil
            else
                waypointError = "SURVEY_FAILED: " .. tostring(scanError)
            end
        else
            waypointError = ("SURVEY_WAYPOINT_BLOCKED %d,%d: %s"):format(
                point.x, point.z, tostring(travelError)
            )
        end
        if waypointError then
            progress.surveyWaypointAttempts = (progress.surveyWaypointAttempts or 0) + 1
            if progress.surveyWaypointAttempts < 3 then
                if not checkpoint(job, framework, ("Retrying farm survey point %d/%d"):format(
                    progress.surveyIndex, #points
                )) then return false, "JOB_CANCELLED" end
                return false, waypointError
            end
            addAlert(progress, waypointError .. " (skipped after 3 attempts)")
            progress.surveyWaypointAttempts = nil
        end
        progress.surveyIndex = progress.surveyIndex + 1
        local fueled, fuelError = refuelIfNeeded(progress, job, framework)
        if not fueled then return false, fuelError end
        if not checkpoint(job, framework, ("Farm survey %d/%d"):format(
            progress.surveyIndex - 1, #points
        )) then return false, "JOB_CANCELLED" end
    end
    progress.surveyIndex = nil
    progress.surveyComplete = true
    return true
end

local function compactCell(cell)
    return {
        x = cell.x, z = cell.z, surfaceY = cell.surfaceY or cell.y,
        class = cell.class, action = cell.action, status = cell.status, reason = cell.reason,
        targetY = cell.targetY,
        groundName = cell.ground and cell.ground.name or cell.name,
        occupant = cell.occupant and {
            name = cell.occupant.name, class = cell.occupant.class,
            y = cell.occupant.y,
        } or nil,
    }
end

local actionCodes = { farm = "f", clear = "c", replace = "r", fill = "i" }
local codeActions = { f = "farm", c = "clear", r = "replace", i = "fill" }

local function planNameId(progress, name)
    if not name then return 0 end
    progress.planNames = progress.planNames or {}
    for index, existing in ipairs(progress.planNames) do
        if existing == name then return index end
    end
    progress.planNames[#progress.planNames + 1] = name
    return #progress.planNames
end

local function encodePlanCell(progress, cell)
    local occupant = cell.occupant
    return {
        cell.x, cell.z, cell.surfaceY or cell.y,
        classCodes[cell.class] or classCodes.unknown,
        actionCodes[cell.action] or "-",
        cell.targetY or 0,
        planNameId(progress, cell.groundName),
        occupant and planNameId(progress, occupant.name) or 0,
        occupant and (classCodes[occupant.class] or classCodes.unknown) or "-",
        occupant and occupant.y or 0,
        planNameId(progress, cell.cropId),
    }
end

local function decodePlanCell(progress, encoded)
    local occupantClass = encoded[9] ~= "-" and (codeClasses[encoded[9]] or "unknown") or nil
    return {
        x = encoded[1], z = encoded[2], surfaceY = encoded[3],
        class = codeClasses[encoded[4]] or "unknown",
        action = codeActions[encoded[5]],
        targetY = encoded[6] ~= 0 and encoded[6] or nil,
        groundName = progress.planNames[encoded[7]],
        occupant = occupantClass and {
            name = progress.planNames[encoded[8]], class = occupantClass, y = encoded[10],
        } or nil,
        cropId = encoded[11] ~= 0 and progress.planNames[encoded[11]] or nil,
    }
end

local function assignPlanRows(progress, cropIds)
    local decoded = {}
    for _, encoded in ipairs(progress.plan or {}) do
        decoded[#decoded + 1] = decodePlanCell(progress, encoded)
    end
    local assigned = terrain.alternatingRows(decoded, cropIds)
    progress.plan = {}
    for _, cell in ipairs(assigned) do
        progress.plan[#progress.plan + 1] = encodePlanCell(progress, cell)
    end
end

local function buildPlan(progress)
    local remoteCells, terrainError = network.requestFarmTerrain(
        progress.farm.id, progress.farmRevision
    )
    if not remoteCells then return false, "CONTROLLER_TERRAIN_REQUIRED: " .. tostring(terrainError) end
    local surfaces = {}
    for _, cell in ipairs(remoteCells) do
        local occupant = cell.occupant and {
            name = cell.occupant,
            class = cell.occupantClass or terrain.classifyBlock({ name = cell.occupant }),
            y = cell.occupantY,
        } or nil
        surfaces[#surfaces + 1] = {
            x = cell.x, y = cell.y, surfaceY = cell.y, z = cell.z,
            class = cell.class, name = cell.name,
            ground = { class = cell.class, name = cell.name, y = cell.y },
            occupant = occupant,
            clearance = { blocked = occupant ~= nil },
            verticalStructure = cell.verticalStructure == true,
        }
    end
    local observed = {}
    for _, surface in ipairs(surfaces) do observed[key(surface.x, surface.z)] = true end
    for x = progress.anchor.x - progress.radius, progress.anchor.x + progress.radius do
        for z = progress.anchor.z - progress.radius, progress.anchor.z + progress.radius do
            if terrain.inRadius(progress.anchor.x, progress.anchor.z, x, z, progress.radius)
                and not observed[key(x, z)] then
                surfaces[#surfaces + 1] = {
                    x = x, y = progress.baseY, surfaceY = progress.baseY, z = z,
                    class = "unknown", name = "unobserved",
                }
            end
        end
    end
    local result = terrain.plan(surfaces, {
        center = { x = progress.anchor.x, z = progress.anchor.z },
        radius = progress.radius,
        baseY = progress.baseY,
        maxOffset = 3,
        margin = 3,
        chests = { { x = progress.anchor.x, z = progress.anchor.z } },
        access = { progress.anchor.approach },
    })
    local stocks, existingCrops, existingKeys = seedStock(), {}, {}
    for _, surface in ipairs(surfaces) do
        if surface.occupant and surface.occupant.class == "crop" then
            existingCrops[surface.occupant.name] = (existingCrops[surface.occupant.name] or 0) + 1
            existingKeys[key(surface.x, surface.z)] = true
        end
    end
    local activeSeeds = {}
    for seed, crop in pairs(progress.seedProfiles) do
        if (stocks[seed] or 0) > 0 or (existingCrops[crop] or 0) > 0 then
            activeSeeds[#activeSeeds + 1] = seed
        end
    end
    table.sort(activeSeeds)
    local candidates, selected, selectedKeys = {}, {}, {}
    for _, cell in ipairs(result.cells) do candidates[#candidates + 1] = compactCell(cell) end
    table.sort(candidates, function(a, b)
        local da = (a.x - progress.anchor.x) ^ 2 + (a.z - progress.anchor.z) ^ 2
        local db = (b.x - progress.anchor.x) ^ 2 + (b.z - progress.anchor.z) ^ 2
        return da == db and (a.z == b.z and a.x < b.x or a.z < b.z) or da < db
    end)
    local suppliedSeeds, existingCount = 0, 0
    for _, count in pairs(stocks) do suppliedSeeds = suppliedSeeds + count end
    for _ in pairs(existingKeys) do existingCount = existingCount + 1 end
    local desiredCapacity = math.min(#candidates, existingCount + suppliedSeeds)
    for _, cell in ipairs(candidates) do
        if existingKeys[key(cell.x, cell.z)] and not selectedKeys[key(cell.x, cell.z)] then
            selected[#selected + 1] = cell
            selectedKeys[key(cell.x, cell.z)] = true
        end
    end
    for _, cell in ipairs(candidates) do
        if #selected >= desiredCapacity then break end
        if not selectedKeys[key(cell.x, cell.z)] then
            selected[#selected + 1] = cell
            selectedKeys[key(cell.x, cell.z)] = true
        end
    end
    local assigned = #activeSeeds > 0 and terrain.alternatingRows(selected, activeSeeds) or selected
    local selectedTiles = {}
    for _, cell in ipairs(selected) do
        local centerX = math.floor(cell.x / 3) * 3 + 1
        local centerZ = math.floor(cell.z / 3) * 3 + 1
        selectedTiles[key(centerX, centerZ)] = true
    end
    progress.wormCenters = {}
    for _, center in ipairs(result.wormCenters) do
        if selectedTiles[key(center.x, center.z)] then
            progress.wormCenters[#progress.wormCenters + 1] = copy(center)
        end
    end
    progress.waterSources = {}
    for _, surface in ipairs(surfaces) do
        if surface.class == "water" then
            progress.waterSources[#progress.waterSources + 1] = {
                x = surface.x, y = surface.surfaceY, z = surface.z,
            }
        end
    end
    local occupied = 0
    for _, cell in ipairs(assigned) do
        if cell.occupant and cell.occupant.class == "crop" then occupied = occupied + 1 end
    end
    progress.planNames = {}
    progress.plan = {}
    progress.planFormat = 1
    for _, cell in ipairs(assigned) do
        progress.plan[#progress.plan + 1] = encodePlanCell(progress, cell)
    end
    progress.farmFull = desiredCapacity >= #candidates and #candidates > 0
    progress.planSummary = copy(result.summary)
    progress.planSummary.candidates = #candidates
    progress.planSummary.selected = #selected
    progress.planSummary.suppliedSeeds = suppliedSeeds
    progress.planSummary.activeSeeds = #activeSeeds
    progress.planSummary.occupied = occupied
    progress.lastSurveyAt = util.now()
    progress.surfaceColumns = nil
    progress.surfaceNames = nil
    progress.scanTiles = nil
    progress.surveyNavigationReady = nil
    progress.phase = "PREPARE"
    return reportMap(progress, { id = progress.jobId }, {})
end

local function atOffset(progress, cell, offset, job, framework)
    local y = (cell.surfaceY or cell.y) + offset
    return travelCruise(progress, cell.x, y, cell.z, job, framework)
end

local function inspectDown()
    local present, detail = turtle.inspectDown()
    return present, type(detail) == "table" and detail or nil
end

local function beginMutation(progress, job, framework, kind, cell, extra)
    local present, detail = inspectDown()
    progress.pendingMutation = {
        kind = kind, cell = copy(cell), position = nav.getPosition(),
        before = present and copy(detail) or nil,
        extra = copy(extra),
    }
    local continue = checkpoint(job, framework, "Prepared farm mutation: " .. kind)
    if not continue then
        progress.pendingMutation = nil
        state.save()
        return false
    end
    return true
end

local function finishMutation(progress, verified, reason)
    if not verified then return false, reason or "FARM_MUTATION_UNVERIFIED" end
    progress.pendingMutation = nil
    state.save()
    return true
end

local function abandonMutation(progress)
    progress.pendingMutation = nil
    state.save()
end

local function useMiningTool(role)
    if role == "farmingTool" then return inventory.ensureFarmingTool() end
    return inventory.ensureMiningTool()
end

local function clearOccupant(progress, cell, job, framework)
    if not cell.occupant or cell.occupant.class ~= "vegetation" then return true end
    local arrived, travelError = atOffset(progress, cell, 2, job, framework)
    if not arrived then return false, "CLEAR_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    if not present then return true end
    if terrain.classifyBlock(detail) ~= "vegetation" then return false, "CLEAR_TARGET_CHANGED" end
    if not beginMutation(progress, job, framework, "clear_vegetation", cell, {
        expectedBlock = detail.name,
    }) then
        return false, "JOB_CANCELLED"
    end
    local equipped, equipError = useMiningTool("farmingTool")
    if not equipped then
        abandonMutation(progress)
        return false, "NEEDS_TOOL: " .. tostring(equipError)
    end
    local stillPresent, current = inspectDown()
    if not stillPresent or current.name ~= detail.name or terrain.classifyBlock(current) ~= "vegetation" then
        abandonMutation(progress)
        return false, "CLEAR_TARGET_CHANGED"
    end
    if not turtle.digDown() then return false, "CLEAR_VEGETATION_DIG_FAILED" end
    local remains, after = inspectDown()
    return finishMutation(progress, not remains or terrain.classifyBlock(after) ~= "vegetation",
        "CLEAR_VEGETATION_UNVERIFIED")
end

local function replaceSurface(progress, cell, job, framework)
    if cell.action ~= "replace" and cell.action ~= "fill" then return true end
    local dirt = inventory.findItem({ "minecraft:dirt" })
    if not dirt then return false, "SUPPLY_DIRT_MISSING" end
    if cell.action == "fill" then
        for fillY = cell.surfaceY + 1, cell.targetY or cell.surfaceY do
            local fillCell = copy(cell)
            fillCell.surfaceY = fillY
            local arrived, travelError = atOffset(progress, fillCell, 1, job, framework)
            if not arrived then return false, "FILL_UNREACHABLE: " .. tostring(travelError) end
            local present, current = inspectDown()
            if not present then
                if not beginMutation(progress, job, framework, "fill_with_dirt", fillCell) then
                    return false, "JOB_CANCELLED"
                end
                dirt = inventory.findItem({ "minecraft:dirt" })
                if not dirt then return false, "SUPPLY_DIRT_MISSING" end
                local placed = selected(dirt, turtle.placeDown)
                local verified, after = inspectDown()
                if not finishMutation(progress, placed and verified and after.name == "minecraft:dirt",
                    "FILL_WITH_DIRT_UNVERIFIED") then return false, "FILL_WITH_DIRT_UNVERIFIED" end
            elseif current.name ~= "minecraft:dirt" then
                return false, "FILL_TARGET_CHANGED: " .. tostring(current.name)
            end
        end
        return true
    end
    local arrived, travelError = atOffset(progress, cell, 1, job, framework)
    if not arrived then return false, "REPLACE_UNREACHABLE: " .. tostring(travelError) end
    if not beginMutation(progress, job, framework, "replace_with_dirt", cell) then
        return false, "JOB_CANCELLED"
    end
    local present, current = inspectDown()
    if present then
        local currentClass = terrain.classifyBlock(current)
        if cell.action ~= "replace" or (current.name ~= cell.groundName
            and currentClass ~= "sand" and currentClass ~= "stone") then
            return false, "REPLACE_TARGET_CHANGED: " .. tostring(current.name)
        end
        local equipped, equipError = useMiningTool("pickaxe")
        if not equipped then return false, "NEEDS_TOOL: " .. tostring(equipError) end
        if not turtle.digDown() then return false, "REPLACE_DIG_FAILED" end
    end
    local placed = selected(dirt, turtle.placeDown)
    local verified, detail = inspectDown()
    return finishMutation(progress, placed and verified and detail.name == "minecraft:dirt",
        "REPLACE_WITH_DIRT_UNVERIFIED")
end

local function prepareCell(progress, cell, job, framework)
    local cleared, clearError = clearOccupant(progress, cell, job, framework)
    if not cleared then return false, clearError end
    return replaceSurface(progress, cell, job, framework)
end

local function tileCenter(x, z)
    return math.floor(x / 3) * 3 + 1, math.floor(z / 3) * 3 + 1
end

local function irrigationKey(x, z)
    local cx, cz = tileCenter(x, z)
    return key(cx, cz)
end

local function isIrrigated(progress, cell)
    if progress.irrigation[irrigationKey(cell.x, cell.z)] then return true end
    for _, water in ipairs(progress.waterSources or {}) do
        if math.max(math.abs(water.x - cell.x), math.abs(water.z - cell.z)) <= 4 then return true end
    end
    return false
end

local function placeWorm(progress, center, job, framework)
    local slot = inventory.findItemByPredicate(wormDetail)
    if not slot then return false, "WORM_UNAVAILABLE" end
    local cell = { x = center.x, z = center.z, surfaceY = center.y or progress.baseY }
    if center.occupant and center.occupant.class == "vegetation" then
        local clearCell = copy(cell)
        clearCell.occupant = copy(center.occupant)
        local cleared, clearError = clearOccupant(progress, clearCell, job, framework)
        if not cleared then return false, clearError end
    elseif center.occupant then
        return false, "WORM_CENTER_BLOCKED: " .. tostring(center.occupant.name)
    end
    local arrived, travelError = atOffset(progress, cell, 1, job, framework)
    if not arrived then return false, "WORM_UNREACHABLE: " .. tostring(travelError) end
    local before = inventory.countMatching(wormDetail)
    if not beginMutation(progress, job, framework, "place_worm", cell, { beforeCount = before }) then
        return false, "JOB_CANCELLED"
    end
    local placed = selected(slot, turtle.placeDown)
    local after = inventory.countMatching(wormDetail)
    if not finishMutation(progress, placed and after < before, "WORM_PLACEMENT_UNVERIFIED") then
        return false, "WORM_PLACEMENT_UNVERIFIED"
    end
    progress.irrigation[key(center.x, center.z)] = "worm"
    return true
end

local function placeWater(progress, center, job, framework)
    local bucket = inventory.findItem({ "minecraft:water_bucket" })
    if not bucket then return false, "WATER_UNAVAILABLE" end
    local cell = { x = center.x, z = center.z, surfaceY = center.y or progress.baseY }
    local arrived, travelError = atOffset(progress, cell, 1, job, framework)
    if not arrived then return false, "WATER_UNREACHABLE: " .. tostring(travelError) end
    if not beginMutation(progress, job, framework, "place_water", cell) then
        return false, "JOB_CANCELLED"
    end
    local present, detail = inspectDown()
    if present and terrain.classifyBlock(detail) ~= "water" then
        local blockClass = terrain.classifyBlock(detail)
        if blockClass ~= "grass" and blockClass ~= "dirt" and blockClass ~= "farmland" then
            return false, "WATER_TARGET_NOT_APPROVED: " .. tostring(detail.name)
        end
        local equipped, equipError = useMiningTool("pickaxe")
        if not equipped then return false, "NEEDS_TOOL: " .. tostring(equipError) end
        if not turtle.digDown() then return false, "WATER_CELL_DIG_FAILED" end
    end
    local placed = selected(bucket, turtle.placeDown)
    local verified, after = inspectDown()
    if not finishMutation(progress,
        placed and verified and terrain.classifyBlock(after) == "water",
        "WATER_PLACEMENT_UNVERIFIED") then return false, "WATER_PLACEMENT_UNVERIFIED" end
    progress.irrigation[key(center.x, center.z)] = "water"
    progress.waterSources[#progress.waterSources + 1] = {
        x = center.x, y = cell.surfaceY, z = center.z,
    }
    return true
end

local function irrigate(progress, job, framework)
    progress.phase = "IRRIGATE"
    progress.irrigationIndex = progress.irrigationIndex or 1
    while progress.irrigationIndex <= #(progress.wormCenters or {}) do
        local center = progress.wormCenters[progress.irrigationIndex]
        local centerKey = key(center.x, center.z)
        if not progress.irrigation[centerKey] then
            local ok, reason = placeWorm(progress, center, job, framework)
            if not ok and reason == "WORM_UNAVAILABLE" then
                ok, reason = placeWater(progress, center, job, framework)
            end
            if not ok then addAlert(progress, reason) end
        end
        progress.irrigationIndex = progress.irrigationIndex + 1
        local fueled, fuelError = refuelIfNeeded(progress, job, framework)
        if not fueled then return false, fuelError end
        if not checkpoint(job, framework, "Farm irrigation checked") then
            return false, "JOB_CANCELLED"
        end
    end
    progress.irrigationIndex = nil
    return true
end

local function tillCell(progress, cell, job, framework)
    if not isIrrigated(progress, cell) then return false, "CELL_NOT_IRRIGATED" end
    if cell.occupant and cell.occupant.class == "crop" then return true end
    local arrived, travelError = atOffset(progress, cell, 1, job, framework)
    if not arrived then return false, "TILL_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    if present and detail.name == "minecraft:farmland" then return true end
    if not present or not config.farming.tillableNames[detail.name] then
        return false, "TILL_BLOCK_NOT_APPROVED: " .. tostring(detail and detail.name)
    end
    local ready, toolSlotOrError = inventory.prepareFarmingToolItem()
    if not ready then return false, "NEEDS_TOOL: " .. tostring(toolSlotOrError) end
    if not beginMutation(progress, job, framework, "till", cell) then return false, "JOB_CANCELLED" end
    selected(toolSlotOrError, turtle.placeDown)
    local verified, after = inspectDown()
    return finishMutation(progress, verified and after.name == "minecraft:farmland", "TILL_UNVERIFIED")
end

local function plantSeed(progress, cell, seed, job, framework, mutationKind)
    local slot = inventory.findItem({ seed })
    if not slot then return false, "NEEDS_SEEDS: " .. seed end
    local arrived, travelError = atOffset(progress, cell, 2, job, framework)
    if not arrived then return false, "PLANT_UNREACHABLE: " .. tostring(travelError) end
    local present = inspectDown()
    if present then return false, "PLANT_CELL_NOT_EMPTY" end
    local before = inventory.countItem(seed)
    if not beginMutation(progress, job, framework, mutationKind or "plant", cell, {
        seed = seed, expectedCrop = progress.seedProfiles[seed], beforeCount = before,
    }) then return false, "JOB_CANCELLED" end
    local placed = selected(slot, turtle.placeDown)
    local cropPresent, crop = inspectDown()
    local verified = placed and inventory.countItem(seed) < before and cropPresent
        and terrain.classifyBlock(crop) == "crop"
    if verified and progress.seedProfiles[seed] and crop.name ~= progress.seedProfiles[seed] then
        verified = false
    end
    if not verified then return false, "PLANT_UNVERIFIED" end
    progress.seedProfiles[seed] = crop.name
    progress.cropProfiles[crop.name] = seed
    return finishMutation(progress, true)
end

local function learnSeeds(progress, job, framework)
    local stock = seedStock()
    for seed, count in pairs(stock) do
        if count > 0 and not progress.seedProfiles[seed] then
            local learned = false
            for _, encoded in ipairs(progress.plan or {}) do
                local cell = decodePlanCell(progress, encoded)
                if isIrrigated(progress, cell) and not cell.occupant then
                    local ok, reason = plantSeed(progress, cell, seed, job, framework, "learn_seed")
                    if ok then learned = true break end
                    if reason ~= "PLANT_CELL_NOT_EMPTY" then addAlert(progress, "SEED_LEARNING: " .. reason) end
                end
            end
            if not learned then addAlert(progress, "NO_SAFE_TEST_CELL_FOR_SEED: " .. seed) end
        end
    end
    return true
end

local function replaceCrop(progress, cell, seed, currentCrop, job, framework)
    local expected = progress.seedProfiles[seed]
    if not expected or expected == currentCrop then return true end
    local slot = inventory.findItem({ seed })
    if not slot then return false, "NEEDS_SEEDS: " .. seed end
    if not beginMutation(progress, job, framework, "replace_crop", cell, {
        seed = seed, expectedCrop = expected,
    }) then return false, "JOB_CANCELLED" end
    local equipped, equipError = useMiningTool("farmingTool")
    if not equipped then
        abandonMutation(progress)
        return false, "NEEDS_TOOL: " .. tostring(equipError)
    end
    local stillPresent, detail = inspectDown()
    if not stillPresent or detail.name ~= currentCrop or terrain.classifyBlock(detail) ~= "crop" then
        abandonMutation(progress)
        return false, "REPLACE_CROP_TARGET_CHANGED"
    end
    if not turtle.digDown() then return false, "REPLACE_CROP_DIG_FAILED" end
    turtle.suckDown()
    local seedSlot = inventory.findItem({ seed })
    if not seedSlot then return false, "NEEDS_SEEDS_AFTER_CROP_DIG: " .. seed end
    local planted = selected(seedSlot, turtle.placeDown)
    local present, detail = inspectDown()
    return finishMutation(progress, planted and present and detail.name == expected,
        "REPLACE_CROP_UNVERIFIED")
end

local function plantCell(progress, cell, stock, job, framework)
    if not isIrrigated(progress, cell) then return true end
    local seed = cell.cropId
    if cell.occupant and cell.occupant.class == "crop" then
        if not progress.farmFull or not seed
            or progress.seedProfiles[seed] == cell.occupant.name then return true end
        if cell.occupant.name == "supplementaries:flax" then
            return false, "TALL_CROP_REBALANCE_SKIPPED"
        end
    end
    local arrived, travelError = atOffset(progress, cell, 2, job, framework)
    if not arrived then return false, "PLANT_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    if present and terrain.classifyBlock(detail) == "crop" then
        if progress.farmFull and seed and (stock[seed] or 0) > 0 then
            return replaceCrop(progress, cell, seed, detail.name, job, framework)
        end
        return true
    end
    if present then return false, "PLANT_CELL_BLOCKED: " .. tostring(detail and detail.name) end
    if seed and (stock[seed] or 0) < 1 then return true end
    if not seed then
        local names = {}
        for candidate, count in pairs(stock) do if count > 0 then names[#names + 1] = candidate end end
        table.sort(names)
        seed = names[1]
    end
    if not seed then return true end
    local ok, reason = plantSeed(progress, cell, seed, job, framework)
    if ok then stock[seed] = math.max(0, (stock[seed] or 1) - 1) end
    return ok, reason
end

local function collectDrops()
    for _ = 1, 16 do if not turtle.suckDown() then return end end
end

local function harvestTallFlax(progress, cell, job, framework)
    local arrived, travelError = atOffset(progress, cell, 3, job, framework)
    if not arrived then return false, "TALL_FLAX_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    if not present or detail.name ~= "supplementaries:flax" then return true end
    if not detail.state or detail.state.half ~= "upper" then return true end
    local ready, toolSlot = inventory.prepareFarmingToolItem()
    if not ready then return false, "NEEDS_TOOL: " .. tostring(toolSlot) end
    if not beginMutation(progress, job, framework, "interact_harvest", cell, {
        expectedCrop = detail.name,
    }) then return false, "JOB_CANCELLED" end
    local stillPresent, current = inspectDown()
    if not stillPresent or current.name ~= detail.name or not current.state
        or current.state.half ~= "upper" then
        abandonMutation(progress)
        return false, "TALL_FLAX_TARGET_CHANGED"
    end
    selected(toolSlot, turtle.placeDown)
    collectDrops()
    local afterPresent, after = inspectDown()
    return finishMutation(progress, afterPresent and after.name == detail.name,
        "TALL_FLAX_HARVEST_UNVERIFIED")
end

local function harvestCell(progress, cell, job, framework)
    if cell.occupant and cell.occupant.name == "supplementaries:flax" then
        return harvestTallFlax(progress, cell, job, framework)
    end
    local arrived, travelError = atOffset(progress, cell, 2, job, framework)
    if not arrived then return false, "HARVEST_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    if not present or terrain.classifyBlock(detail) ~= "crop" then return true end
    local age = detail.state and tonumber(detail.state.age)
    if not age then return true end
    local growth = progress.cropGrowth[detail.name] or { maxAge = -1, stable = 0 }
    if age > growth.maxAge then
        growth.maxAge, growth.stable = age, 0
    elseif age == growth.maxAge then
        growth.stable = growth.stable + 1
    else
        growth.stable = 0
    end
    progress.cropGrowth[detail.name] = growth
    local mature = age >= config.farming.defaultMatureAge
        or growth.maxAge > 0 and age == growth.maxAge and growth.stable >= 2
    if not mature then return true end
    local seed = progress.cropProfiles[detail.name]
    if not seed or inventory.countItem(seed) < 1 then
        local ready, toolSlot = inventory.prepareFarmingToolItem()
        if not ready then return false, "NEEDS_TOOL: " .. tostring(toolSlot) end
        if not beginMutation(progress, job, framework, "interact_harvest", cell, {
            expectedCrop = detail.name,
        }) then return false, "JOB_CANCELLED" end
        local stillPresent, current = inspectDown()
        local currentAge = stillPresent and current.state and tonumber(current.state.age)
        if not stillPresent or current.name ~= detail.name or currentAge ~= age then
            abandonMutation(progress)
            return false, "HARVEST_TARGET_CHANGED"
        end
        selected(toolSlot, turtle.placeDown)
        collectDrops()
        local afterPresent, after = inspectDown()
        return finishMutation(progress, afterPresent and after.name == detail.name,
            "NONDESTRUCTIVE_HARVEST_UNSUPPORTED")
    end
    if not beginMutation(progress, job, framework, "harvest_replant", cell, {
        seed = seed, expectedCrop = detail.name,
    }) then return false, "JOB_CANCELLED" end
    local equipped, equipError = useMiningTool("farmingTool")
    if not equipped then
        abandonMutation(progress)
        return false, "NEEDS_TOOL: " .. tostring(equipError)
    end
    local stillPresent, current = inspectDown()
    local currentAge = stillPresent and current.state and tonumber(current.state.age)
    if not stillPresent or current.name ~= detail.name or currentAge ~= age then
        abandonMutation(progress)
        return false, "HARVEST_TARGET_CHANGED"
    end
    if not turtle.digDown() then return false, "HARVEST_DIG_FAILED" end
    collectDrops()
    local seedSlot = inventory.findItem({ seed })
    if not seedSlot then return false, "NEEDS_SEEDS_AFTER_HARVEST: " .. seed end
    local planted = selected(seedSlot, turtle.placeDown)
    local cropPresent, crop = inspectDown()
    return finishMutation(progress, planted and cropPresent and crop.name == detail.name,
        "HARVEST_REPLANT_UNVERIFIED")
end

local function reconcileMutation(progress, job, framework)
    local pending = progress.pendingMutation
    if not pending then return true end
    local arrived, travelError = travelCruise(
        progress, pending.position.x, pending.position.y, pending.position.z, job, framework
    )
    if not arrived then return false, "PENDING_MUTATION_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = inspectDown()
    local kind, extra = pending.kind, pending.extra or {}
    if kind == "clear_vegetation" and (not present or terrain.classifyBlock(detail) ~= "vegetation") then
        progress.pendingMutation = nil
    elseif kind == "replace_with_dirt" and present and detail.name == "minecraft:dirt" then
        progress.pendingMutation = nil
    elseif kind == "replace_with_dirt" and not present then
        local slot = inventory.findItem({ "minecraft:dirt" })
        if not slot then return false, "SUPPLY_DIRT_MISSING_DURING_RECOVERY" end
        selected(slot, turtle.placeDown)
        local restored, block = inspectDown()
        if not restored or block.name ~= "minecraft:dirt" then return false, "PENDING_DIRT_REPLACE_UNVERIFIED" end
        progress.pendingMutation = nil
    elseif kind == "fill_with_dirt" and present and detail.name == "minecraft:dirt" then
        progress.pendingMutation = nil
    elseif kind == "fill_with_dirt" and not present then
        local slot = inventory.findItem({ "minecraft:dirt" })
        if not slot then return false, "SUPPLY_DIRT_MISSING_DURING_RECOVERY" end
        selected(slot, turtle.placeDown)
        local restored, block = inspectDown()
        if not restored or block.name ~= "minecraft:dirt" then return false, "PENDING_DIRT_FILL_UNVERIFIED" end
        progress.pendingMutation = nil
    elseif kind == "till" and present and detail.name == "minecraft:farmland" then
        progress.pendingMutation = nil
    elseif kind == "till" and present and config.farming.tillableNames[detail.name] then
        local ready, toolSlot = inventory.prepareFarmingToolItem()
        if not ready then return false, "NEEDS_TOOL_DURING_TILL_RECOVERY" end
        selected(toolSlot, turtle.placeDown)
        local tilled, block = inspectDown()
        if not tilled or block.name ~= "minecraft:farmland" then return false, "PENDING_TILL_UNVERIFIED" end
        progress.pendingMutation = nil
    elseif (kind == "plant" or kind == "learn_seed" or kind == "replace_crop"
        or kind == "harvest_replant") and present and terrain.classifyBlock(detail) == "crop"
        and (not extra.expectedCrop or detail.name == extra.expectedCrop) then
        progress.pendingMutation = nil
    elseif (kind == "plant" or kind == "learn_seed") and not present and extra.seed then
        local slot = inventory.findItem({ extra.seed })
        if not slot then return false, "NEEDS_SEEDS_FOR_PENDING_RECOVERY: " .. extra.seed end
        selected(slot, turtle.placeDown)
        local restored, crop = inspectDown()
        if not restored or terrain.classifyBlock(crop) ~= "crop"
            or extra.expectedCrop and crop.name ~= extra.expectedCrop then
            return false, "PENDING_PLANT_UNVERIFIED"
        end
        progress.pendingMutation = nil
    elseif (kind == "replace_crop" or kind == "harvest_replant") and not present and extra.seed then
        local slot = inventory.findItem({ extra.seed })
        if not slot then return false, "NEEDS_SEEDS_FOR_PENDING_RECOVERY: " .. extra.seed end
        selected(slot, turtle.placeDown)
        local restored, crop = inspectDown()
        if not restored or extra.expectedCrop and crop.name ~= extra.expectedCrop then
            return false, "PENDING_REPLANT_UNVERIFIED"
        end
        progress.pendingMutation = nil
    elseif kind == "place_water" and present and terrain.classifyBlock(detail) == "water" then
        progress.pendingMutation = nil
    elseif kind == "place_water" and not present then
        local slot = inventory.findItem({ "minecraft:water_bucket" })
        if not slot then return false, "NEEDS_WATER_BUCKET_DURING_RECOVERY" end
        selected(slot, turtle.placeDown)
        local restored, block = inspectDown()
        if not restored or terrain.classifyBlock(block) ~= "water" then
            return false, "PENDING_WATER_UNVERIFIED"
        end
        progress.pendingMutation = nil
    elseif kind == "place_worm" and inventory.countMatching(wormDetail) < (extra.beforeCount or math.huge) then
        progress.pendingMutation = nil
    elseif kind == "interact_harvest" and present and detail.name == extra.expectedCrop then
        progress.pendingMutation = nil
    else
        return false, "PENDING_MUTATION_AMBIGUOUS: " .. tostring(kind)
    end
    state.save()
    if not checkpoint(job, framework, "Recovered pending farm mutation") then
        return false, "JOB_CANCELLED"
    end
    return true
end

local function protectedSupplies(progress)
    local protected = {
        ["minecraft:dirt"] = true,
        ["minecraft:water_bucket"] = true,
        ["minecraft:bucket"] = true,
    }
    for _, detail in ipairs(inventory.listItemsDetailed()) do
        if wormDetail(detail) then protected[detail.name] = true end
    end
    for seed in pairs(progress.seedProfiles) do
        protected[seed] = progress.seedReserve
    end
    return protected
end

local function unload(progress, job, framework)
    local arrived, travelError = arriveAnchor(progress, job, framework)
    if not arrived then return false, "OUTPUT_TRAVEL_FAILED: " .. tostring(travelError) end
    return station.unloadAt(progress.anchor, protectedSupplies(progress), {
        shouldContinue = function() return shouldContinue(job, framework) end,
        validateFront = function()
            local anchor = currentFrontAnchor()
            return anchor and anchor.x == progress.anchor.x and anchor.y == progress.anchor.y
                and anchor.z == progress.anchor.z, "ANCHOR_CHEST_CHANGED"
        end,
    })
end

local function runCellPhase(progress, job, framework, phase, callback)
    progress.phase = phase
    progress.cellIndex = progress.cellIndex or 1
    local stock = phase == "PLANT" and seedStock() or nil
    while progress.cellIndex <= #(progress.plan or {}) do
        local cell = decodePlanCell(progress, progress.plan[progress.cellIndex])
        local ok, reason = callback(progress, cell, stock, job, framework)
        if not ok then addAlert(progress, reason) end
        progress.cellIndex = progress.cellIndex + 1
        local fueled, fuelError = refuelIfNeeded(progress, job, framework)
        if not fueled then return false, fuelError end
        if not checkpoint(job, framework, phase .. " farm cell") then return false, "JOB_CANCELLED" end
    end
    progress.cellIndex = nil
    return true
end

local function initialize(progress, job, framework)
    progress.radius = tonumber(job.parameters.radius) or progress.radius
        or config.farming.serviceRadius
    progress.radius = math.max(1, math.min(32, math.floor(progress.radius)))
    if progress.autoExpand == nil then progress.autoExpand = job.parameters.autoExpand ~= false end
    progress.seedReserve = progress.seedReserve or config.farming.seedReserve
    progress.seedProfiles = progress.seedProfiles or {}
    progress.cropProfiles = progress.cropProfiles or {}
    progress.cropGrowth = progress.cropGrowth or {}
    progress.irrigation = progress.irrigation or {}
    progress.alerts = progress.alerts or {}
    progress.jobId = job.id
    if not progress.anchor then
        local anchor, anchorError = findAnchor(job, framework)
        if not anchor then return false, anchorError end
        progress.anchor = anchor
        progress.baseY = anchor.approach.y - 1
    end
    progress.farm = progress.farm or {
        id = job.parameters.farmId or ("farm-service-" .. tostring(os.getComputerID())),
        type = "farm", x = progress.anchor.x, y = progress.baseY, z = progress.anchor.z,
        radius = progress.radius, anchor = copy(progress.anchor), service = true,
        autoExpand = progress.autoExpand,
    }
    if not progress.farmSaved then
        local saved, saveError = map.addNode(progress.farm)
        if not saved then return false, "FARM_SAVE_FAILED: " .. tostring(saveError) end
        progress.farmSaved = true
    end
    return true
end

function service.run(job, framework)
    local progress = job.progress
    local initialized, initializeError = initialize(progress, job, framework)
    if not initialized then return serviceFailure(progress, job, framework, initializeError) end
    local reconciled, reconcileError = reconcileMutation(progress, job, framework)
    if not reconciled then return serviceFailure(progress, job, framework, reconcileError) end
    if not progress.phase or progress.phase == "INITIALIZE" then
        local supplied, supplyError = pollSupplies(progress, job, framework)
        if not supplied then return serviceFailure(progress, job, framework, supplyError) end
        progress.supplySnapshot = copy(actionableStock())
        progress.phase = "SURVEY"
    end

    while shouldContinue(job, framework) do
        if progress.phase ~= "IDLE" and state.get().status ~= "WORKING" then
            state.setStatus("WORKING", "Farm service " .. tostring(progress.phase))
        end
        if progress.phase == "SURVEY" then
            local ok, reason = survey(progress, job, framework)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            local planned, planError = buildPlan(progress)
            if not planned then return serviceFailure(progress, job, framework, planError) end
        elseif progress.phase == "PREPARE" then
            local ok, reason = runCellPhase(progress, job, framework, "PREPARE",
                function(p, cell, _, j, f) return prepareCell(p, cell, j, f) end)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            progress.phase = "IRRIGATE"
        elseif progress.phase == "IRRIGATE" then
            local ok, reason = irrigate(progress, job, framework)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            progress.phase = "TILL"
        elseif progress.phase == "TILL" then
            local ok, reason = runCellPhase(progress, job, framework, "TILL",
                function(p, cell, _, j, f) return tillCell(p, cell, j, f) end)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            progress.phase = "LEARN"
        elseif progress.phase == "LEARN" then
            learnSeeds(progress, job, framework)
            progress.phase = "ALLOCATE"
        elseif progress.phase == "ALLOCATE" then
            -- Rebuild row assignments now that newly supplied seeds have a verified crop profile.
            local stocks, active = seedStock(), {}
            for seed, crop in pairs(progress.seedProfiles) do
                local growing = false
                for _, encoded in ipairs(progress.plan) do
                    local cell = decodePlanCell(progress, encoded)
                    if cell.occupant and cell.occupant.name == crop then growing = true break end
                end
                if growing or (stocks[seed] or 0) > 0 then active[#active + 1] = seed end
            end
            table.sort(active)
            if #active > 0 then assignPlanRows(progress, active) end
            progress.phase = "PLANT"
        elseif progress.phase == "PLANT" then
            local ok, reason = runCellPhase(progress, job, framework, "PLANT", plantCell)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            progress.phase = "HARVEST"
        elseif progress.phase == "HARVEST" then
            local ok, reason = runCellPhase(progress, job, framework, "HARVEST",
                function(p, cell, _, j, f) return harvestCell(p, cell, j, f) end)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            progress.phase = "UNLOAD"
        elseif progress.phase == "UNLOAD" then
            local ok, reason = unload(progress, job, framework)
            if not ok then return serviceFailure(progress, job, framework, reason) end
            reportMap(progress, job, {})
            progress.nextHarvestAt = util.now() + HARVEST_INTERVAL_MS
            progress.phase = "IDLE"
        elseif progress.phase == "IDLE" then
            state.setStatus("WAITING_CHEST", "Farm service is waiting for supplies or growth")
            local supplied, supplyError = pollSupplies(progress, job, framework)
            if not supplied then addAlert(progress, supplyError) end
            local currentStock = actionableStock()
            local newSupply = stockIncreased(progress.supplySnapshot, currentStock)
            progress.supplySnapshot = copy(currentStock)
            for _ = 1, config.farming.serviceIdleSeconds do
                sleep(1)
                if not checkpoint(job, framework, "Farm service idle at chest") then
                    return serviceFailure(progress, job, framework, "JOB_CANCELLED")
                end
            end
            local now = util.now()
            local periodicSurvey = progress.autoExpand
                and now - (progress.lastSurveyAt or 0) >= SURVEY_INTERVAL_MS
            if progress.forceSurvey or progress.autoExpand and newSupply or periodicSurvey then
                progress.cycle = (progress.cycle or 0) + 1
                progress.surveyComplete = false
                progress.surfaceColumns = nil
                progress.surfaceNames = nil
                progress.surveyNavigationReady = nil
                progress.plan = nil
                progress.planNames = nil
                progress.wormCenters = nil
                progress.forceSurvey = nil
                progress.phase = "SURVEY"
            elseif newSupply then
                progress.phase = "PREPARE"
            elseif now >= (progress.nextHarvestAt or 0) then
                progress.cycle = (progress.cycle or 0) + 1
                progress.phase = "HARVEST"
            end
        else
            return false, "UNKNOWN_FARM_SERVICE_PHASE: " .. tostring(progress.phase)
        end
    end
    return serviceFailure(progress, job, framework, "JOB_CANCELLED")
end

return service
