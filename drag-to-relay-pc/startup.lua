local arguments = { ... }

local updateRoot = "/.relay-self-update"
local markerPath = fs.combine(updateRoot, "installing")
local backupRoot = fs.combine(updateRoot, "backup")

local function recoverInterruptedUpdate()
    if not fs.exists(markerPath) then return end
    local handle = fs.open(markerPath, "r")
    local marker = handle and textutils.unserialize(handle.readAll())
    if handle then handle.close() end
    if type(marker) ~= "table" or type(marker.files) ~= "table" then
        error("Relay update recovery marker is corrupt", 0)
    end
    for _, entry in ipairs(marker.files) do
        if type(entry) ~= "table" or type(entry.path) ~= "string" then
            error("Relay update recovery marker has an invalid path", 0)
        end
        local destination = "/" .. entry.path
        local backup = fs.combine(backupRoot, entry.path)
        if fs.exists(backup) then
            if fs.exists(destination) then fs.delete(destination) end
            local parent = fs.getDir(destination)
            if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
            fs.move(backup, destination)
        elseif entry.existed == false and fs.exists(destination) then
            fs.delete(destination)
        end
    end
    fs.delete(updateRoot)
end

recoverInterruptedUpdate()

local function supervise(program, label, ...)
    local programArguments = { ... }
    while true do
        local ok = shell.run(program, table.unpack(programArguments))
        if ok then return end
        printError(label .. " stopped; retrying in 5 seconds.")
        sleep(5)
    end
end

if arguments[1] == "command" then
    supervise("relay", "Deployment relay", "native")
    return
end

if multishell and shell.openTab then
    local commandTab = shell.openTab(shell.getRunningProgram(), "command")
    if commandTab then
        multishell.setTitle(commandTab, "Command")
        multishell.setTitle(multishell.getCurrent(), "Map")
        multishell.setFocus(commandTab)
        supervise("relay-map", "Relay map")
        return
    end
end

supervise("relay", "Deployment relay")
