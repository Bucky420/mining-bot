local arguments = { ... }

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
