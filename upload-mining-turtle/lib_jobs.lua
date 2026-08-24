local state = require("lib.state")
local util = require("lib.util")

local jobs = {}
local handlers = {}
local checkpointHook

function jobs.register(jobType, handler)
    if type(jobType) ~= "string" or type(handler) ~= "table" or type(handler.run) ~= "function" then
        error("Invalid job handler registration", 2)
    end
    handlers[jobType] = handler
end

function jobs.supported(jobType)
    return handlers[jobType] ~= nil
end

function jobs.create(jobType, parameters)
    if not handlers[jobType] then return nil, "UNSUPPORTED_JOB_TYPE" end
    return {
        id = util.makeId("job"),
        type = jobType,
        parameters = util.copy(parameters or {}),
        progress = {},
        status = "QUEUED",
        createdAt = util.now(),
    }
end

function jobs.assign(job)
    if type(job) ~= "table" or not handlers[job.type] then
        return false, "UNSUPPORTED_JOB_TYPE"
    end
    local data = state.get()
    if data.currentJob then
        return false, "JOB_ALREADY_ACTIVE"
    end
    job.id = job.id or util.makeId("job")
    job.parameters = job.parameters or {}
    job.progress = job.progress or {}
    job.status = "QUEUED"
    job.assignedAt = util.now()
    data.currentJob = job
    state.save()
    util.log("INFO", "Job assigned", { id = job.id, type = job.type })
    return true
end

function jobs.checkpoint(job, statusDetail)
    if checkpointHook and not job.cancelRequested and not job.updateRequested then
        local hookOk, updateAvailable, hookError = pcall(checkpointHook)
        if not hookOk then error("CHECKPOINT_UPDATE_CHECK_FAILED: " .. tostring(updateAvailable)) end
        if updateAvailable == nil then error("CHECKPOINT_UPDATE_CHECK_FAILED: " .. tostring(hookError)) end
        if hookOk and updateAvailable then job.updateRequested = true end
    end
    job.updatedAt = util.now()
    if statusDetail then job.statusDetail = statusDetail end
    state.save()
    return not job.cancelRequested and not job.updateRequested
end

function jobs.setCheckpointHook(callback)
    checkpointHook = callback
end

function jobs.isCancellationRequested(job)
    return job.cancelRequested == true or job.updateRequested == true
end

function jobs.requestUpdate()
    local job = state.get().currentJob
    if not job or job.status ~= "RUNNING" then return false, "NO_RUNNING_JOB" end
    job.updateRequested = true
    state.save()
    return true
end

function jobs.executeCurrent()
    local data = state.get()
    local job = data.currentJob
    if not job then return true, "NO_JOB" end
    local handler = handlers[job.type]
    if not handler then return false, "UNSUPPORTED_JOB_TYPE" end
    if job.status == "FAILED" then return false, job.failureReason or "JOB_FAILED" end

    job.status = "RUNNING"
    job.startedAt = job.startedAt or util.now()
    state.setStatus(job.type == "TRAVEL" and "TRAVELING" or "WORKING", job.type)
    state.save()
    util.log("INFO", "Executing job", { id = job.id, type = job.type })

    local callOk, success, result = pcall(handler.run, job, jobs)
    if not callOk then
        success, result = false, "HANDLER_ERROR: " .. tostring(success)
    end
    if success then
        job.status = "COMPLETE"
        job.completedAt = util.now()
        job.result = util.detachedCopy(result)
        data.lastJob = job
        data.currentJob = nil
        data.lastError = nil
        state.setStatus("IDLE")
        state.save()
        util.log("INFO", "Job completed", { id = job.id, type = job.type, result = result })
        return true, result
    end

    if result == "JOB_CANCELLED" and job.updateRequested and not job.cancelRequested then
        job.status = "QUEUED"
        job.updateRequested = nil
        state.setStatus("UPDATE_PENDING", "Job paused at a safe checkpoint")
        state.save()
        util.log("INFO", "Job paused for worker update", { id = job.id, type = job.type })
        return false, "JOB_UPDATE_PENDING"
    end

    if result == "JOB_CANCELLED" then
        job.status = "CANCELLED"
        job.completedAt = util.now()
        data.lastJob = job
        data.currentJob = nil
        state.setStatus("IDLE", "Job cancelled")
        state.save()
        util.log("WARN", "Job cancelled", { id = job.id, type = job.type })
        return false, result
    end

    job.status = "FAILED"
    job.failureReason = result or "UNKNOWN_JOB_FAILURE"
    job.failedAt = util.now()
    state.setError("JOB_FAILED", job.failureReason, { id = job.id, type = job.type })
    local failureStatus = "JOB_FAILED"
    if job.failureReason:find("NEEDS_TOOL", 1, true) then failureStatus = "NEEDS_TOOL" end
    if job.failureReason:find("NO_FUEL", 1, true) then failureStatus = "NEEDS_FUEL" end
    if job.failureReason:find("INVENTORY", 1, true) then failureStatus = "NEEDS_INVENTORY_SPACE" end
    if job.failureReason:find("NEEDS_SEEDS", 1, true)
        or job.failureReason:find("SUPPLY_", 1, true) then failureStatus = "NEEDS_SUPPLIES" end
    if job.failureReason:find("OUTPUT_CHEST", 1, true) then failureStatus = "NEEDS_OUTPUT" end
    if job.failureReason:find("NEEDS_OUTPUT", 1, true) then failureStatus = "NEEDS_OUTPUT" end
    if job.failureReason:find("NEEDS_GEO_SCANNER", 1, true) then failureStatus = "NEEDS_SCANNER" end
    if job.failureReason:find("NEEDS_FARM", 1, true) then failureStatus = "NEEDS_FARM" end
    if job.failureReason:find("NEEDS_MODEM", 1, true) then failureStatus = "NEEDS_NETWORK" end
    state.setStatus(failureStatus, job.failureReason)
    util.log("ERROR", "Job failed", { id = job.id, type = job.type, reason = job.failureReason })
    return false, job.failureReason
end

function jobs.retryFailed()
    local data = state.get()
    local job = data.currentJob
    if not job or job.status ~= "FAILED" then return false, "NO_FAILED_JOB" end
    job.status = "QUEUED"
    job.failureReason = nil
    job.failedAt = nil
    job.cancelRequested = nil
    data.lastError = nil
    state.setStatus("IDLE", "Retry queued")
    state.save()
    return true
end

function jobs.cancelCurrent()
    local data = state.get()
    local job = data.currentJob
    if not job then return false, "NO_CURRENT_JOB" end
    if job.status == "RUNNING" then
        job.cancelRequested = true
        state.save()
        return true
    end
    job.status = "CANCELLED"
    job.completedAt = util.now()
    data.lastJob = job
    data.currentJob = nil
    data.lastError = nil
    state.setStatus("IDLE", "Job cancelled")
    state.save()
    return true
end

function jobs.clearFailed()
    local data = state.get()
    if data.currentJob and data.currentJob.status == "FAILED" then
        data.lastJob = data.currentJob
        data.currentJob = nil
        state.setStatus("IDLE")
        state.save()
        return true
    end
    return false
end

return jobs
