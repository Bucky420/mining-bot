local NETWORK_ID = tostring(settings.get("bucky.network", "bucky"))
local PROTOCOL = NETWORK_ID .. "/deployment/v1"
local PROJECT = "mining-bot"
local TARGET = turtle and "turtle" or "controller"
local TIMEOUT = 8
local STAGE = "/.deployment-stage"
local FILE_TEMP = "/.deployment-file.tmp"
local BACKUP = "/.deployment-backup"
local INSTALLING = "/.deployment-installing"
local DEPLOYMENT_STATE = "/data/deployment.state"

local function cleanupLowWorkerSpace()
    if TARGET ~= "turtle" or type(fs.getFreeSpace) ~= "function" then return end
    local free = fs.getFreeSpace("/")
    if type(free) ~= "number" or free >= 32768 then return end
    for _, path in ipairs({ "/data/worker.log.old", "/data/worker.log" }) do
        if fs.exists(path) then fs.delete(path) end
        if fs.getFreeSpace("/") >= 32768 then break end
    end
end

cleanupLowWorkerSpace()

local modemItems = {
    ["computercraft:wireless_modem_normal"] = true,
    ["computercraft:wireless_modem_advanced"] = true,
}

local function safeDestination(path)
    return type(path) == "string" and path ~= "" and path ~= "startup.lua"
        and path:sub(1, 1) ~= "/" and not path:find("..", 1, true)
        and not path:find("\\", 1, true) and not path:match("^data/")
        and not path:match("^%.deployment")
end

local function detachedCopy(value, ancestors)
    if type(value) ~= "table" then return value end
    ancestors = ancestors or {}
    if ancestors[value] then return "<cyclic table>" end
    ancestors[value] = true
    local result = {}
    for key, item in pairs(value) do
        result[detachedCopy(key, ancestors)] = detachedCopy(item, ancestors)
    end
    ancestors[value] = nil
    return result
end

local function readTable(path)
    for _, candidate in ipairs({ path, path .. ".tmp", path .. ".previous" }) do
        if fs.exists(candidate) then
            local handle = fs.open(candidate, "r")
            if handle then
                local value = textutils.unserialize(handle.readAll())
                handle.close()
                if type(value) == "table" then return value end
            end
        end
    end
    return nil
end

local function writeTable(path, value)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local temporary = path .. ".tmp"
    if fs.exists(temporary) then fs.delete(temporary) end
    local handle, openError = fs.open(temporary, "w")
    if not handle then return false, openError end
    handle.write(textutils.serialize(detachedCopy(value), { compact = true }))
    handle.close()
    local previous = path .. ".previous"
    if fs.exists(previous) then fs.delete(previous) end
    if fs.exists(path) then
        fs.move(path, previous)
    end
    fs.move(temporary, path)
    if fs.exists(previous) then fs.delete(previous) end
    return true
end

local function pathSet(paths)
    local result = {}
    for _, path in ipairs(paths or {}) do result[path] = true end
    return result
end

local function rollback(interrupted)
    local existingFiles = pathSet(interrupted.existingFiles or interrupted.previousFiles)
    local affected = {}
    for _, path in ipairs(interrupted.newFiles or {}) do affected[path] = true end
    for _, path in ipairs(interrupted.previousFiles or {}) do affected[path] = true end
    for path in pairs(affected) do
        local destination = "/" .. path
        local backup = fs.combine(BACKUP, path)
        if fs.exists(backup) then
            if fs.exists(destination) then fs.delete(destination) end
            local parent = fs.getDir(destination)
            if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
            fs.move(backup, destination)
        elseif not existingFiles[path] and fs.exists(destination) then
            fs.delete(destination)
        end
    end
    if interrupted.previousState then
        local ok, restoreError = writeTable(DEPLOYMENT_STATE, interrupted.previousState)
        if not ok then error("Cannot restore deployment state: " .. tostring(restoreError), 0) end
    else
        for _, path in ipairs({
            DEPLOYMENT_STATE, DEPLOYMENT_STATE .. ".tmp", DEPLOYMENT_STATE .. ".previous",
        }) do
            if fs.exists(path) then fs.delete(path) end
        end
    end
    if fs.exists(BACKUP) then fs.delete(BACKUP) end
    if fs.exists(STAGE) then fs.delete(STAGE) end
    if fs.exists(FILE_TEMP) then fs.delete(FILE_TEMP) end
    if fs.exists(INSTALLING) then fs.delete(INSTALLING) end
    if fs.exists(INSTALLING .. ".tmp") then fs.delete(INSTALLING .. ".tmp") end
    printError("Rolled back an interrupted deployment before startup.")
end

local function nonce(suffix)
    return ("%d:%d:%s"):format(os.getComputerID(), os.epoch("utc"), suffix or "")
end

local function ensureModem()
    if peripheral.find("modem") then return true end
    if not turtle then return false, "no modem is attached" end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and modemItems[detail.name] then
            local previous = turtle.getSelectedSlot()
            turtle.select(slot)
            local equipped, equipError = turtle.equipRight()
            turtle.select(previous)
            if not equipped then return false, equipError or "unable to equip modem" end
            return peripheral.find("modem") ~= nil, "equipped item is not a modem"
        end
    end
    return false, "no wireless modem is attached or present in inventory"
end

local function openModems()
    local ok, modemError = ensureModem()
    if not ok then return false, modemError end
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    return opened, opened and nil or "unable to open modem"
end

local function receiveFrom(serverId, expectedType, requestNonce)
    local timer = os.startTimer(TIMEOUT)
    while true do
        local event, first, second, third = os.pullEvent()
        if event == "timer" and first == timer then return nil, "deployment request timed out" end
        if event == "rednet_message" and first == serverId and third == PROTOCOL
            and type(second) == "table" and second.nonce == requestNonce then
            if second.type == "ERROR" then return nil, second.error or "deployment server error" end
            if second.type == expectedType then return second end
        end
    end
end

local function discoverServer()
    local requestNonce = nonce("discover")
    rednet.broadcast({
        type = "DISCOVER", nonce = requestNonce, project = PROJECT, target = TARGET,
    }, PROTOCOL)
    local timer = os.startTimer(TIMEOUT)
    local offers = {}
    while true do
        local event, first, second, third = os.pullEvent()
        if event == "timer" and first == timer then
            local count, selected, authoritative = 0, nil, nil
            for id, offer in pairs(offers) do
                count = count + 1
                selected = selected or id
                if offer.authority then authoritative = id end
            end
            if authoritative then return authoritative end
            if count == 1 then return selected end
            if count == 0 then return nil, "no deployment server hosts " .. PROJECT .. "/" .. TARGET end
            return selected
        end
        if event == "rednet_message" and third == PROTOCOL and type(second) == "table"
            and second.type == "OFFER" and second.nonce == requestNonce then
            if next(offers) == nil then timer = os.startTimer(1) end
            offers[first] = second
        end
    end
end

local function stageFile(contents)
    if fs.exists(FILE_TEMP) then fs.delete(FILE_TEMP) end
    local handle, openError = fs.open(FILE_TEMP, "w")
    if not handle then return false, openError end
    handle.write(contents)
    handle.close()
    return true
end

local function receiveUpdateAnnouncement(installedRelease)
    -- Never swap turtle upgrades from the supervisor. The worker restores its
    -- modem when it is safe for networking to resume.
    if not peripheral.find("modem") then sleep(1) return nil end
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened = true
        end
    end
    if not opened then return nil end
    local _, message = rednet.receive(PROTOCOL, 1)
    if type(message) == "table" and message.type == "UPDATE_AVAILABLE"
        and message.project == PROJECT and message.target == TARGET
        and type(message.release) == "string" and message.release ~= installedRelease then
        return message.release
    end
    return nil
end

local function launchInstalledApplication(installedRelease)
    local application = TARGET == "turtle" and "/worker.lua" or "/controller.lua"
    local applicationRunning = true
    local acknowledgedRelease
    parallel.waitForAll(
        function()
            local applicationOk = shell.run(application)
            applicationRunning = false
            os.queueEvent("bucky_application_stopped")
            if not applicationOk then printError("Application stopped with an error: " .. application) end
        end,
        function()
            while applicationRunning do
                local release = receiveUpdateAnnouncement(installedRelease)
                if release and release ~= acknowledgedRelease then
                    os.queueEvent("bucky_deployment_update", release)
                end
            end
        end,
        function()
            while applicationRunning do
                local _, release = os.pullEvent("bucky_deployment_update_ack")
                acknowledgedRelease = release
            end
        end
    )
end

local interrupted = readTable(INSTALLING)
if interrupted then rollback(interrupted) end
if not interrupted then
    -- A download can fail before the installation marker is written. Those
    -- files are never installed and must not survive into the next boot.
    if fs.exists(STAGE) then fs.delete(STAGE) end
    if fs.exists(FILE_TEMP) then fs.delete(FILE_TEMP) end
end
if fs.exists(BACKUP) then fs.delete(BACKUP) end
local saved = readTable(DEPLOYMENT_STATE)
interrupted = nil
if saved and not saved.files then
    if TARGET == "turtle" then
        saved.files = {
            "worker.lua", "config.lua",
            "lib/util.lua", "lib/state.lua", "lib/inventory.lua", "lib/nav.lua",
            "lib/map.lua", "lib/markers.lua", "lib/network.lua", "lib/jobs.lua",
            "lib/scanner.lua", "lib/station.lua",
            "jobs/travel.lua", "jobs/dig_tunnel.lua", "jobs/repair_marker.lua",
            "jobs/survey_area.lua", "jobs/farm_crop.lua", "jobs/configure_site.lua",
        }
    else
        saved.files = { "controller.lua" }
    end
end
local modemOk, modemError = openModems()
if not modemOk then
    if saved and not interrupted then
        printError("Update check unavailable: " .. tostring(modemError))
        launchInstalledApplication(saved and saved.release)
        return
    end
    error("Installer requires a modem: " .. tostring(modemError), 0)
end

local serverId, discoveryError = discoverServer()
if not serverId then
    if saved and not interrupted then
        printError("Deployment master offline: " .. tostring(discoveryError))
        launchInstalledApplication(saved and saved.release)
        return
    end
    error(discoveryError, 0)
end

local manifestNonce = nonce("manifest")
rednet.send(serverId, {
    type = "GET_MANIFEST", nonce = manifestNonce, project = PROJECT, target = TARGET,
}, PROTOCOL)
local manifest, manifestError = receiveFrom(serverId, "MANIFEST", manifestNonce)
if not manifest then
    if saved and not interrupted then
        printError("Update check unavailable: " .. tostring(manifestError))
        launchInstalledApplication(saved and saved.release)
        return
    end
    error("Manifest request failed: " .. tostring(manifestError), 0)
end
if saved and not interrupted and saved.project == PROJECT and saved.target == TARGET
    and saved.release == manifest.release then
    print(("%s/%s is current (%s)."):format(PROJECT, TARGET, manifest.release))
    if fs.getName(shell.getRunningProgram()) == "startup.lua" then
        launchInstalledApplication(saved and saved.release)
    end
    return
end
if type(manifest.files) ~= "table" or #manifest.files == 0 then
    error("Deployment manifest is empty", 0)
end

local manifestPaths = {}
local nextPaths, existingPaths, affectedPaths = {}, {}, {}
for index, entry in ipairs(manifest.files) do
    if type(entry) ~= "table" or not safeDestination(entry.path) or manifestPaths[entry.path]
        or type(entry.size) ~= "number" then
        error("Deployment manifest contains an unknown or duplicate path", 0)
    end
    manifestPaths[entry.path] = true
    table.insert(nextPaths, entry.path)
    affectedPaths[entry.path] = true
end
for _, path in ipairs(saved and saved.files or {}) do affectedPaths[path] = true end
for path in pairs(affectedPaths) do
    if fs.exists("/" .. path) then table.insert(existingPaths, path) end
end

local markerOk, markerError = writeTable(INSTALLING, {
    serverId = serverId,
    project = PROJECT,
    target = TARGET,
    release = manifest.release,
    previousState = saved,
    previousFiles = saved and saved.files or {},
    existingFiles = existingPaths,
    newFiles = nextPaths,
})
if not markerOk then error("Cannot create installation marker: " .. tostring(markerError), 0) end

local function installDownloaded(path)
    local destination = "/" .. path
    local backup = fs.combine(BACKUP, path)
    local parent = fs.getDir(destination)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    if fs.exists(destination) then
        local backupParent = fs.getDir(backup)
        if backupParent ~= "" and not fs.exists(backupParent) then fs.makeDir(backupParent) end
        fs.move(destination, backup)
    end
    fs.move(FILE_TEMP, destination)
end

for index, entry in ipairs(manifest.files) do
    write(("Downloading %d/%d %s... "):format(index, #manifest.files, entry.path))
    local fileNonce = nonce("file:" .. index)
    rednet.send(serverId, {
        type = "GET_FILE", nonce = fileNonce, project = PROJECT, target = TARGET, path = entry.path,
    }, PROTOCOL)
    local response, fileError = receiveFrom(serverId, "FILE", fileNonce)
    if not response then error("Download failed: " .. tostring(fileError), 0) end
    if response.release ~= manifest.release or response.path ~= entry.path
        or type(response.contents) ~= "string" or #response.contents ~= entry.size then
        error("Deployment changed during download; retry after uploads settle", 0)
    end
    if entry.path:sub(-4) == ".lua" then
        local chunk, syntaxError = load(response.contents, "@/" .. entry.path, "t", _ENV)
        if not chunk then error(("Invalid %s: %s"):format(entry.path, syntaxError), 0) end
    end
    local wrote, writeError = stageFile(response.contents)
    if not wrote then error(("Cannot stage %s: %s"):format(entry.path, tostring(writeError)), 0) end
    installDownloaded(entry.path)
    print("ok")
end

local newFiles = {}
for _, entry in ipairs(manifest.files) do
    local path = entry.path
    newFiles[path] = true
end
for _, path in ipairs(saved and saved.files or {}) do
    if not newFiles[path] then
        local destination = "/" .. path
        if fs.exists(destination) then
            local backup = fs.combine(BACKUP, path)
            local backupParent = fs.getDir(backup)
            if backupParent ~= "" and not fs.exists(backupParent) then fs.makeDir(backupParent) end
            fs.move(destination, backup)
            fs.delete(destination)
        end
    end
end

local installedFiles = {}
for _, entry in ipairs(manifest.files) do table.insert(installedFiles, entry.path) end
local stateOk, stateError = writeTable(DEPLOYMENT_STATE, {
    serverId = serverId,
    project = PROJECT,
    target = TARGET,
    release = manifest.release,
    files = installedFiles,
})
if not stateOk then error("Cannot save deployment state: " .. tostring(stateError), 0) end
fs.delete(STAGE)
if fs.exists(FILE_TEMP) then fs.delete(FILE_TEMP) end
fs.delete(INSTALLING)
if fs.exists(BACKUP) then fs.delete(BACKUP) end
print(("Installed %s/%s revision %s."):format(PROJECT, TARGET, manifest.release))
sleep(1)
os.reboot()
