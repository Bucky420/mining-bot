local storage = {}

local MANIFEST = ".bucky-storage"
local TERRAIN_DIR = "bucky/terrain"

local function readTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
end

local function atomicWrite(path, value)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local temporary = path .. ".tmp"
    if fs.exists(temporary) then fs.delete(temporary) end
    local previous = path .. ".previous"
    local primaryValid = readTable(path) ~= nil
    if primaryValid and fs.exists(previous) then fs.delete(previous) end
    local serialized = textutils.serialize(value, { compact = true })
    if fs.getFreeSpace(parent ~= "" and parent or "/") < #serialized then
        return false, "VOLUME_FULL"
    end
    local handle, openError = fs.open(temporary, "w")
    if not handle then return false, openError or "TEMPORARY_OPEN_FAILED" end
    local wrote, writeError = pcall(function()
        handle.write(serialized)
        handle.flush()
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        if fs.exists(temporary) then fs.delete(temporary) end
        return false, tostring(writeError)
    end
    if not readTable(temporary) then
        fs.delete(temporary)
        return false, "TEMPORARY_VALIDATION_FAILED"
    end
    local rotated, rotateError = pcall(function()
        if fs.exists(path) then
            if primaryValid then fs.move(path, previous)
            else fs.delete(path) end
        end
        fs.move(temporary, path)
    end)
    if not rotated then
        if not fs.exists(path) and fs.exists(previous) then pcall(fs.move, previous, path) end
        return false, tostring(rotateError)
    end
    return true
end

local function safeName(value)
    local text, checksum = tostring(value), 0
    for index = 1, #text do checksum = (checksum * 131 + text:byte(index)) % 2147483647 end
    local prefix = text:gsub("[^%w_.-]", "_"):sub(1, 48)
    return ("%s-%d.map"):format(prefix ~= "" and prefix or "farm", checksum)
end

local function compactFarm(farmMap)
    local result = {
        format = 1,
        revision = farmMap.revision,
        updatedAt = farmMap.updatedAt,
        data = {},
        names = {},
        cells = {},
    }
    for key, value in pairs(farmMap.data or {}) do
        if key ~= "cells" then result.data[key] = value end
    end
    local nameIds = {}
    local function nameId(name)
        if name == nil then return 0 end
        name = tostring(name)
        if not nameIds[name] then
            result.names[#result.names + 1] = name
            nameIds[name] = #result.names
        end
        return nameIds[name]
    end
    for _, cell in pairs(farmMap.data and farmMap.data.cells or {}) do
        if cell.class ~= "air" and cell.name ~= "minecraft:air"
            and cell.name ~= "minecraft:cave_air" and cell.name ~= "minecraft:void_air" then
            result.cells[#result.cells + 1] = {
                cell.x, cell.y, cell.z, nameId(cell.name), nameId(cell.class),
                nameId(cell.occupant), nameId(cell.occupantClass), cell.occupantY or 0,
                cell.verticalStructure and 1 or 0,
            }
        end
    end
    table.sort(result.cells, function(a, b) return a[1] == b[1] and a[3] < b[3] or a[1] < b[1] end)
    return result
end

local function expandFarm(value)
    if type(value) ~= "table" or value.format ~= 1 then return value end
    local names = type(value.names) == "table" and value.names or {}
    local result = {
        revision = value.revision,
        updatedAt = value.updatedAt,
        data = type(value.data) == "table" and value.data or {},
    }
    result.data.cells = {}
    for _, row in ipairs(type(value.cells) == "table" and value.cells or {}) do
        local cell = {
            x = tonumber(row[1]), y = tonumber(row[2]), z = tonumber(row[3]),
            name = names[tonumber(row[4])], class = names[tonumber(row[5])],
            occupant = names[tonumber(row[6])], occupantClass = names[tonumber(row[7])],
            occupantY = tonumber(row[8]) ~= 0 and tonumber(row[8]) or nil,
            verticalStructure = tonumber(row[9]) == 1,
        }
        if cell.x and cell.y and cell.z and cell.class ~= "air"
            and cell.name ~= "minecraft:air" and cell.name ~= "minecraft:cave_air"
            and cell.name ~= "minecraft:void_air" then
            result.data.cells[("%d:%d"):format(cell.x, cell.z)] = cell
        end
    end
    return result
end

local function volumeManifest(mount, driveName, drive)
    local path = fs.combine(mount, MANIFEST)
    local manifest = readTable(path)
    if manifest and manifest.version == 1 and type(manifest.id) == "string" then return manifest end
    local label = drive.getDiskLabel()
    manifest = {
        version = 1,
        id = ("volume-%d-%d-%s"):format(
            os.getComputerID(), os.epoch("utc"), tostring(driveName):gsub("[^%w]", "_")
        ),
        label = label,
        createdAt = os.epoch("utc"),
    }
    local ok = atomicWrite(path, manifest)
    return ok and manifest or nil
end

function storage.discover()
    local volumes = {}
    for _, driveName in ipairs(peripheral.getNames()) do
        local drive = peripheral.getType(driveName) == "drive" and peripheral.wrap(driveName)
        if drive and drive.hasData() and drive.getDiskID() == nil then
            local mount = drive.getMountPath()
            if mount and fs.exists(mount) and not fs.isReadOnly(mount) then
                local manifest = volumeManifest(mount, driveName, drive)
                if manifest then
                    volumes[manifest.id] = {
                        id = manifest.id,
                        label = manifest.label or drive.getDiskLabel(),
                        drive = driveName,
                        mount = mount,
                        capacity = fs.getCapacity(mount),
                        free = fs.getFreeSpace(mount),
                    }
                end
            end
        end
    end
    return volumes
end

local function resolve(indexEntry, volumes)
    if type(indexEntry) ~= "table" then return nil end
    local volume = volumes[indexEntry.volumeId]
    if not volume or type(indexEntry.file) ~= "string" then return nil end
    return volume, fs.combine(volume.mount, indexEntry.file)
end

function storage.readFarm(indexEntry)
    local volume, path = resolve(indexEntry, storage.discover())
    if not volume then return nil, "TERRAIN_VOLUME_MISSING" end
    local value = readTable(path) or readTable(path .. ".previous")
    if not value then return nil, "TERRAIN_FILE_INVALID" end
    return expandFarm(value)
end

function storage.writeFarm(farmKey, farmMap, indexEntry)
    local volumes = storage.discover()
    local volume, path = resolve(indexEntry, volumes)
    local file = indexEntry and indexEntry.file or fs.combine(TERRAIN_DIR, safeName(farmKey))
    if not volume then
        for _, candidate in pairs(volumes) do
            if not volume or candidate.free > volume.free then volume = candidate end
        end
        if not volume then return nil, "NO_COMPUTER_STORAGE_VOLUME" end
        path = fs.combine(volume.mount, file)
    end
    local compact = compactFarm(farmMap)
    local ok, writeError = atomicWrite(path, compact)
    if not ok and writeError == "VOLUME_FULL" then
        local alternatives = {}
        for _, candidate in pairs(volumes) do
            if candidate.id ~= volume.id then alternatives[#alternatives + 1] = candidate end
        end
        table.sort(alternatives, function(a, b) return a.free > b.free end)
        for _, candidate in ipairs(alternatives) do
            local candidatePath = fs.combine(candidate.mount, file)
            ok, writeError = atomicWrite(candidatePath, compact)
            if ok then
                volume, path = candidate, candidatePath
                break
            end
        end
    end
    if not ok then return nil, writeError end
    return {
        volumeId = volume.id,
        file = file,
        revision = farmMap.revision,
        updatedAt = os.epoch("utc"),
    }
end

function storage.readValue(indexEntry, validator)
    local volume, path = resolve(indexEntry, storage.discover())
    if not volume then return nil, "TERRAIN_VOLUME_MISSING" end
    local value = readTable(path) or readTable(path .. ".previous")
    if not value or validator and not validator(value) then return nil, "STORAGE_FILE_INVALID" end
    return value
end

function storage.writeValue(file, value, indexEntry, validator)
    local volumes = storage.discover()
    local volume, path = resolve(indexEntry, volumes)
    if indexEntry and not volume then return nil, "TERRAIN_VOLUME_MISSING" end
    if not volume then
        for _, candidate in pairs(volumes) do
            if not volume or candidate.free > volume.free then volume = candidate end
        end
        if not volume then return nil, "NO_COMPUTER_STORAGE_VOLUME" end
        path = fs.combine(volume.mount, file)
    end
    local ok, writeError = atomicWrite(path, value)
    if not ok then return nil, writeError end
    local installed = readTable(path)
    if not installed or validator and not validator(installed) then
        return nil, "INSTALLED_STORAGE_FILE_INVALID"
    end
    return {
        volumeId = volume.id,
        file = file,
        updatedAt = os.epoch("utc"),
    }
end

function storage.stats(maximumDrives)
    local volumes, connected, capacity, free = storage.describe(), 0, 0, 0
    for _, volume in ipairs(volumes) do
        connected = connected + 1
        capacity = capacity + (tonumber(volume.capacity) or 0)
        free = free + (tonumber(volume.free) or 0)
    end
    local used = math.max(0, capacity - free)
    return {
        connected = connected,
        maximum = math.max(1, math.floor(tonumber(maximumDrives) or 8)),
        capacity = capacity,
        free = free,
        used = used,
        percent = capacity > 0 and used / capacity * 100 or 0,
    }
end

function storage.describe()
    local result = {}
    for _, volume in pairs(storage.discover()) do
        result[#result + 1] = {
            id = volume.id, label = volume.label, drive = volume.drive,
            capacity = volume.capacity, free = volume.free,
        }
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

return storage
