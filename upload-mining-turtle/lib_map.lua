local config = require("config")
local state = require("lib.state")
local util = require("lib.util")

local map = {}
local current

local function emptyMap()
    return {
        version = 1,
        revision = 0,
        nodes = {},
        edges = {},
        updatedAt = util.now(),
    }
end

local function validate(data)
    if type(data) ~= "table" or data.version ~= 1 then
        return false, "unsupported map format"
    end
    if type(data.nodes) ~= "table" or type(data.edges) ~= "table" then
        return false, "map nodes or edges are missing"
    end
    return true
end

local function syncRevision(data)
    local workerState = state.get()
    if workerState.mapRevision ~= data.revision then
        workerState.mapRevision = data.revision
        state.save()
    end
end

function map.load()
    if current then return current end
    local candidates = {
        { name = "primary", path = config.paths.map },
        { name = "temporary", path = config.paths.map .. ".tmp" },
        { name = "previous", path = config.paths.map .. ".previous" },
        { name = "backup", path = config.paths.map .. ".bak" },
    }
    local errors = {}
    for index, candidate in ipairs(candidates) do
        local loaded, readError = util.readTable(candidate.path)
        local valid, validationError = validate(loaded)
        if valid then
            current = loaded
            if index ~= 1 then
                util.log("WARN", "Recovered tunnel map", { source = candidate.name })
                if fs.exists(config.paths.map) then fs.delete(config.paths.map) end
                fs.copy(candidate.path, config.paths.map)
            end
            syncRevision(current)
            return current
        end
        errors[candidate.name] = validationError or readError
    end

    local foundMap = false
    for _, candidate in ipairs(candidates) do
        if fs.exists(candidate.path) then foundMap = true break end
    end
    if foundMap then
        error("Cannot safely load tunnel map: " .. textutils.serialize(errors, { compact = true }), 0)
    end
    current = emptyMap()
    map.save()
    return current
end

function map.save()
    local data = current or map.load()
    data.updatedAt = util.now()
    local ok, saveError = util.atomicWriteTable(config.paths.map, data)
    if not ok then error("Unable to persist tunnel map: " .. tostring(saveError), 0) end
    syncRevision(data)
end

function map.getNode(id)
    return map.load().nodes[id]
end

function map.getStation(id)
    local node = map.getNode(id)
    if node and node.type == "service_station" then return node end
    return nil
end

function map.getFarm(id)
    local node = map.getNode(id)
    if node and node.type == "farm" then return node end
    return nil
end

function map.getNodes()
    return util.copy(map.load().nodes)
end

function map.findNodeAt(x, y, z)
    for _, node in pairs(map.load().nodes) do
        if node.x == x and node.y == y and node.z == z then
            return node
        end
    end
    return nil
end

function map.expectedMarker(node)
    if not node then return nil end
    if node.marker then return node.marker end
    if node.type == "junction" then return "JUNCTION" end
    if node.type == "endpoint" or node.type == "cap" then return "END" end
    return nil
end

function map.addNode(node)
    if type(node) ~= "table" or type(node.id) ~= "string" then
        return false, "node requires a string id"
    end
    for _, key in ipairs({ "x", "y", "z" }) do
        if type(node[key]) ~= "number" then return false, "node requires numeric " .. key end
    end
    local data = map.load()
    data.nodes[node.id] = util.copy(node)
    data.revision = data.revision + 1
    map.save()
    return true
end

local function inheritedProfile(edge)
    if edge.profile and config.profiles[edge.profile] then return edge.profile end
    local data = map.load()
    local fromNode = data.nodes[edge.from]
    if fromNode and fromNode.profile and config.profiles[fromNode.profile] then
        return fromNode.profile
    end
    for _, existing in pairs(data.edges) do
        if existing.from == edge.from or existing.to == edge.from then
            if existing.profile and config.profiles[existing.profile] then
                return existing.profile
            end
        end
    end
    return config.defaultProfile
end

function map.addEdge(edge)
    if type(edge) ~= "table" or type(edge.id) ~= "string" then
        return false, "edge requires a string id"
    end
    local data = map.load()
    if not data.nodes[edge.from] or not data.nodes[edge.to] then
        return false, "edge endpoints must exist"
    end
    local saved = util.copy(edge)
    saved.profile = inheritedProfile(saved)
    local profile = config.profiles[saved.profile]
    saved.width = saved.width or profile.width
    saved.height = saved.height or profile.height
    saved.status = saved.status or "planned"
    data.edges[saved.id] = saved
    data.revision = data.revision + 1
    map.save()
    return true
end

function map.getEdge(id)
    return map.load().edges[id]
end

function map.getRevision()
    return map.load().revision
end

return map
