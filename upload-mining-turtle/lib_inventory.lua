local config = require("config")
local state = require("lib.state")
local util = require("lib.util")

local inventory = {}

local function equipmentNames(role)
    return config.equipment[role] or {}
end

local function equippedDetail(side)
    local query = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if type(query) ~= "function" then return nil, "EQUIPMENT_QUERY_UNAVAILABLE" end
    return query()
end

local function roleForItem(itemName)
    if not itemName then return nil end
    for _, role in ipairs({ "modem", "pickaxe", "geoScanner", "farmingTool", "chunkLoader" }) do
        if util.contains(equipmentNames(role), itemName) then return role end
    end
    if itemName:lower():match("hoe$") then return "farmingTool" end
    return "other"
end

function inventory.findItem(names)
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and util.contains(names, detail.name) then
            return slot, detail
        end
    end
    return nil
end

function inventory.findEmptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then
            return slot
        end
    end
    return nil
end

function inventory.hasPeripheralType(peripheralType)
    return peripheral.find(peripheralType) ~= nil
end

function inventory.reconcile()
    local data = state.get()
    local pending = data.pendingEquipmentSwap
    if pending then
        local equipped, queryError = equippedDetail(pending.side)
        if queryError then return false, queryError end
        if equipped and roleForItem(equipped.name) == pending.role then
            data.equipment[pending.side] = pending.role
            util.log("WARN", "Recovered completed equipment swap", pending)
        else
            util.log("WARN", "Recovered uncommitted equipment swap", pending)
        end
        data.pendingEquipmentSwap = nil
        state.save()
    end

    local changed = false
    for _, side in ipairs({ "left", "right" }) do
        local equipped, queryError = equippedDetail(side)
        if queryError then return false, queryError end
        local actualRole = equipped and roleForItem(equipped.name) or nil
        if data.equipment[side] ~= actualRole then
            data.equipment[side] = actualRole
            changed = true
        end
    end
    if changed then state.save() end
    return true
end

function inventory.isEquipped(role)
    for _, side in ipairs({ "left", "right" }) do
        local equipped, queryError = equippedDetail(side)
        if queryError then return false, queryError end
        if equipped and roleForItem(equipped.name) == role then
            return true, side
        end
    end
    return false
end

local function oppositeSide(side)
    return side == "left" and "right" or "left"
end

local function sideFor(role)
    if role ~= "chunkLoader" then
        local chunkLoaded, chunkSide = inventory.isEquipped("chunkLoader")
        if chunkLoaded then return oppositeSide(chunkSide) end
    end
    if role ~= "modem" then
        local modemEquipped, modemSide = inventory.isEquipped("modem")
        if modemEquipped then return oppositeSide(modemSide) end
    else
        for _, toolRole in ipairs({ "farmingTool", "pickaxe", "geoScanner" }) do
            local equipped, toolSide = inventory.isEquipped(toolRole)
            if equipped then return oppositeSide(toolSide) end
        end
    end
    return config.equipment.preferredSide
end

function inventory.equip(role, side)
    side = side or config.equipment.preferredSide
    if side ~= "left" and side ~= "right" then
        return false, "INVALID_SIDE"
    end

    local targetEquipment, targetError = equippedDetail(side)
    if targetError then return false, targetError end
    if role ~= "chunkLoader" and targetEquipment
        and roleForItem(targetEquipment.name) == "chunkLoader" then
        return false, "CHUNK_LOADER_SIDE_PROTECTED"
    end

    local data = state.get()
    local alreadyEquipped, equippedSideOrError = inventory.isEquipped(role)
    if alreadyEquipped then
        data.equipment[equippedSideOrError] = role
        state.save()
        return true
    elseif equippedSideOrError then
        return false, equippedSideOrError
    end

    local slot = inventory.findItem(equipmentNames(role))
    if not slot and role == "farmingTool" then
        for candidate = 1, 16 do
            local detail = turtle.getItemDetail(candidate)
            if detail and detail.name:lower():match("hoe$") then slot = candidate break end
        end
    end
    if not slot then
        return false, "MISSING_" .. string.upper(role)
    end

    local previousSlot = turtle.getSelectedSlot()
    local selectedDetail = turtle.getItemDetail(slot)
    data.pendingEquipmentSwap = {
        side = side,
        role = role,
        slot = slot,
        itemName = selectedDetail and selectedDetail.name or nil,
        previousRole = data.equipment[side],
        at = util.now(),
    }
    state.save()
    turtle.select(slot)
    local equipFunction = side == "left" and turtle.equipLeft or turtle.equipRight
    local ok, equipError = equipFunction()
    turtle.select(previousSlot)
    if not ok then
        data.pendingEquipmentSwap = nil
        state.save()
        return false, "EQUIP_FAILED: " .. tostring(equipError)
    end

    local oldRole = data.equipment[side]
    data.equipment[side] = role
    data.pendingEquipmentSwap = nil
    if oldRole then
        util.log("INFO", "Swapped turtle equipment", { side = side, from = oldRole, to = role })
    else
        util.log("INFO", "Equipped turtle upgrade", { side = side, role = role })
    end
    state.save()
    return true
end

function inventory.unequip(role)
    local equipped, sideOrError = inventory.isEquipped(role)
    if not equipped then return nil, sideOrError or "NOT_EQUIPPED_" .. string.upper(role) end
    local slot = inventory.findEmptySlot()
    if not slot then return nil, "NEEDS_INVENTORY_SPACE" end
    local previousSlot = turtle.getSelectedSlot()
    turtle.select(slot)
    local equipFunction = sideOrError == "left" and turtle.equipLeft or turtle.equipRight
    local ok, equipError = equipFunction()
    turtle.select(previousSlot)
    if not ok then return nil, "UNEQUIP_FAILED: " .. tostring(equipError) end
    local reconciled, reconcileError = inventory.reconcile()
    if not reconciled then return nil, reconcileError end
    return slot, sideOrError
end

function inventory.equipOnSide(role, side)
    local equipped, currentSideOrError = inventory.isEquipped(role)
    if equipped and currentSideOrError == side then return true end
    if not equipped and currentSideOrError then return false, currentSideOrError end
    if equipped then
        local slot, unequipError = inventory.unequip(role)
        if not slot then return false, unequipError end
    end
    return inventory.equip(role, side)
end

function inventory.ensureModem(side)
    return inventory.equip("modem", side or sideFor("modem"))
end

function inventory.ensureMiningTool()
    return inventory.equip("pickaxe", sideFor("pickaxe"))
end

function inventory.ensureGeoScanner()
    return inventory.equip("geoScanner", sideFor("geoScanner"))
end

function inventory.ensureFarmingTool()
    return inventory.equip("farmingTool", sideFor("farmingTool"))
end

function inventory.prepareFarmingToolItem()
    local slot = inventory.findItem(equipmentNames("farmingTool"))
    if slot then return true, slot end
    local equipped, sideOrError = inventory.isEquipped("farmingTool")
    if not equipped then return false, sideOrError or "MISSING_FARMINGTOOL" end
    local removedSlot, removeError = inventory.unequip("farmingTool")
    if not removedSlot then return false, removeError end
    local modemEquipped = inventory.isEquipped("modem")
    if not modemEquipped then
        local modemOk, modemError = inventory.ensureModem(sideOrError)
        if not modemOk then return false, modemError end
    end
    return true, removedSlot
end

function inventory.withModem(callback)
    local modemEquipped = inventory.isEquipped("modem")
    if modemEquipped then return callback() end
    local reconciled, reconcileError = inventory.reconcile()
    if not reconciled then return false, reconcileError end
    local side = sideFor("modem")
    local previousRole = state.get().equipment[side]
    local equipped, equipError = inventory.ensureModem(side)
    if not equipped then return false, equipError end
    local results = table.pack(pcall(callback))
    local keepModem = results[1] and results[2] == true
    if not keepModem and previousRole then
        local restored, restoreError = inventory.equip(previousRole, side)
        if not restored then return false, restoreError end
    end
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

function inventory.countItem(itemName)
    local total = 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name == itemName then total = total + detail.count end
    end
    return total
end

function inventory.findItemNameContaining(fragment, preferredFragment)
    local fallback
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name:find(fragment, 1, true) then
            if preferredFragment and detail.name:find(preferredFragment, 1, true) then
                return detail.name, slot
            end
            fallback = fallback or detail.name
        end
    end
    return fallback
end

function inventory.isProtectedItem(itemName, additional)
    if not itemName then return false end
    if additional and type(additional[itemName]) == "number" then return false end
    if config.inventory.protectedItems[itemName] or (additional and additional[itemName] == true) then return true end
    if roleForItem(itemName) ~= "other" then return true end
    for _, blockName in pairs(config.markers) do
        if itemName == blockName then return true end
    end
    return itemName == config.markerPattern.inward or itemName == config.markerPattern.right
end

function inventory.dropNonProtected(additional)
    local previous = turtle.getSelectedSlot()
    local remaining = {}
    for itemName, count in pairs(additional or {}) do
        if type(count) == "number" then remaining[itemName] = math.max(0, count) end
    end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and not inventory.isProtectedItem(detail.name, additional) then
            local keep = math.min(detail.count, remaining[detail.name] or 0)
            remaining[detail.name] = math.max(0, (remaining[detail.name] or 0) - keep)
            local amount = detail.count - keep
            if amount > 0 then
                turtle.select(slot)
                if not turtle.drop(amount) then
                    turtle.select(previous)
                    return false, "OUTPUT_CHEST_FULL_OR_MISSING"
                end
            end
        end
    end
    turtle.select(previous)
    return true
end

function inventory.requiredOutputSlots(additional)
    local remaining = {}
    for itemName, count in pairs(additional or {}) do
        if type(count) == "number" then remaining[itemName] = math.max(0, count) end
    end
    local required = 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and not inventory.isProtectedItem(detail.name, additional) then
            local keep = math.min(detail.count, remaining[detail.name] or 0)
            remaining[detail.name] = math.max(0, (remaining[detail.name] or 0) - keep)
            if detail.count > keep then required = required + 1 end
        end
    end
    return required
end

function inventory.maximumOutputSlots(additional)
    local remaining = {}
    for itemName, count in pairs(additional or {}) do
        if type(count) == "number" then remaining[itemName] = math.max(0, count) end
    end
    local possible = 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if not detail then
            possible = possible + 1
        elseif not inventory.isProtectedItem(detail.name, additional) then
            local keep = math.min(detail.count, remaining[detail.name] or 0)
            remaining[detail.name] = math.max(0, (remaining[detail.name] or 0) - keep)
            if detail.count > keep then possible = possible + 1 end
        end
    end
    return possible
end

function inventory.pullItemFromFront(itemName, wanted)
    wanted = math.max(0, tonumber(wanted) or 0)
    local before = inventory.countItem(itemName)
    if before >= wanted then return true, 0 end
    local chest = peripheral.wrap("front")
    if not chest or type(chest.list) ~= "function" then return false, "SUPPLY_CHEST_NOT_AN_INVENTORY" end

    local moved = 0
    while inventory.countItem(itemName) < wanted do
        local contents = chest.list()
        local sourceSlot, sourceDetail
        for slot, detail in pairs(contents) do
            if detail.name == itemName then sourceSlot, sourceDetail = slot, detail break end
        end
        if not sourceSlot then break end
        local amount = math.min(sourceDetail.count, wanted - inventory.countItem(itemName))
        if sourceSlot ~= 1 and type(chest.pushItems) == "function" then
            local chestName = peripheral.getName(chest) or "front"
            if contents[1] then
                local empty
                for candidate = 2, chest.size() do
                    if not contents[candidate] then empty = candidate break end
                end
                if not empty then break end
                local callOk, shifted = pcall(chest.pushItems, chestName, 1, nil, empty)
                if not callOk or shifted == 0 then break end
            end
            local callOk, shifted = pcall(chest.pushItems, chestName, sourceSlot, amount, 1)
            if not callOk or shifted == 0 then break end
        elseif sourceSlot ~= 1 then
            return false, "SUPPLY_CHEST_CANNOT_SELECT_ITEM"
        end
        local selected = chest.list()[1]
        if not selected or selected.name ~= itemName then
            return false, "SUPPLY_CHEST_CANNOT_SELECT_ITEM"
        end
        local prior = inventory.countItem(itemName)
        turtle.suck(amount)
        local gained = inventory.countItem(itemName) - prior
        if gained <= 0 then break end
        moved = moved + gained
    end
    if inventory.countItem(itemName) < wanted then
        return false, "SUPPLY_MISSING_ITEM: " .. itemName
    end
    return true, moved
end

function inventory.refuelTo(target)
    local level = turtle.getFuelLevel()
    if level == "unlimited" or (type(level) == "number" and level >= target) then return true end
    local previous = turtle.getSelectedSlot()
    for _, itemName in ipairs(config.inventory.fuelItems) do
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            while detail and detail.name == itemName and turtle.getFuelLevel() < target do
                turtle.select(slot)
                if not turtle.refuel(1) then break end
                detail = turtle.getItemDetail(slot)
            end
        end
    end
    turtle.select(previous)
    level = turtle.getFuelLevel()
    return level == "unlimited" or (type(level) == "number" and level >= target), level
end

function inventory.selectItem(itemName)
    return inventory.findItem({ itemName })
end

function inventory.freeSlots()
    local count = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then
            count = count + 1
        end
    end
    return count
end

return inventory
