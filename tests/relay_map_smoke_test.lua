settings = { get = function(_, default) return default end }
colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024,
    blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768,
}
function colors.toBlit(color)
    for index = 0, 15 do if color == 2 ^ index then return ("%x"):format(index) end end
end
keys = {
    backspace = 14, tab = 15, enter = 28, left = 203, right = 205,
    up = 200, down = 208, pageUp = 201, pageDown = 209, space = 57,
}

local writes = {}
local function terminal()
    local cursorX, cursorY = 1, 1
    local foreground, background = colors.white, colors.black
    local object = {}
    function object.getSize() return 26, 20 end
    function object.setCursorPos(x, y) cursorX, cursorY = x, y end
    function object.getCursorPos() return cursorX, cursorY end
    function object.setTextColor(color) foreground = color end
    function object.setBackgroundColor(color) background = color end
    function object.clear() end
    function object.clearLine() end
    function object.scroll() end
    function object.write(text)
        writes[#writes + 1] = {
            x = cursorX, y = cursorY, text = tostring(text),
            foreground = foreground, background = background,
        }
        cursorX = cursorX + #tostring(text)
    end
    function object.blit(text, foregroundColors, backgroundColors)
        writes[#writes + 1] = {
            x = cursorX, y = cursorY, text = text,
            foreground = foregroundColors, background = backgroundColors, blit = true,
        }
        cursorX = cursorX + #text
    end
    function object.setVisible() end
    return object
end

local native = terminal()
local current = native
term = {
    current = function() return current end,
    redirect = function(target) local old = current current = target return old end,
    getSize = function() return current.getSize() end,
    getCursorPos = function() return current.getCursorPos() end,
    setCursorPos = function(x, y) return current.setCursorPos(x, y) end,
    clear = function() return current.clear() end,
    clearLine = function() return current.clearLine() end,
    write = function(value) return current.write(value) end,
    blit = function(text, foreground, background)
        return current.blit(text, foreground, background)
    end,
    setTextColor = function(color) return current.setTextColor(color) end,
    setBackgroundColor = function(color) return current.setBackgroundColor(color) end,
}
window = { create = function() return terminal() end }
write = function(value) current.write(value) end
printError = function(value) current.write(tostring(value)) end

local virtualFiles = {
    ["/startup.lua"] = "old startup",
    ["/relay.lua"] = "old relay",
    ["/relay-map.lua"] = "old map",
}
fs = {
    exists = function(path) return virtualFiles[path] ~= nil end,
    isDir = function() return false end,
    open = function(path, mode)
        if mode == "r" then
            if virtualFiles[path] == nil then return nil end
            return { readAll = function() return virtualFiles[path] end, close = function() end }
        end
        local buffer = ""
        return {
            write = function(value) buffer = buffer .. tostring(value) end,
            readAll = function() return virtualFiles[path] or "" end,
            close = function() virtualFiles[path] = buffer end,
        }
    end,
    delete = function(path)
        virtualFiles[path] = nil
        for name in pairs(virtualFiles) do
            if name:sub(1, #path + 1) == path .. "/" then virtualFiles[name] = nil end
        end
    end,
    copy = function(source, destination)
        assert(virtualFiles[source] ~= nil, "missing copy source " .. source)
        virtualFiles[destination] = virtualFiles[source]
    end,
    move = function(source, destination)
        assert(virtualFiles[source] ~= nil, "missing move source " .. source)
        virtualFiles[destination], virtualFiles[source] = virtualFiles[source], nil
    end,
    makeDir = function() end,
    list = function() return {} end,
    combine = function(a, b) return tostring(a) .. "/" .. tostring(b) end,
    getDir = function(path) return path:match("^(.*)/[^/]+$") or "" end,
    getName = function(path) return path:match("([^/]+)$") or path end,
}
textutils = {
    serialize = function() return "{}" end,
    unserialize = function() return nil end,
}

peripheral = {
    find = function() return nil end,
    getNames = function() return { "back" } end,
    getType = function() return "modem" end,
}

local sent = {}
rednet = {
    isOpen = function() return true end,
    open = function() end,
    send = function(id, message, protocol)
        sent[#sent + 1] = { id = id, message = message, protocol = protocol }
        return true
    end,
    broadcast = function() return true end,
}

gps = { locate = function() return 0, 70, 0 end }
sleep = function() end

local realOs = os
local timerId = 0
local relayPackage = {
    ["startup.lua"] = "return true",
    ["relay.lua"] = "return true",
    ["relay-map.lua"] = "return true",
    ["relay-manifest.lua"] = [[return {version=1,files={
        {source="startup.lua",path="startup.lua"},
        {source="relay.lua",path="relay.lua"},
        {source="relay-map.lua",path="relay-map.lua"},
        {source="relay-manifest.lua",path="relay-manifest.lua"},
    }}]],
}
local transfer = { getFiles = function()
    local result = {}
    for name, contents in pairs(relayPackage) do
        local fileName, fileContents = name, contents
        result[#result + 1] = {
            getName = function() return fileName end,
            readAll = function() return fileContents end,
            close = function() end,
        }
    end
    return result
end }
local events = {
    { "rednet_message", 9, {
        type = "CONTROLLER_HELLO", controllerId = 9, bootId = "boot",
        turtles = { "worker" }, sites = {},
        turtleStates = {
            [12] = { id = 12, name = "worker", heading = "east", lastSeen = 1000,
                position = { x = 2, y = 70, z = 0 } },
        },
        farmMapKeys = { { farmKey = "farm", revision = 1 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "RELAY_ACK", controllerBootId = "boot", turtles = { "worker" }, sites = {},
        turtleStates = {}, farmMapKeys = { { farmKey = "farm", revision = 1 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_BEGIN", controllerBootId = "boot", farmKey = "farm",
        snapshotId = "snapshot", mapRevision = 1, chunkCount = 1, cellCount = 1,
        metadata = { center = { x = 0, y = 69, z = 0 }, radius = 32 },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_CHUNK", controllerBootId = "boot", farmKey = "farm",
        snapshotId = "snapshot", mapRevision = 1, chunkIndex = 1, chunkCount = 1,
        cells = { { x = 0, y = 69, z = 0, name = "minecraft:grass_block", class = "grass" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_END", controllerBootId = "boot", farmKey = "farm",
        snapshotId = "snapshot", mapRevision = 1, chunkCount = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_BEGIN", controllerBootId = "boot", requestId = "slice-99-1000",
        farmId = "farm", x = 0, y = 69, z = 0, radius = 13,
        environment = "cave", chunkCount = 1, cellCount = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_CHUNK", controllerBootId = "boot", requestId = "slice-99-1000",
        chunkIndex = 1, chunkCount = 1,
        cells = { { x = 0, y = 69, z = 0, name = "minecraft:stone", class = "tunnel" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_END", controllerBootId = "boot", requestId = "slice-99-1000",
        chunkCount = 1, cellCount = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_DELTA", controllerBootId = "boot", farmKey = "farm",
        mapRevision = 3, baseRevision = 1, chunkIndex = 1, chunkCount = 1,
        cells = { { x = 1, y = 69, z = 0, name = "minecraft:water", class = "water" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "TURTLE_UPDATE", controllerBootId = "boot",
        turtle = { id = 12, name = "worker", heading = "east", lastSeen = 1000,
            position = { x = 2, y = 70, z = 0 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "PLAYER_UPDATE", controllerBootId = "boot",
        player = { name = "BIGT", x = 0, y = 70, z = 0, yaw = -90 },
    }, "bucky/mining/v1" },
    { "mouse_click", 1, 8, 1 },
    { "timer", 2 },
    { "file_transfer", transfer },
}
local eventIndex = 0
os = setmetatable({
    getComputerID = function() return 99 end,
    epoch = function() return 1000 end,
    startTimer = function() timerId = timerId + 1 return timerId end,
    pullEvent = function()
        eventIndex = eventIndex + 1
        local event = events[eventIndex]
        if not event then error("STOP_RELAY_TEST", 0) end
        return table.unpack(event)
    end,
    reboot = function() error("SELF_UPDATE_REBOOT", 0) end,
}, { __index = realOs })

local ok, loadError = pcall(assert(loadfile("drag-to-relay-pc/relay.lua")))
assert(not ok and tostring(loadError):find("SELF_UPDATE_REBOOT", 1, true), tostring(loadError))
for name, contents in pairs(relayPackage) do
    assert(virtualFiles["/" .. name] == contents, "self-update did not install " .. name)
end
assert(not virtualFiles["/.relay-self-update/installing"], "self-update marker was not cleaned")

local requestedMap = false
for _, packet in ipairs(sent) do
    if packet.message.type == "FARM_MAP_RESYNC_REQUEST" and packet.message.farmKey == "farm" then
        requestedMap = true
    end
end
assert(requestedMap, "relay did not request the indexed farm map")

local renderedPlayer, renderedWater, renderedTurtle, renderedTunnel = false, false, false, false
local renderedEastUp = false
for _, entry in ipairs(writes) do
    if entry.text == " " and entry.background == colors.cyan then renderedPlayer = true end
    if entry.text == " " and entry.background == colors.blue then renderedWater = true end
    if entry.text == " " and entry.background == colors.orange then renderedTurtle = true end
    if entry.text == " " and (entry.background == colors.brown
        or entry.background == colors.lightGray) then renderedTunnel = true end
    if entry.text:find("UP:E", 1, true) then renderedEastUp = true end
end
assert(renderedPlayer, "map tab did not render the followed GPS player pixel")
assert(renderedTurtle, "map tab did not render a live turtle pixel")
assert(renderedTunnel, "map tab did not render the requested 3D tunnel layer")
assert(renderedEastUp, "map tab did not use controller Player Detector yaw")

writes, sent, eventIndex, timerId, current = {}, {}, 0, 0, native
gps.locate = function() return nil end
peripheral.find = function() return nil end
events = {
    { "rednet_message", 9, {
        type = "CONTROLLER_HELLO", controllerId = 9, bootId = "boot-map",
        turtles = {}, sites = {}, turtleStates = {},
        farmMapKeys = { { farmKey = "farm", revision = 1 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "RELAY_ACK", controllerBootId = "boot-map", turtleStates = {},
        farmMapKeys = { { farmKey = "farm", revision = 1 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_BEGIN", controllerBootId = "boot-map", farmKey = "farm",
        snapshotId = "map-snapshot", mapRevision = 1, chunkCount = 1, cellCount = 1,
        metadata = { center = { x = 88582, y = 69, z = 73676 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_CHUNK", controllerBootId = "boot-map", farmKey = "farm",
        snapshotId = "map-snapshot", chunkIndex = 1, chunkCount = 1,
        cells = { { x = 88583, y = 69, z = 73676, name = "minecraft:water", class = "water" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_END", controllerBootId = "boot-map", farmKey = "farm",
        snapshotId = "map-snapshot", mapRevision = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_BEGIN", controllerBootId = "boot-map", requestId = "slice-99-1000",
        farmId = "farm", x = 88582, y = 69, z = 73676,
        radius = 64, environment = "surface", chunkCount = 1, cellCount = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_CHUNK", controllerBootId = "boot-map", requestId = "slice-99-1000",
        chunkIndex = 1, chunkCount = 1,
        cells = { { x = 88583, y = 69, z = 73676, name = "minecraft:stone", class = "tunnel" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_3D_SLICE_END", controllerBootId = "boot-map", requestId = "slice-99-1000",
        chunkCount = 1, cellCount = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "TURTLE_UPDATE", controllerBootId = "boot-map",
        turtle = { id = 12, name = "worker", heading = "east", lastSeen = 1000,
            position = { x = 88584, y = 70, z = 73676 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "PLAYER_UPDATE", controllerBootId = "boot-map",
        player = { name = "BIGT", x = 88582, y = 70, z = 73676, yaw = -90 },
    }, "bucky/mining/v1" },
    { "timer", 1 },
    { "timer", 3 },
    { "key", keys.pageDown },
    { "key", keys.pageUp },
    { "key", keys.left },
    { "key", keys.space },
}

ok, loadError = pcall(assert(loadfile("drag-to-relay-pc/relay-map.lua")))
assert(not ok and tostring(loadError):find("STOP_RELAY_TEST", 1, true), tostring(loadError))
renderedWater, renderedTurtle, renderedEastUp, renderedTunnel = false, false, false, false
local waterBlit = colors.toBlit(colors.blue)
local turtleBlit = colors.toBlit(colors.orange)
local tunnelBlit = colors.toBlit(colors.brown)
for _, entry in ipairs(writes) do
    if entry.blit and (entry.foreground:find(waterBlit, 1, true)
        or entry.background:find(waterBlit, 1, true)) then renderedWater = true end
    if entry.blit and (entry.foreground:find(turtleBlit, 1, true)
        or entry.background:find(turtleBlit, 1, true)) then renderedTurtle = true end
    if entry.blit and (entry.foreground:find(tunnelBlit, 1, true)
        or entry.background:find(tunnelBlit, 1, true)) then renderedTunnel = true end
    if entry.text:find("UP:E", 1, true) then renderedEastUp = true end
end
assert(renderedWater, "native map did not retain the surface map while outdoors")
assert(renderedTurtle, "native map did not center and render the turtle without GPS")
assert(not renderedTunnel, "native map showed cave data while classified as surface")
assert(renderedEastUp, "native map did not use Player Detector yaw")

local titles, focused, openedProgram, openedArgument = {}, nil, nil, nil
shell = {
    getRunningProgram = function() return "startup.lua" end,
    openTab = function(program, argument)
        openedProgram, openedArgument = program, argument
        return 2
    end,
    run = function(program)
        assert(program == "relay-map", "startup did not supervise the map in its current tab")
        return true
    end,
}
multishell = {
    getCurrent = function() return 1 end,
    setTitle = function(tab, title) titles[tab] = title end,
    setFocus = function(tab) focused = tab end,
}
assert(loadfile("drag-to-relay-pc/startup.lua"))()
assert(openedProgram == "startup.lua" and openedArgument == "command",
    "startup did not open the command supervisor tab")
assert(titles[1] == "Map" and titles[2] == "Command", "native tab titles were not assigned")
assert(focused == 2, "startup did not focus the Command tab")

local commandProgram, commandArgument
shell.run = function(program, argument)
    commandProgram, commandArgument = program, argument
    return true
end
assert(loadfile("drag-to-relay-pc/startup.lua"))("command")
assert(commandProgram == "relay" and commandArgument == "native",
    "command supervisor did not explicitly enable relay native-tab mode")

print("relay map smoke test passed")
