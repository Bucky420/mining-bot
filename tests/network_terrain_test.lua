local now = 1000
local responses = {}
local lastSent
local stateData = { controllerId = 9, controllerBootId = "boot", reportOutbox = {} }

package.preload["config"] = function()
    return {
        network = {
            enabled = true, protocol = "bucky/mining/v1",
            controllerId = nil, maxQueuedReports = 2,
        },
    }
end
package.preload["lib.inventory"] = function()
    return { ensureModem = function() return true end }
end
package.preload["lib.state"] = function()
    return { get = function() return stateData end, save = function() end }
end
package.preload["lib.util"] = function()
    return {
        now = function() now = now + 1 return now end,
        makeId = function(prefix) return prefix .. "-request" end,
        detachedCopy = function(value) return value end,
    }
end

peripheral = {
    getNames = function() return { "left" } end,
    getType = function() return "modem" end,
}
rednet = {
    isOpen = function() return true end,
    open = function() end,
    send = function(id, message)
        lastSent = { id = id, message = message }
    end,
    receive = function()
        local value = table.remove(responses, 1)
        if not value then now = now + 10000 return nil end
        return value[1], value[2]
    end,
}
fs = { exists = function() return false end }
os.getComputerID = function() return 4 end

local network = assert(loadfile("upload-mining-turtle/lib_network.lua"))()

responses = {
    { 9, {
        type = "FARM_ROUTE_RESPONSE", requestId = "farm-route-request", ok = true,
        mapRevision = 7, path = { { x = 1, z = 0 }, { x = 2, z = 0 } },
    } },
}
local route, routeError, revision = network.requestFarmRoute(
    "farm", { x = 0, z = 0 }, { x = 2, z = 0 }, "east", 6
)
assert(route and not routeError and revision == 7 and #route == 2)
assert(lastSent.id == 9 and lastSent.message.minRevision == 6)

responses = {
    { 9, {
        type = "FARM_ROUTE_RESPONSE", requestId = "farm-route-request", ok = true,
        path = { { x = 2, z = 0 } },
    } },
}
local invalid, invalidError = network.requestFarmRoute(
    "farm", { x = 0, z = 0 }, { x = 2, z = 0 }, "east"
)
assert(invalid == nil and invalidError == "INVALID_CONTROLLER_ROUTE")

responses = {
    { 9, {
        type = "FARM_TERRAIN_BEGIN", requestId = "farm-terrain-request", ok = true,
        revision = 8, chunkCount = 2, cellCount = 2,
    } },
    { 9, {
        type = "FARM_TERRAIN_CHUNK", requestId = "farm-terrain-request",
        chunkIndex = 1, chunkCount = 2,
        cells = { { x = 0, y = 70, z = 0, class = "grass" } },
    } },
    { 9, {
        type = "FARM_TERRAIN_CHUNK", requestId = "farm-terrain-request",
        chunkIndex = 2, chunkCount = 2,
        cells = { { x = 1, y = 70, z = 0, class = "grass" } },
    } },
    { 9, {
        type = "FARM_TERRAIN_END", requestId = "farm-terrain-request",
        revision = 8, chunkCount = 2,
    } },
}
local cells, terrainError, terrainRevision = network.requestFarmTerrain("farm", 8)
assert(cells and not terrainError and terrainRevision == 8 and #cells == 2)

responses = {}
local reported, reportError = network.report("FARM_MAP", { revision = 9 })
assert(reported and reportError:find("QUEUED_OFFLINE", 1, true), tostring(reportError))
assert(#stateData.reportOutbox == 1, "unacknowledged report was dropped")
responses = {}
reported, reportError = network.report("FARM_MAP", { revision = 10 })
assert(not reported and reportError:find("REPORT_BACKLOG_LIMIT_REACHED", 1, true),
    tostring(reportError))
assert(network.reportBacklogFull() and #stateData.reportOutbox == 2,
    "full report backlog did not retain terrain")
reported, reportError = network.report("JOB_FAILED", {})
assert(not reported and reportError == "REPORT_BACKLOG_LIMIT_REACHED"
    and #stateData.reportOutbox == 2, "status report exceeded the bounded terrain backlog")
responses = {
    { 9, { type = "REPORT_ACK", messageId = stateData.reportOutbox[1].messageId } },
    { 9, { type = "REPORT_ACK", messageId = stateData.reportOutbox[2].messageId } },
}
reported, reportError = network.flushReports(true)
assert(reported and not reportError and #stateData.reportOutbox == 0,
    "queued report was not removed after acknowledgement")

print("network terrain tests passed")
