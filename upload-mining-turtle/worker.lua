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

local map = require("lib.map")
local markers = require("lib.markers")
local nav = require("lib.nav")
local network = require("lib.network")
local state = require("lib.state")
local util = require("lib.util")
local config = require("config")
local jobs = require("lib.jobs")
local inventory = require("lib.inventory")

jobs.register("TRAVEL", require("jobs.travel"))
jobs.register("DIG_TUNNEL", require("jobs.dig_tunnel"))
jobs.register("REPAIR_MARKER", require("jobs.repair_marker"))
jobs.register("SURVEY_AREA", require("jobs.survey_area"))
jobs.register("FARM_CROP", require("jobs.farm_crop"))
jobs.register("FARM_SERVICE", require("jobs.farm_service"))
jobs.register("CONFIGURE_SITE", require("jobs.configure_site"))

local arguments = { ... }
local jobExecuting = false
local navigationReady = false
local navigationError
local idlePromptVisible = false
local rejectedJobIds = {}
local rejectedJobOrder = {}
local attemptNavigation
local validDirections = { north = true, east = true, south = true, west = true }

local function usage()
    print("Commands:")
    print("  travel <x> <y> <z> | travel <node-id>")
    print("  dig <north|east|south|west> <length> [profile]")
    print("  repair <x> <y> <z> <JUNCTION|END|BUILD|PROFILE_CHANGE>")
    print("  survey [radius] [exact-block-name]")
    print("  farm <farm-id> [mature-age] [seed-name]")
    print("  farm-service start [radius] | stop | status")
    print("  farm-expand [on|off|toggle] | farm-radius <radius>")
    print("  tunnel <tunnel-id> <length>")
    print("  setup station <id> <supply-direction> <output-direction>")
    print("  setup farm <id> <width> <length> <direction> <crop> <seed> [mature-age] <station-id>")
    print("  setup tunnel <id> <direction> <width> <height>")
    print("  setup room <id> <type> <direction> <width> <length> <height>")
    print("  inspect down | inspect front | inspect item [slot]")
    print("  sites | profiles | markers")
    print("  node add <id> <x> <y> <z> <type> [profile]")
    print("  edge add <id> <from> <to> <direction> <length> [profile]")
    print("  setup | fuel | status | tasks | retry | retry now | cancel | recover | help | quit")
end

local function onboarding()
    local data = state.get()
    local fuel = turtle.getFuelLevel()
    print(("Turtle %d at %s; fuel: %s"):format(
        data.turtleId,
        data.position and ("%d,%d,%d"):format(data.position.x, data.position.y, data.position.z) or "unknown position",
        tostring(fuel)
    ))
    if not navigationReady then
        print("Navigation setup is incomplete: " .. tostring(
            navigationError or data.navigationError or data.statusDetail or "unknown reason"
        ))
        print("Add/select fuel and run 'refuel all' if needed, clear one horizontal path, then type 'setup'.")
        print("Available now: setup | fuel | status | help | quit")
    elseif map.getRevision() == 0 then
        print("No tunnel map or job is configured yet.")
        print("For flax, add scanner/tool/seeds/fuel and use 'farm flax'.")
        print("For mining, use 'dig <direction> <length> [profile]' or wait for the controller.")
        print("Profiles: service=1x2, normal=3x3, trunk=5x3; jobs may override width/height.")
    else
        print("No job assigned; waiting for a local command or controller assignment.")
    end
end

local function integer(value, name)
    local parsed, parseError = util.parseInteger(value, name)
    if not parsed then printError(parseError) end
    return parsed
end

local function assign(jobType, parameters)
    local job, createError = jobs.create(jobType, parameters)
    if not job then printError(createError) return false end
    local ok, assignError = jobs.assign(job)
    if not ok then printError(assignError) return false end
    return true
end

local function applyFarmControl(action, parameters)
    local data = state.get()
    local job = data.currentJob
    parameters = parameters or {}
    if action == "farm_status" then
        if parameters.jobId and job and parameters.jobId ~= job.id then
            return false, "STALE_FARM_CONTROL"
        end
        local target = job and job.type == "FARM_SERVICE" and job or data.lastJob
        if not target or target.type ~= "FARM_SERVICE" then return false, "NO_FARM_SERVICE" end
        return true, textutils.serialize(util.detachedCopy({
            id = target.id,
            status = target.status,
            phase = target.progress and target.progress.phase,
            radius = target.progress and target.progress.radius or target.parameters and target.parameters.radius,
            autoExpand = target.progress and target.progress.autoExpand,
            cycle = target.progress and target.progress.cycle,
            summary = target.progress and target.progress.planSummary,
            alerts = target.progress and target.progress.alerts,
        }))
    end
    if not job or job.type ~= "FARM_SERVICE" then return false, "NO_ACTIVE_FARM_SERVICE" end
    if parameters.jobId and parameters.jobId ~= job.id then return false, "STALE_FARM_CONTROL" end
    if action == "farm_cancel" then return jobs.cancelCurrent() end
    if action == "farm_expand" then
        local enabled = parameters.autoExpand
        if enabled == nil then enabled = not (job.progress.autoExpand ~= false) end
        job.parameters.autoExpand = enabled
        job.progress.autoExpand = enabled
        if job.progress.farm then job.progress.farm.autoExpand = enabled end
        if enabled then job.progress.forceSurvey = true end
        if job.progress.farm then
            local saved, saveError = map.addNode(job.progress.farm)
            if not saved then return false, "FARM_MAP_SAVE_FAILED: " .. tostring(saveError) end
        end
        state.save()
        return true, enabled and "enabled" or "disabled"
    end
    if action == "farm_radius" then
        local radius = tonumber(parameters.radius)
        if not radius or radius ~= math.floor(radius) or radius < 1 or radius > 32 then
            return false, "FARM_RADIUS_MUST_BE_1_TO_32"
        end
        job.parameters.radius = radius
        job.progress.radius = radius
        if job.progress.farm then job.progress.farm.radius = radius end
        job.progress.surveyComplete = false
        job.progress.forceSurvey = true
        if job.progress.farm then
            local saved, saveError = map.addNode(job.progress.farm)
            if not saved then return false, "FARM_MAP_SAVE_FAILED: " .. tostring(saveError) end
        end
        state.save()
        return true, tostring(radius)
    end
    return false, "UNKNOWN_FARM_CONTROL"
end

local function printStatus()
    local data = state.get()
    print(textutils.serialize(util.detachedCopy({
        turtleId = data.turtleId,
        status = data.status,
        statusDetail = data.statusDetail,
        position = data.position,
        heading = data.heading,
        home = data.home,
        currentJob = data.currentJob,
        lastJob = data.lastJob,
        lastError = data.lastError,
        mapRevision = map.getRevision(),
    })))
end

local function handle(tokens)
    local command = string.lower(tokens[1] or "")
    if command == "" then return true end
    if command == "help" then usage() return true end
    if command == "status" then printStatus() return true end
    if command == "fuel" then
        print(("Fuel: %s / %s"):format(tostring(turtle.getFuelLevel()), tostring(turtle.getFuelLimit())))
        return true
    end
    if command == "sites" then print(textutils.serialize(map.getNodes())) return true end
    if command == "profiles" then print(textutils.serialize(require("config").profiles)) return true end
    if command == "markers" then
        local config = require("config")
        print(textutils.serialize({ types = config.markers, pattern = config.markerPattern }))
        return true
    end
    if (command == "setup" and not tokens[2]) or command == "calibrate" then
        attemptNavigation(false)
        onboarding()
        return true
    end
    if command == "tasks" then
        print(textutils.serialize(util.detachedCopy(state.get().pendingTasks)))
        return true
    end
    if command == "recover" then
        attemptNavigation(true)
        onboarding()
        return true
    end
    if command == "quit" or command == "exit" then return false end
    if command == "cancel" then
        local ok, cancelError = jobs.cancelCurrent()
        if ok then print(jobExecuting and "Cancellation requested" or "Current job cancelled")
        else printError(cancelError) end
        return true
    end
    if command == "retry" then
        if not tokens[2] then
            local data = state.get()
            data.autoRetry = not data.autoRetry
            state.save()
            print("Automatic retry " .. (data.autoRetry and "enabled" or "disabled"))
            return true
        end
        if tokens[2] == "now" then
            local ok, retryError = jobs.retryFailed()
            if not ok then printError(retryError) end
            return true
        end
        if tokens[2] == "on" or tokens[2] == "off" or tokens[2] == "status" then
            local data = state.get()
            if tokens[2] == "status" then
                print("Automatic retry " .. (data.autoRetry and "enabled" or "disabled"))
            else
                data.autoRetry = tokens[2] == "on"
                state.save()
                print("Automatic retry " .. (data.autoRetry and "enabled" or "disabled"))
            end
            return true
        end
        local ok, retryError = jobs.retryFailed()
        if not ok then printError(retryError) end
        return true
    end
    if not navigationReady and (command == "travel" or command == "dig" or command == "repair"
        or command == "survey" or command == "farm" or command == "farm-service"
        or command == "farm-expand" or command == "farm-radius"
        or command == "tunnel" or command == "setup") then
        printError("Navigation is not ready. Fix the reported problem and type 'setup'.")
        return true
    end
    if command == "travel" then
        if tokens[3] == nil then
            if not tokens[2] then printError("travel requires coordinates or a node ID") return true end
            assign("TRAVEL", { nodeId = tokens[2] })
        else
            local x, y, z = integer(tokens[2], "x"), integer(tokens[3], "y"), integer(tokens[4], "z")
            if x and y and z then assign("TRAVEL", { x = x, y = y, z = z }) end
        end
        return true
    end
    if command == "dig" then
        local length = integer(tokens[3], "length")
        if tokens[2] and length then
            assign("DIG_TUNNEL", { direction = tokens[2], length = length, profile = tokens[4] })
        end
        return true
    end
    if command == "repair" then
        local x, y, z = integer(tokens[2], "x"), integer(tokens[3], "y"), integer(tokens[4], "z")
        if x and y and z and tokens[5] then
            assign("REPAIR_MARKER", { position = { x = x, y = y, z = z }, markerType = string.upper(tokens[5]) })
        end
        return true
    end
    if command == "survey" then
        local radius = tokens[2] and integer(tokens[2], "radius") or nil
        if not tokens[2] or radius then
            assign("SURVEY_AREA", { radius = radius, blockFilter = tokens[3] })
        end
        return true
    end
    if command == "inspect" then
        local direction = string.lower(tokens[2] or "front")
        local present, detail
        if direction == "item" then
            detail = turtle.getItemDetail(tonumber(tokens[3]) or turtle.getSelectedSlot(), true)
            print(detail and textutils.serialize(detail) or "No item found")
            return true
        elseif direction == "down" then present, detail = turtle.inspectDown()
        elseif direction == "up" then present, detail = turtle.inspectUp()
        else present, detail = turtle.inspect() end
        print(present and textutils.serialize(detail) or "No block found")
        return true
    end
    if command == "farm" then
        if not tokens[2] then printError("farm requires a configured farm ID")
        else
            local age = tokens[3] and integer(tokens[3], "mature age") or nil
            if not tokens[3] or age then
                assign("FARM_CROP", { farmId = tokens[2], matureAge = age, seed = tokens[4] })
            end
        end
        return true
    end
    if command == "farm-service" then
        local operation = string.lower(tokens[2] or "status")
        if operation == "start" then
            local radius = tokens[3] and integer(tokens[3], "radius") or config.farming.serviceRadius
            if radius and radius >= 1 and radius <= 32 then
                assign("FARM_SERVICE", { radius = radius, autoExpand = true })
            elseif radius then printError("farm service radius must be 1 to 32") end
        elseif operation == "stop" then
            local ok, controlError = applyFarmControl("farm_cancel")
            if not ok then printError(controlError) end
        elseif operation == "status" then
            local ok, detail = applyFarmControl("farm_status")
            if ok then print(detail) else printError(detail) end
        else printError("farm-service start [radius] | stop | status") end
        return true
    end
    if command == "farm-expand" then
        local value = string.lower(tokens[2] or "toggle")
        if value ~= "on" and value ~= "off" and value ~= "toggle" then
            printError("farm-expand [on|off|toggle]")
        else
            local parameters = {}
            if value ~= "toggle" then parameters.autoExpand = value == "on" end
            local ok, detail = applyFarmControl("farm_expand", parameters)
            if ok then print("Automatic farm expansion " .. detail) else printError(detail) end
        end
        return true
    end
    if command == "farm-radius" then
        local radius = integer(tokens[2], "radius")
        if radius then
            local ok, detail = applyFarmControl("farm_radius", { radius = radius })
            if ok then print("Farm radius set to " .. detail) else printError(detail) end
        end
        return true
    end
    if command == "tunnel" then
        local node = map.getNode(tokens[2])
        local length = integer(tokens[3], "length")
        if not node or node.type ~= "tunnel_entrance" then printError("Unknown tunnel entrance")
        elseif length then
            assign("DIG_TUNNEL", {
                direction = node.direction, length = length,
                width = node.width, height = node.height, profile = node.profile,
            })
        end
        return true
    end
    if command == "setup" and tokens[2] == "station" then
        local position = nav.getPosition()
        if not tokens[3] or not tokens[4] or not tokens[5] then
            printError("setup station <id> <supply-direction> <output-direction>")
        elseif not validDirections[string.lower(tokens[4])] or not validDirections[string.lower(tokens[5])]
            or string.lower(tokens[4]) == string.lower(tokens[5]) then
            printError("Station requires two different cardinal chest directions")
        else
            local ok, addError = map.addNode({
                id = tokens[3], type = "service_station",
                x = position.x, y = position.y, z = position.z,
                supplyDirection = string.lower(tokens[4]), outputDirection = string.lower(tokens[5]),
                marker = "SERVICE",
            })
            if ok then
                print("Service station saved")
                if markers.inspectFloor().markerType ~= "SERVICE" then
                    print("Marker warning: place cyan wool under this cell, white wool inward, and black wool to its right.")
                end
            else printError(addError) end
        end
        return true
    end
    if command == "setup" and tokens[2] == "tunnel" then
        local position = nav.getPosition()
        local width, height = integer(tokens[5], "width"), integer(tokens[6], "height")
        if not tokens[3] or not tokens[4] or not width or not height then
            printError("setup tunnel <id> <direction> <width> <height>")
        elseif not validDirections[string.lower(tokens[4])] or width < 1 or height < 1 then
            printError("Tunnel direction or dimensions are invalid")
        else
            local ok, addError = map.addNode({
                id = tokens[3], type = "tunnel_entrance",
                x = position.x, y = position.y, z = position.z,
                direction = string.lower(tokens[4]), width = width, height = height,
                profile = "normal", marker = "MAIN_TUNNEL",
            })
            if ok then
                print("Tunnel entrance saved; use 'tunnel " .. tokens[3] .. " <length>'")
                if markers.inspectFloor().markerType ~= "MAIN_TUNNEL" then
                    print("Marker warning: place orange wool under this cell, white wool into the tunnel, and black wool to its right.")
                end
            else printError(addError) end
        end
        return true
    end
    if command == "setup" and tokens[2] == "room" then
        local position = nav.getPosition()
        local width = integer(tokens[6], "width")
        local length = integer(tokens[7], "length")
        local height = integer(tokens[8], "height")
        if not tokens[3] or not tokens[4] or not tokens[5] or not width or not length or not height then
            printError("setup room <id> <type> <direction> <width> <length> <height>")
        elseif not validDirections[string.lower(tokens[5])] or width < 1 or length < 1 or height < 1 then
            printError("Room direction or dimensions are invalid")
        else
            local ok, addError = map.addNode({
                id = tokens[3], type = "room", roomType = tokens[4], direction = string.lower(tokens[5]),
                x = position.x, y = position.y, z = position.z,
                width = width, length = length, height = height, marker = "ROOM",
            })
            if ok then
                print("Room saved")
                if markers.inspectFloor().markerType ~= "ROOM" then
                    print("Marker warning: place purple wool under this cell, white wool into the room, and black wool to its right.")
                end
            else printError(addError) end
        end
        return true
    end
    if command == "setup" and tokens[2] == "farm" then
        local position = nav.getPosition()
        local width, length = integer(tokens[4], "width"), integer(tokens[5], "length")
        local matureAge = tonumber(tokens[9])
        local stationId = tokens[10] or tokens[9]
        if not tokens[3] or not width or not length or not tokens[6] or not tokens[7] or not tokens[8] or not stationId then
            printError("setup farm <id> <width> <length> <direction> <crop> <seed> [mature-age] <station-id>")
        elseif not validDirections[string.lower(tokens[6])] or width < 1 or length < 1 or not map.getStation(stationId) then
            printError("Farm direction/dimensions are invalid or the station is unknown")
        else
            local ok, addError = map.addNode({
                id = tokens[3], type = "farm", x = position.x, y = position.y, z = position.z,
                width = width, length = length, direction = string.lower(tokens[6]),
                crop = tokens[7], seed = tokens[8], matureAge = matureAge, stationId = stationId,
                marker = nil,
            })
            if ok then print("Farm saved; use 'farm " .. tokens[3] .. "'") else printError(addError) end
        end
        return true
    end
    if command == "node" and tokens[2] == "add" then
        local x, y, z = integer(tokens[4], "x"), integer(tokens[5], "y"), integer(tokens[6], "z")
        if x and y and z then
            local ok, addError = map.addNode({ id=tokens[3], x=x, y=y, z=z, type=tokens[7], profile=tokens[8] })
            if not ok then printError(addError) else print("Node saved") end
        end
        return true
    end
    if command == "edge" and tokens[2] == "add" then
        local length = integer(tokens[7], "length")
        if length then
            local ok, addError = map.addEdge({
                id=tokens[3], from=tokens[4], to=tokens[5], direction=tokens[6], length=length, profile=tokens[8]
            })
            if not ok then printError(addError) else print("Edge saved") end
        end
        return true
    end
    printError("Unknown command: " .. tostring(tokens[1]))
    usage()
    return true
end

local function tokenize(line)
    local tokens = {}
    for token in tostring(line):gmatch("%S+") do table.insert(tokens, token) end
    return tokens
end

local function waitForAssignment()
    local line
    local remoteJob
    local remoteControl
    local remoteControlRelease
    local remoteControlParameters
    local controllerSender
    local updateRequested = false
    network.announce()
    parallel.waitForAny(
        function()
            if not idlePromptVisible then
                write("worker> ")
                idlePromptVisible = true
            end
            line = read()
            idlePromptVisible = false
        end,
        function()
            while not remoteJob and not remoteControl do
                local received, _, sender, control, controlRelease, controlParameters = network.receiveJob(1)
                if received then remoteJob, controllerSender = received, sender
                elseif control then
                    remoteControl, remoteControlRelease, remoteControlParameters, controllerSender =
                        control, controlRelease, controlParameters, sender
                else sleep(0.25) end
            end
        end,
        function()
            while not updateRequested do
                local release
                updateRequested, release = network.receiveDeploymentUpdate(1)
                if updateRequested then os.queueEvent("bucky_deployment_update_ack", release) end
                if not updateRequested then sleep(0.25) end
            end
        end,
        function()
            while not updateRequested do
                local _, release = os.pullEvent("bucky_deployment_update")
                if network.needsRelease(release) then
                    os.queueEvent("bucky_deployment_update_ack", release)
                    updateRequested = true
                end
            end
        end,
        function()
            while true do
                os.pullEvent("monitor_resize")
                if refreshMonitor then refreshMonitor() end
            end
        end
    )
    if updateRequested then
        state.setStatus("UPDATE_PENDING", "Idle worker accepted an update")
        network.report("WORKER_UPDATING", {
            result = "Update accepted at idle; rebooting now",
            job = state.get().currentJob,
        })
        print("Worker update available; rebooting before accepting another job.")
        sleep(1)
        os.reboot()
    end
    if remoteControl then
        state.get().controllerId = controllerSender
        state.save()
        local ok, controlError
        if remoteControl == "update" then
            if not network.needsRelease(remoteControlRelease) then return true end
            state.setStatus("UPDATE_PENDING", "Controller requested worker update")
            network.report("WORKER_UPDATING", {
                result = "Controller delivered a new release; rebooting now",
                job = state.get().currentJob,
            })
            sleep(1)
            os.reboot()
        end
                    if remoteControl == "retry" then ok, controlError = jobs.retryFailed()
                    elseif remoteControl == "retry_on" or remoteControl == "retry_off" then
                        state.get().autoRetry = remoteControl == "retry_on"
                        state.save()
                        ok = true
                    elseif remoteControl == "retry_toggle" then
                        state.get().autoRetry = not state.get().autoRetry
                        state.save()
                        ok = true
                        controlError = state.get().autoRetry and "enabled" or "disabled"
                    elseif remoteControl == "retry_status" then
                        ok = true
                        controlError = state.get().autoRetry and "enabled" or "disabled"
                    elseif remoteControl == "farm_status" or remoteControl == "farm_expand"
                        or remoteControl == "farm_radius" or remoteControl == "farm_cancel" then
                        ok, controlError = applyFarmControl(remoteControl, remoteControlParameters)
                    else ok, controlError = jobs.cancelCurrent() end
        network.report(ok and "CONTROL_ACCEPTED" or "CONTROL_REJECTED", {
            action = remoteControl,
            reason = controlError,
            job = state.get().currentJob or state.get().lastJob,
        })
        if not ok then
            if idlePromptVisible then print("") idlePromptVisible = false end
            printError("Remote " .. remoteControl .. " failed: " .. tostring(controlError))
        end
        return true
    end
    if remoteJob then
        state.get().controllerId = controllerSender
        state.save()
        if not navigationReady then
            local rejectedKey = remoteJob.id or (tostring(remoteJob.type) .. ":missing-id")
            if rejectedJobIds[rejectedKey] then return true end
            rejectedJobIds[rejectedKey] = true
            rejectedJobOrder[#rejectedJobOrder + 1] = rejectedKey
            while #rejectedJobOrder > 32 do
                rejectedJobIds[table.remove(rejectedJobOrder, 1)] = nil
            end
            if idlePromptVisible then print("") idlePromptVisible = false end
            local reason = "NAVIGATION_NOT_READY: " .. tostring(
                navigationError or state.get().navigationError or state.get().statusDetail or "unknown calibration failure"
            )
            printError("Rejected network job: " .. reason)
            network.report("JOB_REJECTED", {
                reason = reason,
                detail = navigationError,
                lastError = state.get().lastError,
                job = remoteJob,
            })
            return true
        end
        if idlePromptVisible then print("") idlePromptVisible = false end
        local ok, assignError = jobs.assign(remoteJob)
        if not ok then
            printError("Rejected network job: " .. tostring(assignError))
            network.report("JOB_REJECTED", { reason = assignError, job = remoteJob })
        else
            network.report("JOB_ACCEPTED", { id = remoteJob.id, type = remoteJob.type })
        end
        return true
    end
    return handle(tokenize(line))
end

local function runActiveJob(suppressInput)
    local success, result
    local updateRequested = false
    jobExecuting = true
    parallel.waitForAll(
        function()
            success, result = jobs.executeCurrent()
            jobExecuting = false
            os.queueEvent("mining_job_finished")
        end,
        function()
            if suppressInput then
                os.pullEvent("mining_job_finished")
                return
            end
            while jobExecuting do
                local line
                parallel.waitForAny(
                    function()
                        write("active job (status/cancel)> ")
                        line = read()
                    end,
                    function()
                        os.pullEvent("mining_job_finished")
                    end
                )
                if line then
                    local tokens = tokenize(line)
                    local command = string.lower(tokens[1] or "")
                    if command == "cancel" or command == "status" or command == "tasks"
                        or command == "farm-expand" or command == "farm-radius"
                        or command == "farm-service" then
                        handle(tokens)
                    elseif command ~= "" then
                        printError("Only status, tasks, or cancel is available while a job is active")
                    end
                end
            end
        end,
        function()
            while jobExecuting do
                local resized = false
                parallel.waitForAny(
                    function() os.pullEvent("monitor_resize") resized = true end,
                    function() os.pullEvent("mining_job_finished") end
                )
                if resized and refreshMonitor then refreshMonitor() end
            end
        end,
        function()
            while jobExecuting do
                local remoteJob, receiveError, sender, control, controlRelease, controlParameters = network.receiveJob(0.5, true)
                if control then
                    state.get().controllerId = sender
                    state.save()
                    local ok, controlError
                    local reportControl = true
                    if control == "update" then
                        if network.needsRelease(controlRelease) then
                            updateRequested = true
                            ok, controlError = jobs.requestUpdate()
                        else
                            ok = true
                            reportControl = false
                        end
                    elseif control == "cancel" then ok, controlError = jobs.cancelCurrent()
                    elseif control == "farm_status" or control == "farm_expand"
                        or control == "farm_radius" or control == "farm_cancel" then
                        ok, controlError = applyFarmControl(control, controlParameters)
                    else ok, controlError = false, "JOB_IS_RUNNING" end
                    if reportControl then
                        network.report(ok and "CONTROL_ACCEPTED" or "CONTROL_REJECTED", {
                            action = control,
                            reason = controlError,
                            job = state.get().currentJob or state.get().lastJob,
                        })
                    end
                elseif remoteJob then
                    state.get().controllerId = sender
                    state.save()
                    network.report("JOB_REJECTED", { reason = "JOB_IS_RUNNING", job = remoteJob })
                elseif receiveError and receiveError ~= "UNAUTHORIZED_CONTROLLER" then
                    printError("Network command rejected: " .. tostring(receiveError))
                end
            end
        end,
        function()
            while jobExecuting and not updateRequested do
                local available, release = network.receiveDeploymentUpdate(1)
                if available then
                    os.queueEvent("bucky_deployment_update_ack", release)
                    updateRequested = true
                    local requested, requestError = jobs.requestUpdate()
                    if requested then
                        print("Worker update received; pausing at the next safe checkpoint")
                    elseif requestError ~= "NO_RUNNING_JOB" then
                        printError("Could not pause for update: " .. tostring(requestError))
                    end
                else
                    sleep(0.25)
                end
            end
        end,
        function()
            while jobExecuting and not updateRequested do
                local _, release = os.pullEvent("bucky_deployment_update")
                if network.needsRelease(release) then
                    os.queueEvent("bucky_deployment_update_ack", release)
                    updateRequested = true
                    local requested, requestError = jobs.requestUpdate()
                    if requested then
                        print("Background updater requested a safe job checkpoint")
                    elseif requestError ~= "NO_RUNNING_JOB" then
                        printError("Could not pause for background update: " .. tostring(requestError))
                    end
                end
            end
        end
    )
    return success, result, updateRequested
end

state.load()
map.load()
if state.get().status == "UPDATE_PENDING" then
    state.setStatus("IDLE", "Update reboot completed")
    network.report("WORKER_REBOOTED", {
        result = "Update installed; reboot complete; queued job will resume",
        job = state.get().currentJob,
    })
end
attemptNavigation = function(allowDisplacement)
    local bootOk, bootError = nav.bootstrap(allowDisplacement)
    navigationReady = bootOk == true
    navigationError = navigationReady and nil or tostring(bootError)
    state.get().navigationReady = navigationReady
    state.get().navigationError = navigationError
    state.save()
    if navigationReady then
        print(("Navigation ready at %d,%d,%d facing %s"):format(
            nav.getPosition().x, nav.getPosition().y, nav.getPosition().z, nav.getHeading()
        ))
    else
        printError("Navigation setup deferred: " .. tostring(bootError))
    end
    return navigationReady
end
local startupCommand = string.lower(arguments[1] or "")
if startupCommand ~= "setup" and startupCommand ~= "calibrate" and startupCommand ~= "recover" then
    attemptNavigation(false)
end
if #arguments == 0 then onboarding() end

local running = true
if #arguments > 0 then running = handle(arguments) end
while running do
    local currentJob = state.get().currentJob
    if currentJob and currentJob.status == "FAILED" and state.get().autoRetry then
        print("Automatic retry is enabled; resuming the failed job.")
        jobs.retryFailed()
        currentJob = state.get().currentJob
    end
    if navigationReady and currentJob and currentJob.status ~= "FAILED" then
        local success, result, updateRequested
        success, result, updateRequested = runActiveJob(#arguments > 0)
        if result == "JOB_UPDATE_PENDING" then updateRequested = true end
        local event = result == "JOB_UPDATE_PENDING" and "WORKER_UPDATING"
            or success and "JOB_COMPLETE"
            or (result == "JOB_CANCELLED" and "JOB_CANCELLED" or "JOB_FAILED")
        network.report(event, {
            result = result,
            job = state.get().lastJob or state.get().currentJob,
        })
        if updateRequested then
            print("Installing worker update and rebooting; the job will resume automatically")
            sleep(1)
            os.reboot()
        end
        if not success and result ~= "JOB_CANCELLED" and state.get().autoRetry then
            print("Job failed; automatic retry is enabled. Retrying in " .. tostring(config.jobs.retryDelay) .. " seconds.")
            sleep(config.jobs.retryDelay)
            jobs.retryFailed()
        end
        if #arguments > 0 then break end
    else
        if #arguments > 0 then break end
        -- Failed jobs already selected the most specific actionable status.
        if navigationReady and not (currentJob and currentJob.status == "FAILED") then
            state.setStatus("WAITING_NETWORK", "Waiting for local command or controller assignment")
        end
        running = waitForAssignment()
    end
end
