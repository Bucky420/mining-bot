local scanner = require("lib.scanner")

local surveyArea = {}

function surveyArea.run(job, framework)
    if job.progress.complete and job.progress.result then return true, job.progress.result end
    if not framework.checkpoint(job, "Preparing Geo Scanner survey") then return false, "JOB_CANCELLED" end
    local result, scanError = scanner.scan(job.parameters.radius, job.parameters.blockFilter)
    if not result then return false, scanError end
    job.progress.result = result
    job.progress.complete = true
    if not framework.checkpoint(job, "Survey captured") then return false, "JOB_CANCELLED" end
    return true, result
end

return surveyArea
