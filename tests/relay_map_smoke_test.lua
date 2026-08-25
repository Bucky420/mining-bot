settings = { get = function(_, default) return default end }
colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024,
    blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768,
}
keys = {
    backspace = 14, tab = 15, enter = 28, left = 203, right = 205,
    up = 200, down = 208,
}

local writes = {}
local function terminal()
    local cursorX, cursorY = 1, 1
    local object = {}
    function object.getSize() return 26, 20 end
    function object.setCursorPos(x, y) cursorX, cursorY = x, y end
    function object.getCursorPos() return cursorX, cursorY end
    function object.setTextColor() end
    function object.setBackgroundColor() end
    function object.clear() end
    function object.clearLine() end
    function object.scroll() end
    function object.write(text)
        writes[#writes + 1] = { x = cursorX, y = cursorY, text = tostring(text) }
        cursorX = cursorX + #tostring(text)
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
    setTextColor = function(color) return current.setTextColor(color) end,
    setBackgroundColor = function(color) return current.setBackgroundColor(color) end,
}
window = { create = function() return terminal() end }
write = function(value) current.write(value) end
printError = function(value) current.write(tostring(value)) end

fs = {
    exists = function() return false end,
    isDir = function() return false end,
    open = function()
        return { write = function() end, readAll = function() return "" end, close = function() end }
    end,
    delete = function() end,
    copy = function() end,
    move = function() end,
    makeDir = function() end,
    list = function() return {} end,
    combine = function(a, b) return tostring(a) .. "/" .. tostring(b) end,
    getDir = function() return "" end,
    getName = function(path) return path end,
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
        type = "FARM_MAP_DELTA", controllerBootId = "boot", farmKey = "farm",
        mapRevision = 3, baseRevision = 1, chunkIndex = 1, chunkCount = 1,
        cells = { { x = 1, y = 69, z = 0, name = "minecraft:water", class = "water" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "TURTLE_UPDATE", controllerBootId = "boot",
        turtle = { id = 12, name = "worker", heading = "east", lastSeen = 1000,
            position = { x = 2, y = 70, z = 0 } },
    }, "bucky/mining/v1" },
    { "mouse_click", 1, 8, 1 },
    { "timer", 2 },
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
}, { __index = realOs })

local ok, loadError = pcall(assert(loadfile("drag-to-relay-pc/relay.lua")))
assert(not ok and tostring(loadError):find("STOP_RELAY_TEST", 1, true), tostring(loadError))

local requestedMap = false
for _, packet in ipairs(sent) do
    if packet.message.type == "FARM_MAP_RESYNC_REQUEST" and packet.message.farmKey == "farm" then
        requestedMap = true
    end
end
assert(requestedMap, "relay did not request the indexed farm map")

local renderedPlayer = false
local renderedWater = false
local renderedTurtle = false
for _, entry in ipairs(writes) do
    if entry.text == "@" then renderedPlayer = true end
    if entry.text == "~" then renderedWater = true end
    if entry.text == ">" then renderedTurtle = true end
end
assert(renderedPlayer, "map tab did not render the followed GPS player")
assert(renderedWater, "map tab did not render a live terrain delta")
assert(renderedTurtle, "map tab did not render a live turtle heading")

writes, sent, eventIndex, timerId, current = {}, {}, 0, 0, native
local gpsCalls = 0
gps.locate = function()
    gpsCalls = gpsCalls + 1
    if gpsCalls == 1 then return 0, 70, 0 end
    return 1, 70, 0
end
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
        metadata = { center = { x = 0, y = 69, z = 0 } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_CHUNK", controllerBootId = "boot-map", farmKey = "farm",
        snapshotId = "map-snapshot", chunkIndex = 1, chunkCount = 1,
        cells = { { x = 1, y = 69, z = 0, name = "minecraft:water", class = "water" } },
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "FARM_MAP_SNAPSHOT_END", controllerBootId = "boot-map", farmKey = "farm",
        snapshotId = "map-snapshot", mapRevision = 1,
    }, "bucky/mining/v1" },
    { "rednet_message", 9, {
        type = "TURTLE_UPDATE", controllerBootId = "boot-map",
        turtle = { id = 12, name = "worker", heading = "east", lastSeen = 1000,
            position = { x = 2, y = 70, z = 0 } },
    }, "bucky/mining/v1" },
    { "timer", 1 },
    { "timer", 3 },
}

ok, loadError = pcall(assert(loadfile("drag-to-relay-pc/relay-map.lua")))
assert(not ok and tostring(loadError):find("STOP_RELAY_TEST", 1, true), tostring(loadError))
local renderedHeadingUp = false
renderedPlayer, renderedWater, renderedTurtle = false, false, false
for _, entry in ipairs(writes) do
    if entry.text == "@" then renderedPlayer = true end
    if entry.text == "~" then renderedWater = true end
    if entry.text == ">" then renderedTurtle = true end
    if entry.text == "^" then renderedHeadingUp = true end
end
assert(renderedPlayer, "native map did not render the pocket GPS position")
assert(renderedWater, "native map did not render synced terrain")
assert(renderedTurtle, "native map did not render the turtle heading")
assert(renderedHeadingUp, "native map did not rotate eastward travel to screen-up")

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
