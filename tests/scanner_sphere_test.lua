package.loaded.config = {
    scanner = {
        surveyVersion = 2,
        maxRadius = 8,
        retryAttempts = 4,
        retryDelay = 2,
        chestNameContains = "chest",
        cropNameContains = "crop",
    },
}
package.loaded["lib.inventory"] = { ensureGeoScanner = function() return true end }
package.loaded["lib.markers"] = { recognizeScan = function() return {} end }
package.loaded["lib.nav"] = { getPosition = function() return { x = 10, y = 20, z = 30 } end }

peripheral = {
    find = function(kind)
        if kind ~= "geo_scanner" then return nil end
        return {
            scan = function()
                 return {
                     { x = 0, y = 0, z = 0, name = "minecraft:stone" },
                     { x = 2, y = 2, z = 2, name = "minecraft:stone" },
                 }
            end,
        }
    end,
}

local scanner = assert(loadfile("upload-mining-turtle/lib_scanner.lua"))()
local result, scanError = scanner.scan(2)
assert(result, tostring(scanError))
assert(result.version == 2, "scanner did not attach the current survey version")
assert(#result.blocks == 33, "radius-two sphere should contain exactly 33 known cells")

local cells = {}
for _, block in ipairs(result.blocks) do
    cells[("%d:%d:%d"):format(block.x, block.y, block.z)] = block.name
end
assert(cells["10:20:30"] == "minecraft:stone", "solid scanner result was not retained")
assert(cells["12:20:30"] == "minecraft:air", "known air on sphere boundary was not synthesized")
assert(cells["12:22:32"] == nil, "unknown cube corner was incorrectly synthesized as air")

local attempts, slept = 0, 0
sleep = function(seconds) slept = slept + seconds end
peripheral.find = function(kind)
    if kind ~= "geo_scanner" then return nil end
    return {
        scan = function()
            attempts = attempts + 1
            if attempts < 3 then return nil end
            return {}
        end,
    }
end
local retried, retryError = scanner.scan(2)
assert(retried, tostring(retryError))
assert(attempts == 3, "transient scanner failure was not retried")
assert(slept == 4, "scanner retries did not honor the configured delay")

print("scanner sphere tests passed")
