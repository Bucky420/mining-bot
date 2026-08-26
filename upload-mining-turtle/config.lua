local networkId = tostring(settings.get("bucky.network", "bucky"))

local config = {
    schemaVersion = 1,

    paths = {
        dataDir = "/data",
        state = "/data/worker.state",
        map = "/data/tunnel.map",
        log = "/data/worker.log",
    },

    gps = {
        timeout = 5,
        debug = false,
        resyncMoves = 32,
        maximumDrift = 0,
    },

    movement = {
        retries = 8,
        retryDelay = 1,
        digRetries = 12,
        routeOrder = { "x", "z", "y" },
    },

    jobs = {
        retryDelay = 10,
    },

    network = {
        enabled = true,
        id = networkId,
        protocol = networkId .. "/mining/v1",
        controllerId = nil,
        receiveTimeout = 1,
        maxQueuedReports = 16,
    },

    profiles = {
        service = { width = 1, height = 2 },
        normal = { width = 3, height = 3 },
        trunk = { width = 5, height = 3 },
        hub = { width = 5, height = 5 },
    },
    defaultProfile = "normal",

    markers = {
        JUNCTION = "minecraft:yellow_wool",
        END = "minecraft:red_wool",
        BUILD = "minecraft:green_wool",
        PROFILE_CHANGE = "minecraft:blue_wool",
        MAIN_TUNNEL = "minecraft:orange_wool",
        ROOM = "minecraft:purple_wool",
        SERVICE = "minecraft:cyan_wool",
        FARM = "minecraft:lime_wool",
    },
    markerPattern = {
        inward = "minecraft:white_wool",
        right = "minecraft:black_wool",
    },

    scanner = {
        maxRadius = 8,
        chestNameContains = "chest",
        cropNameContains = "flax",
    },

    inventory = {
        protectedItems = {
            ["minecraft:coal"] = true,
            ["minecraft:charcoal"] = true,
            ["minecraft:coal_block"] = true,
        },
        fuelItems = {
            "minecraft:coal",
            "minecraft:charcoal",
            "minecraft:coal_block",
        },
        startupFuel = 8,
        jobFuelReserve = 64,
    },

    farming = {
        serviceRadius = 32,
        serviceIdleSeconds = 5,
        maxOverflightRise = 16,
        defaultMatureAge = 7,
        seedReserve = 8,
        minimumDiscoveryDensity = 0.6,
        outputReserveSlots = 4,
        harvestDropSlots = 4,
        farmlandNames = {
            ["minecraft:farmland"] = true,
        },
        tillableNames = {
            ["minecraft:dirt"] = true,
            ["minecraft:grass_block"] = true,
        },
    },

    equipment = {
        preferredSide = "right",
        modem = {
            "computercraft:wireless_modem_advanced",
            "computercraft:wireless_modem_normal",
            "computercraft:wired_modem_full",
        },
        pickaxe = {
            "minecraft:diamond_pickaxe",
        },
        geoScanner = {
            "advancedperipherals:geo_scanner",
        },
        chunkLoader = {
            "advancedperipherals:chunk_controller",
        },
        farmingTool = {
            "minecraft:diamond_hoe",
        },
    },

    logging = {
        level = "INFO",
        maxFileBytes = 65536,
    },
}

return config
