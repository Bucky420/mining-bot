local scanner = require("lib.scanner")
local network = require("lib.network")

local surveyArea = {}

function surveyArea.run(job, framework)
    if job.progress.complete and job.progress.result then return true, job.progress.result end
    if not framework.checkpoint(job, "Preparing Geo Scanner survey") then return false, "JOB_CANCELLED" end
    local result, scanError = scanner.scan(job.parameters.radius, job.parameters.blockFilter)
    if not result then return false, scanError end
    local chunks = {}
    for _, block in ipairs(result.blocks or {}) do
        local chunkKey = ("%d:%d:%d"):format(
            math.floor(block.x / 16), math.floor(block.y / 16), math.floor(block.z / 16)
        )
        chunks[chunkKey] = chunks[chunkKey] or {}
        chunks[chunkKey][#chunks[chunkKey] + 1] = block
    end
    local reported, reportError = network.reportFarmSpatial(
        job.parameters.mapId or "world", chunks, 0,
        result.origin, result.radius, result.version
    )
    if not reported then return false, "SURVEY_3D_REPORT_FAILED: " .. tostring(reportError) end
    job.progress.result = result
    job.progress.complete = true
    if not framework.checkpoint(job, "Survey captured") then return false, "JOB_CANCELLED" end
    return true, result
end

return surveyArea
