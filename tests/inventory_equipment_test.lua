local equipped = {
    left = { name = "advancedperipherals:unexpected_chunk_controller_id", count = 1 },
    right = { name = "computercraft:wireless_modem_advanced", count = 1 },
}
local slots = {
    [1] = { name = "advancedperipherals:geo_scanner", count = 1 },
}
local selected = 1
local savedState = { equipment = {}, pendingEquipmentSwap = nil }

package.preload.config = function()
    return {
        equipment = {
            preferredSide = "right",
            modem = { "computercraft:wireless_modem_advanced" },
            pickaxe = { "minecraft:diamond_pickaxe" },
            geoScanner = { "advancedperipherals:geo_scanner" },
            farmingTool = { "minecraft:diamond_hoe" },
            chunkLoader = { "advancedperipherals:chunk_controller" },
        },
        inventory = { protectedItems = {} },
        markers = {},
        markerPattern = {},
    }
end

package.preload["lib.state"] = function()
    return {
        get = function() return savedState end,
        save = function() return true end,
    }
end

package.preload["lib.util"] = function()
    return {
        contains = function(values, wanted)
            for _, value in ipairs(values or {}) do if value == wanted then return true end end
            return false
        end,
        now = function() return 1 end,
        log = function() end,
    }
end

local function clone(detail)
    if not detail then return nil end
    return { name = detail.name, count = detail.count }
end

turtle = {
    getEquippedLeft = function() return clone(equipped.left) end,
    getEquippedRight = function() return clone(equipped.right) end,
    getSelectedSlot = function() return selected end,
    select = function(slot) selected = slot return true end,
    getItemDetail = function(slot) return clone(slots[slot]) end,
    getItemCount = function(slot) return slots[slot] and slots[slot].count or 0 end,
}

local function swap(side)
    slots[selected], equipped[side] = equipped[side], slots[selected]
    return true
end
turtle.equipLeft = function() return swap("left") end
turtle.equipRight = function() return swap("right") end

peripheral = {
    find = function() return nil end,
}

local inventory = assert(loadfile("upload-mining-turtle/lib_inventory.lua"))()

local scannerOk, scannerError = inventory.ensureGeoScanner()
assert(scannerOk, tostring(scannerError))
assert(equipped.left.name == "advancedperipherals:unexpected_chunk_controller_id",
    "scanner replaced the unknown protected upgrade")
assert(equipped.right.name == "advancedperipherals:geo_scanner",
    "scanner did not replace the modem side")

local modemOk, modemError = inventory.ensureModem()
assert(modemOk, tostring(modemError))
assert(equipped.left.name == "advancedperipherals:unexpected_chunk_controller_id",
    "modem restoration replaced the unknown protected upgrade")
assert(equipped.right.name == "computercraft:wireless_modem_advanced",
    "modem was not restored onto the scanner side")

local protectedOk, protectedError = inventory.equip("geoScanner", "left")
assert(not protectedOk and tostring(protectedError):find("UNKNOWN_EQUIPMENT_SIDE_PROTECTED", 1, true),
    "explicit swaps did not protect an unknown equipped upgrade")

equipped.left = { name = "computercraft:wireless_modem_advanced", count = 1 }
equipped.right = { name = "advancedperipherals:geo_scanner", count = 1 }
slots[1] = { name = "advancedperipherals:chunk_controller", count = 1 }
savedState.equipment = {}
local reconciled, reconcileError = inventory.reconcile()
assert(reconciled, tostring(reconcileError))
assert(equipped.left.name == "computercraft:wireless_modem_advanced",
    "chunk recovery replaced the modem")
assert(equipped.right.name == "advancedperipherals:chunk_controller",
    "chunk recovery did not replace the temporary scanner")

print("inventory equipment tests passed")
