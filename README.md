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
metadata. Both compact 2D farm maps and authoritative 3D chunks use separate,
atomic terrain directories on the mounted computers. Legacy controller-local
3D chunks are copied and validated on mounted storage before the index changes;
the source is retained for rollback. Removing a storage computer can therefore
make its farms temporarily unavailable, but does not silently create a
conflicting map on another volume. The controller monitor header shows aggregate
used percentage, connected/configured drive count, and used/total capacity.

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
- Press `T` to focus the next known turtle, ordered by distance from the player
  (or current map center).
- The native Pocket map uses CC:Tweaked 2-by-3 semigraphics for six square map
  pixels per terminal character.
- Cyan pixels mark the player. Turtle markers use a black high-contrast outline;
  the focused turtle blinks white/orange and its facing tip is yellow. Red
  centers mark off-screen turtles.
- The Pocket requests bounded cave slices from the controller's 3D chunks; it
  does not copy or persist the turtle's complete navigation map.
- `[` and `]` select a manual Y level. `L` toggles automatic mode, which follows
  the player/turtle Y and switches back to the grass surface map when the known
  column is open to the surface.
- `A` selects automatic surface/cave mode, `S` forces the surface map, and `C`
  forces cave mode. The footer shows the active mode as `M:A`, `M:S`, or `M:C`.
- Cave layers show walkable two-block-high tunnels, walls, low ceilings, and
  pits. Unknown cells remain blank, and the 2D surface map is the fallback until
  3D data exists.
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

The service surveys terrain in spherical Geo Scanner tiles, follows local
ground contours within three blocks above or below the chest ground level, and
publishes revisioned terrain deltas to the controller. Survey centers use an
eight-block serpentine spacing with long straight rows. Before each survey move,
the turtle asks the mining controller once for a distance-ordered array of
missing current-version scan poses. The pose array and rolling 3D A* map remain
in RAM. If the controller is unavailable, the turtle generates the complete
local sweep once. If the next center is outside known air, it advances to the
nearest reachable frontier, scans there, publishes the delta, and repeats. It
may use a nearby scan cell when the nominal center is occupied. It preserves
trees, excludes their occupied canopy cells, and applies a three-block
construction and travel margin around fences, buildings, unknown blocks, and
terrain outside the vertical limit. Spherical scan-edge air remains unknown
rather than becoming a false 2D surface. Before planning, the turtle republishes
its current 2D revision and waits for the controller's persisted ACK. Fully
enclosed natural sand or stone surface islands may be replaced with dirt. Fully
enclosed holes no deeper than three blocks may be filled. Every destructive
operation re-inspects the live block and checkpoints before changing it.

The mining controller persists authoritative 3D terrain as atomic 16x16x16
chunk files under `bucky/terrain-3d/` on mounted storage computers. Chunks
use a block-name palette and run-length encoded local coordinates while retaining
known air, solid blocks, verification time, and a change count. Existing verbose
chunks and their rollback copies are converted atomically when the controller
boots. The turtle requests chunks only for job-local navigation and recovery,
keeps a 3x3 chunk window in RAM, and merges fresh Geo Scanner results without
allowing an older controller snapshot to overwrite newer local observations.
Stable chunks are reused for up to 24 hours, while chunks with observed changes
are refreshed after 15 minutes when approached. Ordinary crop work still updates
inspected cells individually instead of triggering whole-farm scans.

Survey coverage is versioned separately from stored terrain. Legacy 2D maps and
older 3D chunks remain available for surface display and rollback, but they do
not satisfy a current-version survey plan. Scan payloads and survey pose arrays
are never persisted in turtle worker state.

The turtle persists only a rolling window of the four newest surface tiles. A
surface tile is acknowledged only after the controller has validated its
external copy. If the controller is unavailable, the turtle may use its local
window, but it never guesses through an unobserved obstacle. Farm survey points
can be rebuilt from fresh 3D chunks without scanning again; expired or missing
areas are scanned and uploaded as new 3D chunk data.
All turtle movement enters the shared navigation layer. The controller plans
coarse and long-range 3D waypoint arrays from its global map, reserving route
cells against other turtles and a safety volume around the tracked player. The
turtle validates adjacency and reinspects each physical move. Unexpected blocks
are reported to the controller, which updates the chunk and replans once.
Farm-survey and other close work movements may use the bounded local 3D cache;
ordinary farming remains inspection-driven rather than repeatedly rescanning.
Reactive overflight is not the default route planner.

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
