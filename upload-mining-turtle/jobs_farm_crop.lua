local config = require("config")
local config = require("config")
local inventory = require("lib.inventory")
local map = require("lib.map")
local nav = require("lib.nav")
local scanner = require("lib.scanner")
local station = require("lib.station")
local state = require("lib.state")
local util = require("lib.util")

local farmCrop = {}

local function distance(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

local function rightVector(direction)
    if direction == "north" then return { x = 1, z = 0 } end
    if direction == "east" then return { x = 0, z = 1 } end
    if direction == "south" then return { x = -1, z = 0 } end
    return { x = 0, z = -1 }
end

local function cellsFor(farm)
    local forward = nav.directionVector(farm.direction)
    local right = rightVector(farm.direction)
    if not forward then return nil, "INVALID_FARM_DIRECTION" end
    local cells = {}
    for row = 0, farm.length - 1 do
        if row % 2 == 0 then
            for column = 0, farm.width - 1 do
                table.insert(cells, {
                    x = farm.x + forward.x * row + right.x * column,
                    y = farm.y,
                    z = farm.z + forward.z * row + right.z * column,
                })
            end
        else
            for column = farm.width - 1, 0, -1 do
                table.insert(cells, {
                    x = farm.x + forward.x * row + right.x * column,
                    y = farm.y,
                    z = farm.z + forward.z * row + right.z * column,
                })
            end
        end
    end
    return cells
end

local function plant(seed, crop)
    local slot = inventory.selectItem(seed)
    if not slot then return false, "NEEDS_SEEDS: " .. seed end
    local previous = turtle.getSelectedSlot()
    turtle.select(slot)
    local planted, plantError = turtle.placeDown()
    turtle.select(previous)
    local present, detail = turtle.inspectDown()
    if present and type(detail) == "table" and detail.name == crop then
        if crop ~= "supplementaries:flax"
            or detail.state and detail.state.half == "lower" then return true end
        return false, "REPLANT_WRONG_FLAX_HALF"
    end
    if not planted then return false, "REPLANT_FAILED: " .. tostring(plantError) end
    return false, "REPLANT_UNVERIFIED"
end

local function seedProtection(farm, reserve)
    if farm.seed then return { [farm.seed] = reserve } end
    return {}
end

local function collectDropsBelow()
    for _ = 1, 16 do
        if not turtle.suckDown() then return true end
    end
    return false, "DROP_COLLECTION_LIMIT_EXCEEDED"
end

local function farmingToolSlot()
    return inventory.findItem(config.equipment.farmingTool)
end

local function digCropDown()
    local toolWasEquipped, originalToolSide = inventory.isEquipped("farmingTool")
    local modemWasEquipped, originalModemSide = inventory.isEquipped("modem")
    local equipped, equipError = inventory.ensureFarmingTool()
    if not equipped then return false, equipError end
    local toolEquipped, toolSide = inventory.isEquipped("farmingTool")
    if not toolEquipped then return false, toolSide or "FARMING_TOOL_NOT_EQUIPPED" end
    local dug, digError = turtle.digDown()
    if not toolWasEquipped then
        if modemWasEquipped and originalModemSide ~= toolSide then
            local removed, removeError = inventory.unequip("farmingTool")
            if not removed then return false, "TOOL_RESTORE_FAILED_AFTER_DIG: " .. tostring(removeError) end
        else
            local modemOk, modemError = inventory.ensureModem(originalModemSide or toolSide)
            if not modemOk then
                return false, "MODEM_RESTORE_FAILED_AFTER_DIG: " .. tostring(modemError)
            end
        end
    elseif originalToolSide ~= toolSide then
        local restored, restoreError = inventory.equipOnSide("farmingTool", originalToolSide)
        if not restored then return false, "TOOL_RESTORE_FAILED_AFTER_DIG: " .. tostring(restoreError) end
    end
    return dug, digError
end

local function ensurePlantingSoilBelow()
    local present, detail = turtle.inspectDown()
    if present and type(detail) == "table" and config.farming.farmlandNames[detail.name] then
        return false, "PLANTING_GEOMETRY_INVALID: crop cell is not empty"
    end
    if present then return false, "PLANTING_GEOMETRY_INVALID: unexpected block below" end
    local toolWasEquipped, originalToolSide = inventory.isEquipped("farmingTool")
    local previous = turtle.getSelectedSlot()
    local toolSlot = inventory.findItem(config.equipment.farmingTool)
    if not toolSlot then
        for slot = 1, 16 do
            local item = turtle.getItemDetail(slot)
            if item and item.name:lower():match("hoe$") then toolSlot = slot break end
        end
    end
    local temporaryToolSide
    if not toolSlot and toolWasEquipped then
        toolSlot, temporaryToolSide = inventory.unequip("farmingTool")
        if not toolSlot then return false, "TILL_FAILED: hoe could not be moved into inventory" end
    end
    local tilled, tillError
    if toolSlot then
        turtle.select(toolSlot)
        tilled, tillError = turtle.placeDown()
        turtle.select(previous)
    else
        tillError = "No hoe item available"
    end
    if temporaryToolSide then
        local restored, restoreError = inventory.equip("farmingTool", temporaryToolSide)
        if not restored then return false, "HOE_RESTORE_FAILED_AFTER_TILL: " .. tostring(restoreError) end
    elseif originalToolSide then
        local restored, restoreError = inventory.equipOnSide("farmingTool", originalToolSide)
        if not restored then return false, "HOE_RESTORE_FAILED_AFTER_TILL: " .. tostring(restoreError) end
    end
    if not toolSlot then return false, "TILL_FAILED: " .. tostring(tillError) end
    -- Farmland returns false to another hoe use, while some mod hooks return
    -- false after changing the soil. The following plant postcondition is authoritative.
    return true
end

local function cropTravelOptions(targetY, shouldContinue)
    local routeOrder = targetY > nav.getPosition().y
        and { "y", "x", "z" } or { "x", "z", "y" }
    return { shouldContinue = shouldContinue, routeOrder = routeOrder }
end

local function interactHarvest(farm, job, framework, cell, detecting)
    local present, before = turtle.inspectDown()
    if not present or before.name ~= farm.crop then return false, "CROP_NOT_PRESENT" end
    local beforeAge = before.state and tonumber(before.state.age)
    if not beforeAge then return false, "CROP_AGE_UNAVAILABLE" end

    if inventory.freeSlots() < config.farming.harvestDropSlots + 1 then
        return false, "NEEDS_INVENTORY_SPACE"
    end
    local toolSlot = farmingToolSlot()
    if not toolSlot then return false, "INTERACTION_TOOL_UNAVAILABLE" end
    job.progress.pendingInteraction = {
        x = cell.x,
        y = cell.y,
        z = cell.z,
        beforeAge = beforeAge,
        cell = detecting and nil or job.progress.cell,
        detecting = detecting == true,
    }
    if not framework.checkpoint(job, "Prepared crop interaction") then
        return false, "JOB_CANCELLED"
    end
    local previous = turtle.getSelectedSlot()
    turtle.select(toolSlot)
    local interacted, interactionError = turtle.placeDown()
    turtle.select(previous)
    local collected, collectionError = collectDropsBelow()

    local remains, after = turtle.inspectDown()
    local afterAge = remains and after.name == farm.crop and after.state and tonumber(after.state.age)
    if afterAge and afterAge < beforeAge and not collected then return false, collectionError end
    if interacted and afterAge and afterAge < beforeAge then return true end
    if afterAge and afterAge < beforeAge then
        return false, "CROP_RESET_WITH_FAILED_INTERACTION_RESULT: " .. tostring(interactionError)
    end
    job.progress.pendingInteraction = nil
    return false, "CROP_DID_NOT_RESET_AFTER_INTERACTION"
end

local function recoverPendingInteraction(farm, job, framework)
    local pending = job.progress.pendingInteraction
    if not pending then return true end
    if type(pending.x) ~= "number" or type(pending.y) ~= "number"
        or type(pending.z) ~= "number" or type(pending.beforeAge) ~= "number"
        or pending.cell ~= nil and type(pending.cell) ~= "number" then
        return false, "INVALID_PENDING_INTERACTION"
    end
    if pending.toolSide then
        local restored, restoreError = inventory.equipOnSide("farmingTool", pending.toolSide)
        if not restored then return false, "INTERACTION_TOOL_RESTORE_FAILED: " .. tostring(restoreError) end
        local modemOk, modemError
        if pending.modemSide then
            modemOk, modemError = inventory.equipOnSide("modem", pending.modemSide)
            if not modemOk then return false, "NEEDS_MODEM: " .. tostring(modemError) end
        end
    end
    local arrived, travelError = nav.gotoXYZ(pending.x, pending.y, pending.z, cropTravelOptions(
        pending.y, function() return not framework.isCancellationRequested(job) end
    ))
    if not arrived then return false, "PENDING_INTERACTION_UNREACHABLE: " .. tostring(travelError) end
    local collected, collectionError = collectDropsBelow()
    if not collected then return false, collectionError end
    local present, detail = turtle.inspectDown()
    local age = present and type(detail) == "table" and detail.name == farm.crop
        and detail.state and tonumber(detail.state.age)
    if not age or age >= pending.beforeAge then
        return false, "PENDING_INTERACTION_AMBIGUOUS"
    end
    farm.harvestMode = "interact"
    job.progress.harvested = job.progress.harvested + 1
    if pending.cell then job.progress.cell = math.max(job.progress.cell, pending.cell + 1) end
    job.progress.pendingInteraction = nil
    local saved, saveError = map.addNode(farm)
    if not saved then return false, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
    if not framework.checkpoint(job, "Recovered completed crop interaction") then
        return false, "JOB_CANCELLED"
    end
    return true
end

local function restorePendingEquipment(pending)
    if not pending.toolSide then return true end
    local restored, restoreError = inventory.equipOnSide("farmingTool", pending.toolSide)
    if not restored then return false, "INTERACTION_TOOL_RESTORE_FAILED: " .. tostring(restoreError) end
    if pending.modemSide then
        local modemOk, modemError = inventory.equipOnSide("modem", pending.modemSide)
        if not modemOk then return false, "NEEDS_MODEM: " .. tostring(modemError) end
    else
        local modemSide = pending.toolSide == "left" and "right" or "left"
        local modemOk, modemError = inventory.ensureModem(modemSide)
        if not modemOk then return false, "NEEDS_MODEM: " .. tostring(modemError) end
    end
    return true
end

local function finishTallFlax(farm, pending)
    -- Once harvesting starts, complete the descend/replant/ascend transaction
    -- before honoring cancellation so the farmland is never left empty.
    local descended, descendError = nav.down()
    if not descended then return false, "TALL_FLAX_DESCENT_FAILED: " .. tostring(descendError) end
    local function returnToWorkPlane()
        local returned, returnError = nav.up()
        if not returned then return false, "TALL_FLAX_ASCENT_FAILED: " .. tostring(returnError) end
        return true
    end
    local function failAfterReturn(reason)
        local returned, returnError = returnToWorkPlane()
        if not returned then return false, returnError .. "; original error: " .. tostring(reason) end
        return false, reason
    end
    local function collectAtGroundLevel()
        local groundCollected, groundError = collectDropsBelow()
        if not groundCollected then return false, groundError, true end
        return true, nil, true
    end

    local collected, collectionError = collectDropsBelow()
    if not collected then return failAfterReturn(collectionError) end
    local present, detail = turtle.inspectDown()
    if present and type(detail) == "table" and detail.name == farm.crop then
        local age = detail.state and tonumber(detail.state.age)
        if not age or age >= pending.beforeAge then
            if inventory.freeSlots() < config.farming.harvestDropSlots then
                return failAfterReturn("NEEDS_INVENTORY_SPACE")
            end
            local dug, digError = digCropDown()
            if not dug then
                return failAfterReturn("TALL_FLAX_LOWER_HARVEST_FAILED: " .. tostring(digError))
            end
            collected, collectionError = collectDropsBelow()
            if not collected then return failAfterReturn(collectionError) end
            present = false
        end
    elseif present then
        return failAfterReturn(
            "UNEXPECTED_TALL_FLAX_LOWER_BLOCK: " .. tostring(type(detail) == "table" and detail.name or detail)
        )
    end

    if not present then
        local atUpperLevel
        collected, collectionError, atUpperLevel = collectAtGroundLevel()
        if not collected then
            if not atUpperLevel then return false, collectionError end
            return failAfterReturn(collectionError)
        end
        local soilReady, soilError = ensurePlantingSoilBelow()
        if not soilReady then return failAfterReturn(soilError) end
        if not farm.seed or inventory.countItem(farm.seed) < 1 then
            local returned, returnError = returnToWorkPlane()
            if not returned then return false, returnError end
            return true, "REPLANT_DEFERRED"
        end
        local planted, plantError = plant(farm.seed, farm.crop)
        if not planted then return failAfterReturn(plantError) end
    end
    return returnToWorkPlane()
end

local function queueTallReplant(job, cell)
    job.progress.pendingReplants = job.progress.pendingReplants or {}
    for _, pending in ipairs(job.progress.pendingReplants) do
        if pending.x == cell.x and pending.y == cell.y and pending.z == cell.z then return end
    end
    table.insert(job.progress.pendingReplants, { x = cell.x, y = cell.y, z = cell.z })
end

local function repairPendingTallReplants(farm, job, framework)
    local queue = job.progress.pendingReplants or {}
    while #queue > 0 and farm.seed and inventory.countItem(farm.seed) > 0 do
        local cell = queue[1]
        local arrived, travelError = nav.gotoXYZ(cell.x, cell.y, cell.z, cropTravelOptions(
            cell.y, function() return not framework.isCancellationRequested(job) end
        ))
        if not arrived then return false, "PENDING_REPLANT_UNREACHABLE: " .. tostring(travelError) end
        local descended, descendError = nav.down()
        if not descended then return false, "PENDING_REPLANT_DESCENT_FAILED: " .. tostring(descendError) end
        local present, detail = turtle.inspectDown()
        if not present then
            local soilReady, soilError = ensurePlantingSoilBelow()
            if not soilReady then return false, soilError end
            local planted, plantError = plant(farm.seed, farm.crop)
            if not planted then
                local returned, returnError = nav.up()
                if not returned then return false, "PENDING_REPLANT_ASCENT_FAILED: " .. tostring(returnError) end
                return false, plantError
            end
        elseif type(detail) ~= "table" or detail.name ~= farm.crop then
            nav.up()
            return false, "PENDING_REPLANT_BLOCKED: " .. tostring(type(detail) == "table" and detail.name or detail)
        end
        local returned, returnError = nav.up()
        if not returned then return false, "PENDING_REPLANT_ASCENT_FAILED: " .. tostring(returnError) end
        table.remove(queue, 1)
        job.progress.replanted = job.progress.replanted + 1
        if not framework.checkpoint(job, "Repaired deferred tall flax replant") then
            return false, "JOB_CANCELLED"
        end
    end
    job.progress.pendingReplants = queue
    return true
end

local function harvestTallFlax(farm, job, framework, cell)
    local present, before = turtle.inspectDown()
    local beforeAge = present and type(before) == "table" and before.name == farm.crop
        and before.state and tonumber(before.state.age)
    if not beforeAge or before.state.half ~= "upper" then
        return false, "TALL_FLAX_UPPER_NOT_PRESENT"
    end
    if inventory.freeSlots() < config.farming.harvestDropSlots + 1 then
        return false, "NEEDS_INVENTORY_SPACE"
    end
    local toolSlot = farmingToolSlot()
    if not toolSlot then return false, "INTERACTION_TOOL_UNAVAILABLE" end
    job.progress.pendingTallFlax = {
        x = cell.x,
        y = cell.y,
        z = cell.z,
        cell = job.progress.cell,
        beforeAge = beforeAge,
    }
    if not framework.checkpoint(job, "Prepared tall flax harvest") then
        return false, "JOB_CANCELLED"
    end

    local previous = turtle.getSelectedSlot()
    turtle.select(toolSlot)
    turtle.placeDown()
    turtle.select(previous)
    local collected, collectionError = collectDropsBelow()
    if not collected then return false, collectionError end

    local upperPresent, upper = turtle.inspectDown()
    if upperPresent and type(upper) == "table" and upper.name == farm.crop then
        job.progress.pendingTallFlax = nil
        return false, "TALL_FLAX_INTERACTION_DID_NOT_HARVEST"
    end
    if upperPresent then
        return false, "UNEXPECTED_TALL_FLAX_UPPER_BLOCK: " .. tostring(type(upper) == "table" and upper.name or upper)
    end
    return finishTallFlax(farm, job.progress.pendingTallFlax)
end

local function recoverPendingTallFlax(farm, job, framework)
    local pending = job.progress.pendingTallFlax
    if not pending then return true end
    if type(pending.x) ~= "number" or type(pending.y) ~= "number"
        or type(pending.z) ~= "number" or type(pending.cell) ~= "number"
        or type(pending.beforeAge) ~= "number" then
        return false, "INVALID_PENDING_TALL_FLAX"
    end
    local equipmentOk, equipmentError = restorePendingEquipment(pending)
    if not equipmentOk then return false, equipmentError end
    local arrived, travelError = nav.gotoXYZ(pending.x, pending.y, pending.z, cropTravelOptions(
        pending.y, function() return not framework.isCancellationRequested(job) end
    ))
    if not arrived then return false, "PENDING_TALL_FLAX_UNREACHABLE: " .. tostring(travelError) end
    local collected, collectionError = collectDropsBelow()
    if not collected then return false, collectionError end
    local present, detail = turtle.inspectDown()
    if present and type(detail) == "table" and detail.name == farm.crop then
        local age = detail.state and tonumber(detail.state.age)
        if age and age >= pending.beforeAge then
            job.progress.pendingTallFlax = nil
            if not framework.checkpoint(job, "Recovered unstarted tall flax harvest") then
                return false, "JOB_CANCELLED"
            end
            return true
        end
        if age and age < pending.beforeAge and detail.state.half == "upper" then
            job.progress.harvested = job.progress.harvested + 1
            job.progress.replanted = job.progress.replanted + 1
        else
            return false, "PENDING_TALL_FLAX_AMBIGUOUS"
        end
    elseif not present then
        local finished, finishError = finishTallFlax(farm, pending)
        if not finished then return false, finishError end
        job.progress.harvested = job.progress.harvested + 1
        if finishError == "REPLANT_DEFERRED" then
            queueTallReplant(job, pending)
        else
            job.progress.replanted = job.progress.replanted + 1
        end
    else
        return false, "PENDING_TALL_FLAX_AMBIGUOUS"
    end
    job.progress.cell = math.max(job.progress.cell, pending.cell + 1)
    job.progress.pendingTallFlax = nil
    if not framework.checkpoint(job, "Recovered tall flax harvest") then return false, "JOB_CANCELLED" end
    return true
end

local function recoverPendingDig(farm, job, framework)
    local pending = job.progress.pendingDig
    if not pending then return true end
    if type(pending.x) ~= "number" or type(pending.y) ~= "number"
        or type(pending.z) ~= "number" or type(pending.cell) ~= "number"
        or type(pending.beforeAge) ~= "number" or type(job.progress.cell) ~= "number" then
        return false, "INVALID_PENDING_DIG"
    end
    local toolReady, toolError = inventory.prepareFarmingToolItem()
    if not toolReady then return false, "NEEDS_TOOL: " .. tostring(toolError) end
    local arrived, travelError = nav.gotoXYZ(pending.x, pending.y, pending.z, cropTravelOptions(
        pending.y, function() return not framework.isCancellationRequested(job) end
    ))
    if not arrived then return false, "PENDING_DIG_UNREACHABLE: " .. tostring(travelError) end
    local present, detail = turtle.inspectDown()
    if present and type(detail) == "table" and detail.name == farm.crop then
        local age = detail.state and tonumber(detail.state.age)
        if not pending.harvested and age and age >= pending.beforeAge then
            job.progress.pendingDig = nil
            if not framework.checkpoint(job, "Recovered unstarted crop dig") then
                return false, "JOB_CANCELLED"
            end
            return true
        end
        if not pending.harvested then return false, "PENDING_DIG_AMBIGUOUS" end
        if not pending.planted then job.progress.replanted = job.progress.replanted + 1 end
    elseif not present or type(detail) == "table" and config.farming.farmlandNames[detail.name] then
        if not pending.harvested then job.progress.harvested = job.progress.harvested + 1 end
        pending.harvested = true
        state.save()
        if not farm.seed or inventory.countItem(farm.seed) < 1 then
            return false, "NEEDS_SEEDS: crop was dug before reboot and must be replanted"
        end
        local planted, plantError = plant(farm.seed, farm.crop)
        if not planted then return false, plantError end
        job.progress.replanted = job.progress.replanted + 1
    else
        return false, "PENDING_DIG_AMBIGUOUS: " .. tostring(type(detail) == "table" and detail.name or detail)
    end
    job.progress.cell = math.max(job.progress.cell, pending.cell + 1)
    job.progress.pendingDig = nil
    if not framework.checkpoint(job, "Recovered dig-and-replant transaction") then
        return false, "JOB_CANCELLED"
    end
    return true
end

local function detectHarvestMode(farm, cells, job, framework)
    local matureAge = farm.matureAge or config.farming.defaultMatureAge
    for _, cell in ipairs(cells) do
        local arrived, travelError = nav.gotoXYZ(cell.x, cell.y, cell.z, cropTravelOptions(
            cell.y, function() return not framework.isCancellationRequested(job) end
        ))
        if not arrived then return nil, "FARM_CELL_UNREACHABLE: " .. tostring(travelError) end
        local present, detail = turtle.inspectDown()
        local age = present and detail.name == farm.crop and detail.state and tonumber(detail.state.age)
        if age and age >= matureAge then
            local interacted, interactionError = interactHarvest(farm, job, framework, cell, true)
            if interacted then
                farm.harvestMode = "interact"
                job.progress.harvested = job.progress.harvested + 1
                job.progress.pendingInteraction = nil
            else
                if interactionError == "NEEDS_INVENTORY_SPACE"
                    or interactionError:find("CROP_RESET_WITH_FAILED", 1, true)
                    or interactionError:find("DROP_COLLECTION_", 1, true) then
                    return nil, interactionError
                end
                farm.harvestMode = "dig_replant"
            end
            local saved, saveError = map.addNode(farm)
            if not saved then return nil, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
            job.progress.discoveredFarm = farm
            if not framework.checkpoint(job, "Detected farm harvest mode: " .. farm.harvestMode) then
                return nil, "JOB_CANCELLED"
            end
            return farm.harvestMode
        end
    end
    return nil, "NEEDS_FARM_MATURITY_CONFIGURATION: no mature flax matched the configured age"
end

local function detectSeedName(cropName)
    local candidate = inventory.findItemNameContaining("flax", "seed")
    if candidate and candidate:find("seed", 1, true) then return candidate end
    if cropName == "actuallyadditions:flax" and inventory.countItem(cropName) > 0 then return cropName end
    if cropName == "supplementaries:flax" then return "supplementaries:flax_seeds" end
    return nil
end

local function largestConnectedCrop(groups)
    local selected, selectedCount
    for _, group in pairs(groups) do
        local remaining = {}
        for key, crop in pairs(group.positions) do remaining[key] = crop end
        while next(remaining) do
            local startKey, start = next(remaining)
            remaining[startKey] = nil
            local queue = { start }
            local component = {}
            local index = 1
            while index <= #queue do
                local crop = queue[index]
                index = index + 1
                component[("%d:%d"):format(crop.x, crop.z)] = crop
                for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local key = ("%d:%d"):format(crop.x + offset[1], crop.z + offset[2])
                    if remaining[key] then
                        table.insert(queue, remaining[key])
                        remaining[key] = nil
                    end
                end
            end
            if not selectedCount or #queue > selectedCount
                or #queue == selectedCount and group.y > selected.y then
                selectedCount = #queue
                selected = { name = group.name, y = group.y, positions = component }
            end
        end
    end
    return selected, selectedCount
end

local function discoverFarm(job, framework)
    local result, scanError = scanner.scan(job.parameters.scanRadius or config.scanner.maxRadius)
    local modemOk, modemError = inventory.ensureModem()
    if not modemOk then return nil, "NEEDS_MODEM: " .. tostring(modemError) end
    if not result then return nil, scanError end

    local groups = {}
    for _, crop in ipairs(result.farmCandidates or {}) do
        local key = crop.name .. ":" .. tostring(crop.y)
        local group = groups[key] or { name = crop.name, y = crop.y, positions = {} }
        group.positions[("%d:%d"):format(crop.x, crop.z)] = crop
        groups[key] = group
    end
    local selected, selectedCount = largestConnectedCrop(groups)
    if not selected then return nil, "NEEDS_FARM: Geo Scanner found no flax within range" end

    local minX, maxX, minZ, maxZ
    for _, crop in pairs(selected.positions) do
        minX, maxX = math.min(minX or crop.x, crop.x), math.max(maxX or crop.x, crop.x)
        minZ, maxZ = math.min(minZ or crop.z, crop.z), math.max(maxZ or crop.z, crop.z)
    end
    local xSize, zSize = maxX - minX + 1, maxZ - minZ + 1
    local density = selectedCount / (xSize * zSize)
    if density < config.farming.minimumDiscoveryDensity then
        return nil, ("NEEDS_FARM_CONFIGURATION: flax area is irregular (density %.2f)"):format(density)
    end

    local farm = {
        id = job.parameters.farmId or "auto-flax",
        type = "farm",
        x = minX,
        y = selected.y + 1,
        z = minZ,
        width = zSize,
        length = xSize,
        direction = "east",
        crop = selected.name,
        seed = job.parameters.seed or detectSeedName(selected.name),
        matureAge = tonumber(job.parameters.matureAge) or config.farming.defaultMatureAge,
        discoveredAt = os.epoch("utc"),
    }
    for _, crop in pairs(selected.positions) do
        if crop.state and crop.state.half == "upper" then
            farm.cropHeight = 2
            break
        end
    end
    local bestOutput, bestDistance
    for _, chest in ipairs(result.chests or {}) do
        for _, approach in ipairs(chest.approaches or {}) do
            local insideFarm = approach.x >= minX and approach.x <= maxX
                and approach.z >= minZ and approach.z <= maxZ
            local candidateDistance = distance(farm, approach)
            if not insideFarm and (not bestDistance or candidateDistance < bestDistance) then
                bestDistance = candidateDistance
                bestOutput = {
                    name = chest.name,
                    x = chest.x, y = chest.y, z = chest.z,
                    approach = { x = approach.x, y = approach.y, z = approach.z },
                    direction = approach.direction,
                }
            end
        end
    end
    if not bestOutput then return nil, "NEEDS_OUTPUT: Geo Scanner found no nearby chest" end
    farm.output = bestOutput

    local saved, saveError = map.addNode(farm)
    if not saved then return nil, "FARM_SAVE_FAILED: " .. tostring(saveError) end
    job.progress.discoveredFarm = farm
    if not framework.checkpoint(job, "Discovered flax farm and output chest") then return nil, "JOB_CANCELLED" end
    return farm
end

function farmCrop.run(job, framework)
    local farm = job.parameters.farm or map.getFarm(job.parameters.farmId)
    if not farm then
        local discoveryError
        farm, discoveryError = discoverFarm(job, framework)
        if not farm then return false, discoveryError end
    end
    if job.parameters.matureAge or job.parameters.seed then
        farm = util.copy(farm)
        farm.matureAge = tonumber(job.parameters.matureAge) or farm.matureAge
        farm.seed = job.parameters.seed or farm.seed
        local saved, saveError = map.addNode(farm)
        if not saved then return false, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
    end
    local serviceStation = farm.station or farm.stationId
    local cells, cellsError = cellsFor(farm)
    if not cells then return false, cellsError end
    job.progress.cell = job.progress.cell or 1
    job.progress.harvested = job.progress.harvested or 0
    job.progress.replanted = job.progress.replanted or 0
    job.progress.skipped = job.progress.skipped or 0

    local seedReserve = farm.seedReserve or config.farming.seedReserve
    if serviceStation then
        local stationData, stationError = station.validate(serviceStation)
        if not stationData then return false, stationError end
        local currentFuel = turtle.getFuelLevel()
        local approachDistance = distance(nav.getPosition(), stationData)
        if currentFuel ~= "unlimited" and (type(currentFuel) ~= "number" or currentFuel < approachDistance) then
            return false, "NEEDS_FUEL_AT_CURRENT_POSITION"
        end
        local stationDistance = distance(stationData, farm)
        local fueled, fuelError = station.refuel(
            serviceStation,
            #cells * 2 + stationDistance * 3 + config.inventory.jobFuelReserve,
            { shouldContinue = function() return not framework.isCancellationRequested(job) end }
        )
        if not fueled then return false, "NEEDS_FUEL: " .. tostring(fuelError) end
    else
        local home = state.get().home
        local homePosition = home and home.position or nav.getPosition()
        local current = nav.getPosition()
        local requiredFuel = distance(current, farm.output.approach)
            + distance(farm.output.approach, farm)
            + #cells * 2
            + distance(farm, farm.output.approach)
            + distance(farm.output.approach, homePosition)
            + config.inventory.jobFuelReserve
        local fueled = inventory.refuelTo(requiredFuel)
        if not fueled then return false, "NEEDS_FUEL: no registered fuel chest and onboard fuel is insufficient" end
    end
    local toolOk, toolError = inventory.prepareFarmingToolItem()
    if not toolOk then
        if serviceStation then
            for _, toolName in ipairs(config.equipment.farmingTool) do
                station.pull(serviceStation, toolName, 1)
                toolOk, toolError = inventory.prepareFarmingToolItem()
                if toolOk then break end
            end
        end
    end
    if not toolOk then return false, "NEEDS_TOOL: " .. tostring(toolError) end
    local protectedSeeds = seedProtection(farm, seedReserve)
    local minimumOutputSlots = math.max(
        config.farming.outputReserveSlots,
        inventory.maximumOutputSlots(protectedSeeds)
    )
    if serviceStation then
        local outputReady, outputError = station.verifyOutput(
            serviceStation,
            protectedSeeds,
            { shouldContinue = function() return not framework.isCancellationRequested(job) end },
            minimumOutputSlots
        )
        if not outputReady then return false, outputError end
    else
        local outputReady, outputError = station.verifyOutputAt(
            farm.output,
            protectedSeeds,
            { shouldContinue = function() return not framework.isCancellationRequested(job) end },
            minimumOutputSlots
        )
        if outputError == "JOB_CANCELLED" then return false, outputError end
        if not outputReady then
            local home = state.get().home
            if home then
                local _, recoveryError = nav.gotoXYZ(home.position.x, home.position.y, home.position.z, {
                    shouldContinue = function() return not framework.isCancellationRequested(job) end,
                })
                if recoveryError == "JOB_CANCELLED" then return false, recoveryError end
            end
            return false, outputError
        end
    end
    local atFarm, farmError, blockingFarmBlock = nav.gotoXYZ(
        farm.x, farm.y, farm.z,
        cropTravelOptions(farm.y, function() return not framework.isCancellationRequested(job) end)
    )
    if not atFarm and farmError == "BLOCK" and blockingFarmBlock
        and blockingFarmBlock.name == farm.crop then
        farm.y = farm.y + 1
        farm.cropHeight = math.max(2, farm.cropHeight or 1)
        cells, cellsError = cellsFor(farm)
        if not cells then return false, cellsError end
        local saved, saveError = map.addNode(farm)
        if not saved then return false, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
        job.progress.discoveredFarm = farm
        if not framework.checkpoint(job, "Raised farm path above a tall crop") then
            return false, "JOB_CANCELLED"
        end
        atFarm, farmError, blockingFarmBlock = nav.gotoXYZ(
            farm.x, farm.y, farm.z,
            cropTravelOptions(farm.y, function() return not framework.isCancellationRequested(job) end)
        )
    end
    if farmError == "JOB_CANCELLED" then return false, farmError end
    if not atFarm then
        return false, "FARM_ROUTE_UNAVAILABLE: " .. tostring(farmError)
            .. (blockingFarmBlock and " (" .. tostring(blockingFarmBlock.name) .. ")" or "")
    end
    if farm.crop == "supplementaries:flax" then
        local present, detail = turtle.inspectDown()
        local planeChanged = false
        if present and type(detail) == "table" and detail.name == farm.crop
            and detail.state and detail.state.half == "lower" then
            farm.y = farm.y + 1
            farm.cropHeight = 2
            cells, cellsError = cellsFor(farm)
            if not cells then return false, cellsError end
            local raised, raiseError = nav.up({
                shouldContinue = function() return not framework.isCancellationRequested(job) end,
            })
            if not raised then return false, "FARM_PLANE_RAISE_FAILED: " .. tostring(raiseError) end
            planeChanged = true
        end
        if present and type(detail) == "table" and detail.name == farm.crop
            and detail.state and detail.state.half == "upper" then
            farm.cropHeight = 2
        end
        if farm.cropHeight == 2 then
            local changed = planeChanged or farm.harvestMode ~= "tall_reap"
                or farm.seed ~= "supplementaries:flax_seeds"
            farm.harvestMode = "tall_reap"
            farm.seed = "supplementaries:flax_seeds"
            if changed then
                local saved, saveError = map.addNode(farm)
                if not saved then return false, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
                job.progress.discoveredFarm = farm
                if not framework.checkpoint(job, "Configured two-block Supplementaries flax") then
                    return false, "JOB_CANCELLED"
                end
            end
        end
    end
    if job.progress.pendingDig and (not farm.seed or inventory.countItem(farm.seed) < 1) then
        if not serviceStation or not farm.seed then
            return false, "NEEDS_SEEDS: crop was dug before reboot and must be replanted"
        end
        local pulled, pullError = station.pull(serviceStation, farm.seed, seedReserve, {
            shouldContinue = function() return not framework.isCancellationRequested(job) end,
        })
        if not pulled then return false, pullError end
    end
    if job.progress.pendingTallFlax and serviceStation
        and farm.seed and inventory.countItem(farm.seed) < 1 then
        local pulled, pullError = station.pull(
            serviceStation,
            farm.seed,
            math.max(seedReserve, #(job.progress.pendingReplants or {})), {
            shouldContinue = function() return not framework.isCancellationRequested(job) end,
        })
        if not pulled and pullError == "JOB_CANCELLED" then return false, pullError end
    end
    if #(job.progress.pendingReplants or {}) > 0 and serviceStation
        and farm.seed and inventory.countItem(farm.seed) < 1 then
        local pulled, pullError = station.pull(
            serviceStation,
            farm.seed,
            math.max(seedReserve, #job.progress.pendingReplants), {
            shouldContinue = function() return not framework.isCancellationRequested(job) end,
        })
        if not pulled and pullError == "JOB_CANCELLED" then return false, pullError end
    end
    local recovered, recoveryError = recoverPendingInteraction(farm, job, framework)
    if not recovered then return false, recoveryError end
    recovered, recoveryError = recoverPendingTallFlax(farm, job, framework)
    if not recovered then return false, recoveryError end
    recovered, recoveryError = recoverPendingDig(farm, job, framework)
    if not recovered then return false, recoveryError end
    local repaired, repairError = repairPendingTallReplants(farm, job, framework)
    if not repaired then return false, repairError end
    if not farm.harvestMode then
        local mode, modeError = detectHarvestMode(farm, cells, job, framework)
        if not mode then return false, modeError end
        protectedSeeds = seedProtection(farm, seedReserve)
    end
    if farm.harvestMode == "dig_replant" and (not farm.seed or inventory.countItem(farm.seed) < seedReserve) then
        if not serviceStation then
            return false, "NEEDS_SEEDS: this flax does not support interaction harvesting"
        end
        if not farm.seed then return false, "NEEDS_SEEDS: seed item name is unknown" end
        local pulled, pullError = station.pull(serviceStation, farm.seed, seedReserve, {
            shouldContinue = function() return not framework.isCancellationRequested(job) end,
        })
        if not pulled then return false, pullError end
    end
    if not framework.checkpoint(job, "Farm supplies ready") then return false, "JOB_CANCELLED" end

    while job.progress.cell <= #cells do
        if framework.isCancellationRequested(job) then return false, "JOB_CANCELLED" end
        local cell = cells[job.progress.cell]
        local arrived, travelError = nav.gotoXYZ(cell.x, cell.y, cell.z, cropTravelOptions(
            cell.y, function() return not framework.isCancellationRequested(job) end
        ))
        if not arrived then return false, "FARM_CELL_UNREACHABLE: " .. tostring(travelError) end

        local present, detail = turtle.inspectDown()
        if present and detail.name == farm.crop then
            local age = detail.state and tonumber(detail.state.age)
            local matureAge = farm.matureAge or config.farming.defaultMatureAge
            if age and age >= matureAge then
                if farm.harvestMode == "tall_reap" then
                    local harvested, harvestError = harvestTallFlax(farm, job, framework, cell)
                    if not harvested then return false, "TALL_FLAX_HARVEST_FAILED: " .. tostring(harvestError) end
                    job.progress.harvested = job.progress.harvested + 1
                    if harvestError == "REPLANT_DEFERRED" then
                        queueTallReplant(job, cell)
                    else
                        job.progress.replanted = job.progress.replanted + 1
                    end
                    job.progress.pendingTallFlax = nil
                elseif farm.harvestMode == "interact" then
                    local harvested, harvestError = interactHarvest(farm, job, framework, cell, false)
                    if harvested then
                        job.progress.harvested = job.progress.harvested + 1
                        job.progress.pendingInteraction = nil
                    elseif harvestError == "CROP_DID_NOT_RESET_AFTER_INTERACTION"
                        and farm.seed and inventory.countItem(farm.seed) >= 1 then
                        farm.harvestMode = "dig_replant"
                        local saved, saveError = map.addNode(farm)
                        if not saved then return false, "FARM_UPDATE_FAILED: " .. tostring(saveError) end
                        if not framework.checkpoint(job, "Switched farm to dig-and-replant") then
                            return false, "JOB_CANCELLED"
                        end
                    else
                        return false, "INTERACTION_HARVEST_FAILED: " .. tostring(harvestError)
                    end
                end
                if farm.harvestMode == "dig_replant" then
                    if not farm.seed or inventory.countItem(farm.seed) < 1 then
                        return false, "NEEDS_SEEDS: refusing to dig a crop without a replant seed"
                    end
                    if inventory.freeSlots() < config.farming.harvestDropSlots then
                        return false, "NEEDS_INVENTORY_SPACE"
                    end
                    job.progress.pendingDig = {
                        x = cell.x,
                        y = cell.y,
                        z = cell.z,
                        cell = job.progress.cell,
                        beforeAge = age,
                        harvested = false,
                        planted = false,
                    }
                    if not framework.checkpoint(job, "Prepared crop dig") then
                        return false, "JOB_CANCELLED"
                    end
                    local harvested, harvestError = digCropDown()
                    if not harvested then return false, "HARVEST_FAILED: " .. tostring(harvestError) end
                    job.progress.harvested = job.progress.harvested + 1
                    job.progress.pendingDig.harvested = true
                    state.save()
                    local planted, plantError = plant(farm.seed, farm.crop)
                    if not planted then return false, plantError end
                    job.progress.replanted = job.progress.replanted + 1
                    job.progress.pendingDig.planted = true
                    state.save()
                end
            else
                job.progress.skipped = job.progress.skipped + 1
            end
        elseif present and config.farming.farmlandNames[detail.name] then
            if farm.seed then
                local planted, plantError = plant(farm.seed, farm.crop)
                if not planted then return false, plantError end
                job.progress.replanted = job.progress.replanted + 1
            else
                job.progress.skipped = job.progress.skipped + 1
            end
        elseif present then
            return false, "UNEXPECTED_FARM_BLOCK: " .. tostring(detail.name)
        elseif farm.harvestMode == "tall_reap" then
            job.progress.skipped = job.progress.skipped + 1
        else
            return false, "FARMLAND_MISSING"
        end

        job.progress.pendingDig = nil
        job.progress.pendingTallFlax = nil
        job.progress.cell = job.progress.cell + 1
        if not framework.checkpoint(job, ("Farm cell %d/%d"):format(job.progress.cell - 1, #cells)) then
            return false, "JOB_CANCELLED"
        end
        repaired, repairError = repairPendingTallReplants(farm, job, framework)
        if not repaired then return false, repairError end
    end

    repaired, repairError = repairPendingTallReplants(farm, job, framework)
    if not repaired then return false, repairError end
    if #(job.progress.pendingReplants or {}) > 0 then
        return false, "NEEDS_SEEDS: harvested all mature flax but some cells still require replanting"
    end

    local unloadOptions = { shouldContinue = function() return not framework.isCancellationRequested(job) end }
    protectedSeeds = seedProtection(farm, seedReserve)
    local unloaded, unloadError
    if serviceStation then
        unloaded, unloadError = station.unload(serviceStation, protectedSeeds, unloadOptions)
    else
        unloaded, unloadError = station.unloadAt(farm.output, protectedSeeds, unloadOptions)
    end
    if not unloaded then return false, unloadError end
    local home = state.get().home
    local returnPosition = home and home.position or farm
    local returned, returnError = nav.gotoXYZ(returnPosition.x, returnPosition.y, returnPosition.z, {
        shouldContinue = function() return not framework.isCancellationRequested(job) end,
    })
    if returnError == "JOB_CANCELLED" then return false, returnError end
    if not returned then return false, "FARM_RETURN_FAILED: " .. tostring(returnError) end
    local modemOk, modemError = inventory.ensureModem()
    if not modemOk then return false, "NEEDS_MODEM: " .. tostring(modemError) end
    local gpsOk, gpsError = nav.syncGps(false)
    if not gpsOk then return false, "GPS_AFTER_FARM_FAILED: " .. tostring(gpsError) end
    if framework.isCancellationRequested(job) then return false, "JOB_CANCELLED" end
    return true, {
        farmId = farm.id,
        harvested = job.progress.harvested,
        replanted = job.progress.replanted,
        skipped = job.progress.skipped,
        farm = farm,
    }
end

return farmCrop
