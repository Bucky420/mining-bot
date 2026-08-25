local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local PROTOCOL = NETWORK_ID .. "/deployment/v1"
local PROJECT_ROOT = "/projects"
local STAGING_ROOT = "/.deployment-host-stage"
local BACKUP_ROOT = "/.deployment-host-backup"
local SCAN_SECONDS = 1
local STABLE_SECONDS = 3
local ANNOUNCE_SECONDS = 15

local targets = {}
local pendingCatalog
local pendingSince
local handleRelayUpload

local function enableMonitorOutput()
    local monitor = peripheral.find("monitor")
    if not monitor then return end
    pcall(monitor.setTextScale, 0.5)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    local oldPrint, oldWrite, oldError = print, write, printError
    local history = {}
    local function redraw()
        local width, height = monitor.getSize()
        monitor.clear()
        monitor.setCursorPos(1, 1)
        for _, value in ipairs(history) do
            local text = tostring(value)
            repeat
                local line = text:sub(1, width)
                text = text:sub(width + 1)
                local _, y = monitor.getCursorPos()
                if y > height then monitor.scroll(1) y = height end
                monitor.setCursorPos(1, y)
                monitor.write(line)
                monitor.setCursorPos(1, y + 1)
            until text == ""
        end
    end
    local function mirror(value)
        table.insert(history, tostring(value))
        table.insert(history, "")
        while #history > 200 do table.remove(history, 1) end
        redraw()
    end
    function print(...)
        local values = { ... }
        for index, value in ipairs(values) do values[index] = tostring(value) end
        local text = table.concat(values, "\t")
        oldPrint(text)
        mirror(text)
    end
    function write(value)
        oldWrite(value)
        if #history == 0 then history[1] = "" end
        history[#history] = history[#history] .. tostring(value)
        redraw()
    end
    function printError(...)
        local values = { ... }
        for index, value in ipairs(values) do values[index] = tostring(value) end
        local text = table.concat(values, "\t")
        oldError(text)
        mirror("ERROR: " .. text)
    end
    return redraw
end

local refreshMonitor = enableMonitorOutput()

local function validName(value)
    return type(value) == "string" and value:match("^[%w_.-]+$") ~= nil
end

local function validDestination(path)
    return type(path) == "string" and path ~= "" and path:sub(1, 1) ~= "/"
        and not path:find("..", 1, true) and not path:find("\\", 1, true)
end

local function readFile(path)
    local handle, openError = fs.open(path, "r")
    if not handle then return nil, openError or "unable to open file" end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function hashText(values)
    local first, second = 5381, 52711
    for _, value in ipairs(values) do
        for index = 1, #value do
            local byte = value:byte(index)
            first = (first * 33 + byte) % 4294967296
            second = (second * 65599 + byte) % 4294967296
        end
    end
    return ("%08x%08x"):format(first, second)
end

local function loadTarget(project, target, directory)
    local manifestSource, readError = readFile(fs.combine(directory, "manifest.lua"))
    if not manifestSource then return nil, readError end
    local environment = {}
    local chunk, syntaxError = load(manifestSource, "@" .. fs.combine(directory, "manifest.lua"), "t", environment)
    if not chunk then return nil, syntaxError end
    local ok, definition = pcall(chunk)
    if not ok then return nil, definition end
    if type(definition) ~= "table" or type(definition.files) ~= "table" then
        return nil, "manifest.lua must return { files = {...} }"
    end

    local snapshot = { files = {}, manifest = {} }
    local revisionParts = { project, "\0", target, "\0" }
    local seen = {}
    for _, entry in ipairs(definition.files) do
        if type(entry) ~= "table" or type(entry.source) ~= "string"
            or not validDestination(entry.path) or seen[entry.path] then
            return nil, "manifest contains an unsafe or duplicate file entry"
        end
        if not validName(entry.source) then
            return nil, "manifest contains an unsafe source path"
        end
        local sourcePath = fs.combine(directory, entry.source)
        seen[entry.path] = true
        local contents, sourceError = readFile(sourcePath)
        if not contents then return nil, ("%s: %s"):format(entry.source, tostring(sourceError)) end
        if entry.path:sub(-4) == ".lua" then
            local luaChunk, luaError = load(contents, "@" .. entry.path, "t", _ENV)
            if not luaChunk then return nil, ("%s: %s"):format(entry.source, tostring(luaError)) end
        end
        snapshot.files[entry.path] = contents
        table.insert(snapshot.manifest, { path = entry.path, size = #contents })
        table.insert(revisionParts, entry.path .. "\0" .. contents .. "\0")
    end
    if #snapshot.manifest == 0 then return nil, "manifest contains no files" end
    snapshot.project = project
    snapshot.target = target
    snapshot.revision = hashText(revisionParts)
    return snapshot
end

local function scanProjects()
    local catalog = {}
    local errors = {}
    if not fs.exists(PROJECT_ROOT) then fs.makeDir(PROJECT_ROOT) end
    for _, project in ipairs(fs.list(PROJECT_ROOT)) do
        local projectPath = fs.combine(PROJECT_ROOT, project)
        if validName(project) and fs.isDir(projectPath) then
            for _, target in ipairs(fs.list(projectPath)) do
                local targetPath = fs.combine(projectPath, target)
                if validName(target) and fs.isDir(targetPath)
                    and fs.exists(fs.combine(targetPath, "manifest.lua")) then
                    local snapshot, targetError = loadTarget(project, target, targetPath)
                    local key = project .. "/" .. target
                    if snapshot then catalog[key] = snapshot
                    else errors[key] = targetError end
                end
            end
        end
    end
    local parts = {}
    for key, snapshot in pairs(catalog) do table.insert(parts, key .. "=" .. snapshot.revision) end
    table.sort(parts)
    return catalog, hashText(parts), errors
end

local function announce(snapshot)
    rednet.broadcast({
        type = "UPDATE_AVAILABLE",
        project = snapshot.project,
        target = snapshot.target,
        release = snapshot.revision,
        serverId = os.getComputerID(),
        authority = true,
    }, PROTOCOL)
end

local function checkForChanges()
    local catalog, catalogRevision, errors = scanProjects()
    for key, targetError in pairs(errors) do
        printError(("Rejected %s: %s"):format(key, tostring(targetError)))
        if targets[key] then catalog[key] = targets[key] end
    end
    local revisedParts = {}
    for key, snapshot in pairs(catalog) do table.insert(revisedParts, key .. "=" .. snapshot.revision) end
    table.sort(revisedParts)
    catalogRevision = hashText(revisedParts)
    local activeParts = {}
    for key, snapshot in pairs(targets) do table.insert(activeParts, key .. "=" .. snapshot.revision) end
    table.sort(activeParts)
    if catalogRevision == hashText(activeParts) then
        pendingCatalog = nil
        pendingSince = nil
        return
    end
    if not pendingCatalog or pendingCatalog.revision ~= catalogRevision then
        pendingCatalog = { targets = catalog, revision = catalogRevision }
        pendingSince = os.epoch("utc")
        print("Project changes detected; waiting for uploads to settle.")
        return
    end
    if os.epoch("utc") - pendingSince >= STABLE_SECONDS * 1000 then
        targets = catalog
        pendingCatalog = nil
        pendingSince = nil
        print("Activated deployment catalog " .. catalogRevision)
        for _, snapshot in pairs(targets) do announce(snapshot) end
    end
end

local function openModems()
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    return opened
end

local function requestedTarget(request)
    if type(request) ~= "table" or not validName(request.project) or not validName(request.target) then
        return nil
    end
    return targets[request.project .. "/" .. request.target]
end

local function installDeploymentUpdate(files, sender, nonceValue)
    if type(files["deploy_server.lua"]) ~= "string" or type(files["startup.lua"]) ~= "string" then
        return false
    end
    local stage = "/.deployment-self-update"
    if fs.exists(stage) then fs.delete(stage) end
    fs.makeDir(stage)
    for _, name in ipairs({ "deploy_server.lua", "startup.lua" }) do
        local handle, openError = fs.open(fs.combine(stage, name), "w")
        if not handle then
            fs.delete(stage)
            if sender then rednet.send(sender, { type = "ERROR", nonce = nonceValue, error = openError }, PROTOCOL) end
            return false
        end
        handle.write(files[name])
        handle.close()
    end
    if sender then
        rednet.send(sender, { type = "MASTER_UPDATE_RESULT", nonce = nonceValue, accepted = true }, PROTOCOL)
    end
    if fs.exists("/deploy_server.lua") then fs.delete("/deploy_server.lua") end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    fs.move(fs.combine(stage, "deploy_server.lua"), "/deploy_server.lua")
    fs.move(fs.combine(stage, "startup.lua"), "/startup.lua")
    fs.delete(stage)
    print("Deployment server updated. Rebooting...")
    sleep(1)
    os.reboot()
    return true
end

local function handleRequest(sender, request)
    if type(request) == "table" and request.type == "RELAY_UPLOAD" then
        handleRelayUpload(sender, request)
        return
    end
    if type(request) == "table" and request.type == "RELAY_MASTER_UPDATE" then
        installDeploymentUpdate(request.files or {}, sender, request.nonce)
        return
    end
    if type(request) == "table" and request.type == "DISCOVER_AUTHORITY" then
        rednet.send(sender, {
            type = "AUTHORITY_OFFER",
            nonce = request.nonce,
            authority = true,
            serverId = os.getComputerID(),
        }, PROTOCOL)
        return
    end
    local snapshot = requestedTarget(request)
    if not snapshot then return end
    if request.type == "DISCOVER" then
        rednet.send(sender, {
            type = "OFFER", nonce = request.nonce, project = snapshot.project,
            target = snapshot.target, release = snapshot.revision,
            serverId = os.getComputerID(), authority = true,
        }, PROTOCOL)
    elseif request.type == "GET_MANIFEST" then
        rednet.send(sender, {
            type = "MANIFEST", nonce = request.nonce, project = snapshot.project,
            target = snapshot.target, release = snapshot.revision, files = snapshot.manifest,
        }, PROTOCOL)
    elseif request.type == "GET_FILE" and type(request.path) == "string" then
        local contents = snapshot.files[request.path]
        rednet.send(sender, contents and {
            type = "FILE", nonce = request.nonce, release = snapshot.revision,
            path = request.path, contents = contents,
        } or {
            type = "ERROR", nonce = request.nonce, error = "file is not in target manifest",
        }, PROTOCOL)
    end
end

local function activateUpload(uploaded, sourceLabel)
    sourceLabel = sourceLabel or ""
    local descriptorSource = uploaded["upload.lua"]
    local descriptor
    if descriptorSource then
        local descriptorChunk, descriptorError = load(descriptorSource, "@upload.lua", "t", {})
        if not descriptorChunk then
            printError(("Upload rejected%s: %s"):format(sourceLabel, tostring(descriptorError)))
            return false
        end
        local ok, loadedDescriptor = pcall(descriptorChunk)
        if ok then descriptor = loadedDescriptor end
    elseif uploaded["manifest.lua"] and uploaded["worker.lua"] then
        descriptor = { project = "mining-bot", target = "turtle" }
        print("upload.lua missing; inferred mining-bot/turtle from worker.lua")
    elseif uploaded["manifest.lua"] and uploaded["controller.lua"] then
        descriptor = { project = "mining-bot", target = "controller" }
        print("upload.lua missing; inferred mining-bot/controller from controller.lua")
    else
        local names = {}
        for name in pairs(uploaded) do table.insert(names, name) end
        table.sort(names)
        printError(("Upload rejected%s: missing upload.lua. Received: %s"):format(
            sourceLabel, table.concat(names, ", ")
        ))
        return false
    end
    if type(descriptor) ~= "table" or not validName(descriptor.project)
        or not validName(descriptor.target) then
        printError(("Upload rejected%s: invalid project/target descriptor"):format(sourceLabel))
        return false
    end
    local destination = fs.combine(PROJECT_ROOT, descriptor.project)
    destination = fs.combine(destination, descriptor.target)
    local stage = fs.combine(STAGING_ROOT, descriptor.project)
    local backup = fs.combine(BACKUP_ROOT, descriptor.project)
    stage = fs.combine(stage, descriptor.target)
    backup = fs.combine(backup, descriptor.target)
    if fs.exists(stage) then fs.delete(stage) end
    if fs.exists(destination) then fs.copy(destination, stage) else fs.makeDir(stage) end
    local count = 0
    for name, contents in pairs(uploaded) do
        if name ~= "upload.lua" then
            if not validName(name) then
                printError(("Skipped unsafe upload filename%s: %s"):format(sourceLabel, tostring(name)))
            else
                local handle, openError = fs.open(fs.combine(stage, name), "wb")
                if not handle then
                    printError(("Cannot save %s%s: %s"):format(name, sourceLabel, tostring(openError)))
                    fs.delete(stage)
                    return false
                else
                    handle.write(contents)
                    handle.close()
                    count = count + 1
                end
            end
        end
    end
    local candidate, candidateError = loadTarget(descriptor.project, descriptor.target, stage)
    if not candidate then
        printError(("Upload rejected%s before activation: %s"):format(sourceLabel, tostring(candidateError)))
        fs.delete(stage)
        return false
    end
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(destination) then fs.move(destination, backup) end
    fs.move(stage, destination)
    if fs.exists(backup) then fs.delete(backup) end
    print(("Uploaded %d files to %s%s"):format(
        count, descriptor.project, descriptor.target and ("/" .. descriptor.target) or ""
    ))
    return true
end

local function handleTransfer(transfer)
    local uploaded = {}
    for _, file in ipairs(transfer.getFiles()) do
        local name = fs.getName(file.getName())
        uploaded[name] = file.readAll()
        file.close()
    end
    if uploaded["deploy_server.lua"] and uploaded["startup.lua"] and not uploaded["upload.lua"] then
        installDeploymentUpdate(uploaded)
        return
    end
    activateUpload(uploaded, " from local drag-and-drop")
end

handleRelayUpload = function(sender, request)
    if type(request.files) ~= "table" then return end
    local uploaded = {}
    for name, contents in pairs(request.files) do
        if type(name) == "string" and type(contents) == "string" then
            uploaded[name] = contents
        end
    end
    local accepted = activateUpload(uploaded, (" from relay %d"):format(sender))
    rednet.send(sender, {
        type = "RELAY_UPLOAD_RESULT", nonce = request.nonce, accepted = accepted,
    }, PROTOCOL)
end

local function recoverHostTransactions()
    if not fs.exists(BACKUP_ROOT) then return end
    for _, project in ipairs(fs.list(BACKUP_ROOT)) do
        local projectBackup = fs.combine(BACKUP_ROOT, project)
        if fs.isDir(projectBackup) then
            for _, target in ipairs(fs.list(projectBackup)) do
                local backup = fs.combine(projectBackup, target)
                local destination = fs.combine(fs.combine(PROJECT_ROOT, project), target)
                if fs.isDir(backup) then
                    if not fs.exists(destination) then
                        local parent = fs.getDir(destination)
                        if not fs.exists(parent) then fs.makeDir(parent) end
                        fs.move(backup, destination)
                    else
                        fs.delete(backup)
                    end
                end
            end
        end
    end
end

if not openModems() then error("Deployment server requires an attached modem", 0) end
recoverHostTransactions()
local initial, _, initialErrors = scanProjects()
targets = initial
for key, targetError in pairs(initialErrors) do
    printError(("Rejected %s: %s"):format(key, tostring(targetError)))
end

print(("Generic deployment computer ID: %d"):format(os.getComputerID()))
print("Network: " .. NETWORK_ID)
print("Watching /projects/<project>/<target>/ for stable changes.")

for _, snapshot in pairs(targets) do announce(snapshot) end
local scanTimer = os.startTimer(SCAN_SECONDS)
local announceTimer = os.startTimer(ANNOUNCE_SECONDS)
while true do
    local event, first, second, third = os.pullEvent()
    if event == "monitor_resize" and refreshMonitor then
        refreshMonitor()
    elseif event == "rednet_message" and third == PROTOCOL then
        handleRequest(first, second)
    elseif event == "file_transfer" then
        handleTransfer(first)
    elseif event == "timer" and first == scanTimer then
        checkForChanges()
        scanTimer = os.startTimer(SCAN_SECONDS)
    elseif event == "timer" and first == announceTimer then
        for _, snapshot in pairs(targets) do announce(snapshot) end
        announceTimer = os.startTimer(ANNOUNCE_SECONDS)
    end
end
