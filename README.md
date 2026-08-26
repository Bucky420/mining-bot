# Mining Bot V1

Local-first CC:Tweaked automation for mining turtles, crop farms, and room or
tunnel jobs.

## Roles

- **Deployment PC** stores and distributes project revisions.
- **Mining PC** discovers turtles and assigns jobs.
- **Mining turtle** performs navigation and work locally.
- **Relay PC** is an optional cache-and-forward terminal for remote control.

There is only one deployment authority. Relays never create revisions or
overwrite worker state.

## Install

1. On the deployment PC, drag all files from `drag-to-deployment-pc/` onto a
   CC:Tweaked computer with a modem, then reboot it.
2. Drag all files from `upload-mining-turtle/` and
   `upload-mining-controller/` onto the running deployment PC.
3. On the mining PC, drag `drag-to-mining-device/startup.lua` onto a computer
   with a modem, then reboot it.
4. On each turtle, drag the same `startup.lua` onto the turtle, then reboot it.
   This persistent bootstrap runs the installed application and update watcher
   concurrently. It must be copied directly because deployments never replace
   `/startup.lua`. Devices pull the current manifest at boot, then listen for
   pushed update announcements without generating periodic polling traffic.
   The authority and cache relays repeat their current releases every 15
   seconds so devices which reconnect after an announcement still update.
5. Optionally, drag all files from `drag-to-relay-pc/` onto an advanced pocket
   computer, then reboot it.

Running relays recognize `relay-manifest.lua` as a local self-update package.
Dragging all files from `drag-to-relay-pc/` onto an active relay stages and
validates every manifest entry, installs it with rollback data, and reboots the
Pocket automatically. Relays installed before the manifest updater require the
same package to be dragged twice once: the first drag updates the updater, and
the second installs the complete package. Later updates require one drag per
Pocket, including when new files are added to the manifest.

The bootstrap detects whether it is running on a computer or turtle and
installs the correct target. Updates are staged, validated, and resumed from
checkpoints. `/data` state and maps are never distributed.

## Network

All devices use the `bucky` network by default. To change it, set the same
value on every device before rebooting:

```text
set bucky.network my-network-name
reboot
```

Computer IDs are internal addresses. Operators use assigned turtle names.

Controllers broadcast a lightweight heartbeat challenge every 15 seconds.
Registered workers reply directly with status, verified position, and installed
release. Three missed challenges mark a worker offline; its registration is
retained for recovery, but new jobs are rejected until it reconnects. Unknown
senders receive `REGISTRATION_REQUIRED` instead of being trusted implicitly.

## Controller Commands

```text
turtles
jobs
sites
storage
travel <turtle> <x> <y> <z>
dig <turtle> <north|east|south|west> <length> [profile]
repair <turtle> <x> <y> <z> <marker-type>
survey <turtle> [radius]
farm-service <turtle> start [radius]
farm-service <turtle> stop | status
farm-expand <turtle> [on|off|toggle]
farm-radius <turtle> <radius>
farm <turtle> <farm-id> [mature-age] [seed-name]
tunnel <turtle> <tunnel-id> <length>
cancel <turtle>
retry [now|turtle-name]
help
```

Farm jobs support configured crops and seeds rather than a crop-specific
implementation. A farm can use a service station for fuel, tools, seeds, and
output, or operate from onboard supplies.

## Controller Storage

Farm terrain is owned by the mining controller, not by roaming turtles. Give
the controller one or more disk drives containing computers:

1. Place and start each storage computer once so CC:Tweaked assigns its
   filesystem.
2. Stop and break the storage computer, then insert it into a disk drive.
3. Attach each drive directly or through the controller's wired peripheral
   network.
4. Run `storage` on the controller. Every mounted computer should appear with
   its capacity and free space.

The controller writes a stable `.bucky-storage` identity inside each mounted
computer. It never depends on changing mount names such as `/disk` or `/disk2`.
Floppies are ignored: only writable data media for which the drive reports no
floppy disk ID are used. New farms are assigned to the volume with the most
free space. If an existing volume fills, a validated replacement may be written
to another mounted computer before the controller changes its reference. If a
known volume is missing or no terrain copy can be validated, the controller
rejects the update instead of acknowledging data it could not preserve.

`/data/controller.state` retains worker, job, revision, and stable volume
metadata. Bulk farm maps use compact, atomic terrain files on the mounted
computers. Removing a storage computer can therefore make its farms temporarily
unavailable, but does not silently create a conflicting map on another volume.

## Turtle Commands

```text
travel <x> <y> <z>
dig <north|east|south|west> <length> [profile]
farm <farm-id>
farm-service start [radius]
farm-service stop | status
farm-expand [on|off|toggle]
farm-radius <radius>
tunnel <tunnel-id> <length>
survey [radius]
setup
sites
profiles
markers
fuel
status
tasks
retry
cancel
recover
```

## Pocket Map

The relay pocket computer opens separate `Command` and `Map` tabs in CraftOS's
native tab bar. Click those tabs outside the program terminal to switch views,
or type `map` from the command tab. The map follows the pocket computer's GPS
position by default and overlays live turtle headings on terrain reported by
farm surveys. Consecutive GPS fixes rotate the map so the player's current
travel direction is at the top; `UP:N`, `UP:E`, `UP:S`, or `UP:W` in the footer
shows the corresponding world direction.

- Arrow keys pan and disable player follow.
- `Page Up` zooms in and `Page Down` zooms out.
- Press `Space` to center on the player and restore following.
- The native Pocket map uses CC:Tweaked 2-by-3 semigraphics for six square map
  pixels per terminal character.
- Cyan pixels mark the player, orange pixels mark turtles, and red edge pixels
  mark off-screen turtles.
- Click the native `Command` tab to return to commands.

GPS reports movement but not stationary head direction. For live yaw, connect an
Advanced Peripherals Player Detector directly to the mining controller PC or to
its connected wired-modem network. Configure the tracked Minecraft name on that
controller before rebooting it:

```text
set bucky.player PlayerName
```

The controller sends only that player's validated position and yaw to registered
relays. If no name is configured, it automatically tracks the player only when
exactly one player is online. The Pocket keeps its wireless modem equipped.

Terrain snapshots are transferred in bounded chunks and kept only in pocket
memory. Reconnecting to the controller rebuilds the map without growing the
relay command-state file.

## Safety

- GPS verifies physical position and heading at boot.
- Normal movement is centralized in `lib/nav.lua` and persisted transactionally.
- Jobs checkpoint progress so interrupted work can resume safely.
- Inventory management protects tools, fuel, modem, scanner, seeds, and marker
  materials.
- Wool markers identify entrances, junctions, stations, farms, endpoints, and
  build or profile requests.
- Missing fuel, tools, seeds, scanner, or output storage creates a recoverable
  job failure instead of risking the turtle.

Navigation calibration at boot requires GPS coverage, fuel, an equipped modem,
and one empty horizontal block that the turtle can move into and back out of.
Do not stand in that block during calibration. If setup is incomplete, run
`status` for the recorded cause, clear a path, and run `setup` again. Controllers
do not submit jobs while a worker explicitly reports that navigation is not
ready.

## Autonomous Farm Service

`farm-service` is a persistent chest-anchored farmer. Start the turtle facing
the Ender Chest that will provide supplies and receive output. The chest is the
center of the farm, and the turtle returns there to unload, poll supplies, and
idle. Farming does not use the worker's logical home point, although GPS remains
required for boot and reboot recovery.

Automatic expansion is enabled by default. The radius is the only farm layout
setting and defaults to 32 blocks. It is a maximum circular survey envelope,
not an instruction to prepare every block immediately. Existing planted cells
plus currently supplied seeds determine the active farm size, so five seeds
produce a small addition and larger supplies expand farther. When the envelope
is full, available replacement seeds gradually rebalance active crops toward
equal alternating rows.

The service surveys terrain in Geo Scanner tiles, follows local ground contours
within three blocks above or below the chest ground level, and publishes
revisioned terrain deltas to the controller. Survey centers use an overlapping
serpentine sweep with long straight rows and short L transitions. Obstacle
routes penalize rotations, preferring one large L or a slightly longer path
over repeated left-right turns. It preserves trees, excludes their
occupied canopy cells, and applies a three-block construction and travel margin
around fences, buildings, unknown blocks, and terrain outside the vertical
limit. Fully enclosed natural sand or stone surface islands may be replaced
with dirt. Fully enclosed holes no deeper than three blocks may be filled.
Every destructive operation re-inspects the live block and checkpoints before
changing it.

The turtle persists only a rolling window of the four newest scanner tiles.
Each tile is acknowledged only after the controller has validated its external
copy. Long travel requests a turn-efficient route from the controller; every
returned step is checked for integer coordinates, adjacency, destination, and
length before movement. If the controller is unavailable, the turtle may use
its local window or a bounded route through freshly inspected air, but it never
guesses through an unobserved obstacle. The complete terrain map is fetched in
validated chunks only when the farm plan is rebuilt, then discarded after the
compact execution plan is created.

Actually Additions worms are preferred for irrigation. One reserved worm center
covers each usable 3x3 tile. The turtle clears flowers or tall grass from that
center first. Existing water is reused; a protected water bucket is the fallback
when no worm is available. Cells without verified irrigation are not planted.

The supply chest may provide seeds, worms, dirt, water buckets, coal, and
replacement tools. The only allowed tool items are
`minecraft:diamond_pickaxe` and `minecraft:diamond_hoe`. The chunk controller
side remains protected while the modem side is temporarily swapped for the Geo
Scanner or a tool.

## Requirements

- Current CC:Tweaked
- Mining turtle or advanced mining turtle
- Wireless modem
- GPS coverage for verified startup recovery
- Advanced Peripherals Geo Scanner is optional for ordinary jobs and required
  for autonomous farm construction
- At least one initialized computer mounted in a controller-connected disk
  drive is required for persistent autonomous farm terrain

See the command help shown by the controller and worker for current setup
options.
