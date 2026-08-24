# Mining Bot V1

Local-first CC:Tweaked mining system with three separate computer roles.

## Three Roles

1. **Deployment PC** stores and distributes software for multiple projects. It
   does not control mining jobs.
2. **Mining PC** runs `controller.lua`, discovers workers, and assigns whole
   jobs.
3. **Mining turtles** run `worker.lua` and execute navigation/mining locally.

The deployment PC routes updates by `project/target`. Mining turtles subscribe
to `mining-bot/turtle`; the mining PC subscribes to `mining-bot/controller`.
Other projects can use different names on the same deployment PC.

## Workspace Folders

```text
drag-to-deployment-pc/   Initial deployment PC files
  startup.lua
  deploy_server.lua

upload-mining-turtle/    Files dropped onto the running deployment PC
upload-mining-controller/

drag-to-mining-device/   One startup.lua used for both the mining PC and turtles
  startup.lua

drag-to-relay-pc/         Optional pocket-computer relay
  startup.lua
  relay.lua
```

All upload folders are flat. Open a folder, select every file inside it, and
drag those files into the appropriate in-game computer.

## Deployment PC Setup

1. Use a normal or advanced CC:Tweaked computer with a modem.
2. Open `drag-to-deployment-pc` on Windows.
3. Select `startup.lua` and `deploy_server.lua` and drag both onto the computer.
4. Reboot the computer.

The startup program continuously runs the generic deployment server. It creates
`/projects` automatically and displays its computer ID.

If a monitor is attached, deployment status and errors are mirrored to it while
the computer terminal remains usable.

Monitor output automatically wraps to its current width and redraws when the
monitor is resized. The last 200 output messages are retained for redraw.

To update the deployment PC itself, drag `startup.lua` and
`deploy_server.lua` from `drag-to-deployment-pc` onto it. The running server now
recognizes that pair as a self-update and reboots automatically. If an older
server prints `missing upload.lua`, press `Ctrl+T` to stop it, drag the two files
while at the CraftOS shell, and run `reboot` once. Future deployment-PC updates
will be automatic.

## Upload Mining Software

While the deployment server is running:

1. Open `upload-mining-turtle`, select every file, and drag them onto the
   deployment PC.
2. Open `upload-mining-controller`, select every file, and drag them onto the
   deployment PC.
3. Wait for the server to report that each upload was saved and activated.

Each batch contains `upload.lua`. The running deployment server handles the
CC:Tweaked `file_transfer` event and routes the batch automatically:

```text
/projects/mining-bot/turtle/
/projects/mining-bot/controller/
```

You do not need to stop the server, use `cd`, or manually create those folders.
The server waits for files to remain stable for three seconds, validates every
manifest and Lua file, then broadcasts the new target revision.

## Install Mining PC

1. Attach a modem to the mining controller computer.
2. Drag only `drag-to-mining-device/startup.lua` onto it.
3. Reboot.

Because this is a normal computer, the bootstrap selects
`mining-bot/controller`, installs `controller.lua`, and reboots. Later boots
check for controller updates before launching the controller.

## Install Turtles

For every mining turtle:

1. Attach a modem or put a CC:Tweaked wireless modem in inventory.
2. Drag only `drag-to-mining-device/startup.lua` onto the turtle.
3. Reboot.

Because the `turtle` API exists, the same bootstrap selects
`mining-bot/turtle`, installs all worker modules, and reboots. It creates
`lib/` and `jobs/` itself.

The bootstrap `startup.lua` remains permanently installed and is never replaced
during an update. This ensures an interrupted update always has valid recovery
code at the next boot. Deployment state is stored in `/data/deployment.state`.

## Live Updates

To update mining turtle code, drag every file from `upload-mining-turtle` onto
the running deployment PC again. To update the controller, drag every file from
`upload-mining-controller`.

- The mining PC reboots into its updater when its controller target changes.
- Idle turtles reboot into their updater when the turtle target changes.
- Active turtles pause at their next safe checkpoint, keep the job queued,
  install the update, reboot, and resume from the persisted checkpoint. A
  turtle using a tool briefly swaps in its modem every five seconds at a safe
  checkpoint to query the deployment server.
- Relay alerts report both when a turtle accepts an update and when the updated
  worker has rebooted successfully.
- Every device also checks for updates at boot.
- If the deployment PC is offline, already-installed devices continue running
  their local revision.
- `/data` worker, map, controller, and deployment state is never distributed or
  overwritten by project updates.

## Optional Pocket Relay

There is still only one deployment server. A pocket computer is only a
store/cache-and-forward relay and never creates revisions or manages projects.

1. Attach an Ender Modem or other modem to the pocket computer.
2. Drag both files from `drag-to-relay-pc` onto the pocket computer.
3. Reboot it.

The relay discovers the master deployment PC automatically. You can then drag
either upload batch onto the pocket computer itself:

```text
upload-mining-turtle/*
upload-mining-controller/*
```

The relay forwards the batch to the master. The master validates and activates
it, then the relay caches and forwards the official revision to nearby devices.
If the master is offline, already-installed devices continue operating. The
relay does not invent or publish local revisions.

To update the relay itself, drag `startup.lua` and `relay.lua` from
`drag-to-relay-pc` onto the running pocket. It recognizes that pair as a
self-update and reboots automatically. If an older relay prints
`missing upload.lua`, press `Ctrl+T`, drag the two files at the CraftOS shell,
then run `reboot` once.

To update the master deployment PC through the pocket, drag `startup.lua` and
`deploy_server.lua` from `drag-to-deployment-pc` onto the running pocket. The
pocket forwards that pair to the master; the master installs it and reboots.

The relay also provides a remote mining-controller terminal. At the pocket
computer use the same commands as the mining PC:

```text
relay> turtles
relay> jobs
relay> travel turtle-1 100 64 -20
relay> dig turtle-2 east 32 service
```

The pocket forwards these commands to the mining PC and displays its response.
The mining PC remains the job authority; the pocket does not move turtles
directly.

If a monitor is attached to the pocket, relay status, cache activity, upload
errors, and remote controller output are mirrored there.

Monitor output wraps to the available width and redraws after resizing.

Computer IDs are internal rednet addresses only. Normal installation, relay
pairing, reconnecting, and update delivery use automatic discovery. If the
master is repaired or rebooted, relays and devices reconnect automatically.

## Network Name

All deployment, relay, controller, and turtle traffic belongs to one logical
network named `bucky` by default. Computer IDs remain internal to rednet and are
not operator configuration.

The protocols are derived automatically:

```text
bucky/deployment/v1
bucky/mining/v1
```

To use another shared name, run this on the deployment PC, relay, mining PC,
and each turtle before rebooting:

```text
set bucky.network my-network-name
reboot
```

Every participating device must use the same value. This is a simple network
name/passphrase for separation and convenience, not cryptographic security.

Rednet does not authenticate computer IDs. Use deployment on a trusted network.

## Other Projects

The deployment server is not mining-specific. A new flat upload batch needs an
`upload.lua` routing descriptor:

```lua
return { project = "inventory-computers", target = "main" }
```

It also needs a `manifest.lua` describing source filenames from that flat batch
and their installed paths:

```lua
return {
    files = {
        { source = "main.lua", path = "main.lua" },
        { source = "display.lua", path = "lib/display.lua" },
    },
}
```

That project supplies its own bootstrap/updater identifying its project and
target. Dropping the batch onto the running deployment PC creates or updates
`/projects/inventory-computers/main` without affecting mining computers.

## Controller Commands

At the mining PC:

```text
turtles
jobs
sites
surveys
retry                                # toggle automatic retry on all turtles
retry now                            # immediately retry all failed turtles
retry <turtle-name>                  # toggle one turtle
cancel <turtle-name>
travel <turtle-name> <x> <y> <z>
dig <turtle-name> <north|east|south|west> <length> [profile]
repair <turtle-name> <x> <y> <z> <marker-type>
survey <turtle-name> [radius]
farm <turtle-name> <farm-id> [mature-age] [seed-name]
tunnel <turtle-name> <tunnel-id> <length>
setup-station <turtle-name> <id> <supply-direction> <output-direction>
setup-tunnel <turtle-name> <id> <direction> <width> <height>
setup-farm <turtle-name> <id> <width> <length> <direction> <crop> <seed> [age] <station-id>
setup-room <turtle-name> <id> <type> <direction> <width> <length> <height>
help
```

Workers announce themselves while idle. The controller assigns persistent names
such as `turtle-1` and `turtle-2`; normal commands use those names rather than
computer IDs. An optional CC computer label can also be used. The first accepted
controller assignment is remembered by the turtle, and job lifecycle reports
return to that controller. `retry` resumes a failed job from its persisted
checkpoint. `cancel` stops an active job at its next safe checkpoint or removes
a queued or failed job.

On the relay pocket, `alerts` is a local persistent toggle and is enabled by
default. `alerts on`, `alerts off`, and `alerts status` are also accepted. When
enabled, the pocket automatically displays live turtle failures and the latest
10 alerts whenever it connects or the mining controller restarts. Empty alert
history produces no output. Press Tab to complete pocket command names, current
turtle names, and known farm/tunnel site IDs.

## Worker Commands

Commands can still be entered directly on an idle turtle:

```text
travel <x> <y> <z>
travel <node-id>
dig <north|east|south|west> <length> [profile]
repair <x> <y> <z> <JUNCTION|END|BUILD|PROFILE_CHANGE>
survey [radius]
farm <farm-id>
tunnel <tunnel-id> <length>
setup station <id> <supply-direction> <output-direction>
setup tunnel <id> <direction> <width> <height>
setup farm <id> <width> <length> <direction> <crop> <seed> [mature-age] <station-id>
setup room <id> <type> <direction> <width> <length> <height>
inspect down
inspect front
inspect item [slot]
sites
profiles
markers
node add <id> <x> <y> <z> <type> [profile]
edge add <id> <from> <to> <direction> <length> [profile]
setup
fuel
status
tasks
retry
cancel
recover
```

## Wool Markers

Markers use an oriented three-wool floor pattern. Stand the turtle over the
colored anchor while configuring the location:

```text
W   white wool points into the managed tunnel or room
C B colored anchor with black wool on its right
```

The colored anchor meanings are:

| Wool   | Meaning                                     |
| ------ | ------------------------------------------- |
| Orange | Main tunnel entrance                        |
| Purple | Room entrance                               |
| Cyan   | Service station                             |
| Lime   | Farm, when a physical farm marker is wanted |
| Yellow | Junction                                    |
| Red    | End or no-dig cap                           |
| Green  | Build request                               |
| Blue   | Profile change                              |

All marker wool, including the white and black orientation blocks, is protected
from automatic tunnel digging. Ordinary workers can read the colored anchor
below them. A turtle with a Geo Scanner validates the entire pattern and its
orientation. Rooms and tunnels store dimensions virtually; wool is not required
around the complete boundary.

## Service Stations

A service station has one navigation cell and two different adjacent Ender
Chests:

- The supply chest is stocked by AE2/RS exporters with fuel, tools, seeds, and
  marker wool.
- The output chest imports harvested or mined items into storage.

Place the turtle at the navigation cell, note the absolute directions from the
turtle to each chest, and run:

```text
setup station base-service <supply-direction> <output-direction>
```

The directions are absolute `north`, `east`, `south`, or `west`, not left and
right. The software validates each chest as an inventory before transferring
anything. Modems, tools, fuel, marker wool, and configured seed reserves are
never unloaded. Keep at least one empty supply-chest slot so the turtle can
safely select an exact requested item before pulling it. Recognized coal,
charcoal, and coal blocks in turtle inventory are automatically consumed when
fuel is low.

## Main Tunnel Setup

Place the turtle over the orange anchor at the tunnel entrance. White points
into the tunnel and black is on the right when facing inward. Configure custom
dimensions and then start a job:

```text
setup tunnel main north 5 4
tunnel main 32
```

Replace the direction and dimensions with the actual tunnel. Setup records the
current GPS coordinate as the entrance. The terminal warns when the expected
wool anchor is absent rather than silently assuming the physical marker exists.

## Flax Farm Setup

The farm turtle does not require wool or a physical marker. Its first verified
boot position becomes its home and return location.

For automatic first-time discovery:

1. Place the turtle within eight blocks of the planted flax field and an output
   chest or Ender Chest.
2. Leave a clear route between the turtle, field, and chest.
3. Put a Geo Scanner, wireless modem, hoe, and coal in its inventory. Keep an
   Advanced Peripherals Chunk Controller equipped if the turtle must remain
   loaded without a nearby player. Seeds are optional for crops that support
   safe interaction harvesting.
4. Reboot and wait for the controller to assign its turtle name.
5. Run `farm <turtle-name> flax` from the controller or relay pocket.

An unknown farm ID triggers one Geo Scanner pass. The turtle groups nearby flax
blocks into a rectangle, rejects sparse wild patches, chooses the nearest chest
with a free approach cell, saves the farm, restores its modem, and begins work.
Later cycles use the saved definition and do not need another scan unless the
map is removed or changed. A turtle discovering a new area needs temporary
access to a Geo Scanner, but it does not keep the scanner equipped while
reporting.

The crop movement plane is one block above the crop blocks so `inspectDown`,
`digDown`, and `placeDown` operate on each plant. Automatic discovery calculates
that height from the scan.

The farmer keeps the chunk loader equipped on one side and the modem on the
other. The hoe stays in inventory and is selected for `placeDown`; it does not
need to remain a turtle upgrade for right-click harvesting. The Geo Scanner or
a digging tool temporarily replaces only the modem and restores it immediately.
If the same plant remains and its age resets, that non-destructive harvest mode
is saved and no replant seed is required. If interaction harvesting is
unsupported, the turtle leaves the plant intact and requests a seed before
using dig-and-replant mode.

Supplementaries flax is handled as a two-block crop. The turtle travels above
the upper half, uses its hoe to trigger ATM10's right-click harvest, collects
the lower-half seed drops, and replants from the temporarily empty upper cell
when the pack does not replant automatically. It never mines the upper half,
because Supplementaries assigns flax and seed drops only to the lower half.

Automatic discovery defaults to mature age 7. If `inspect down` shows another
maximum age or the seed registry name needs correction, rerun with overrides:

```text
farm <turtle-name> flax <mature-age> <seed-name>
```

First inspect a mature flax plant and a seed stack because ATM10 can contain
different flax implementations:

```text
inspect down
inspect item
```

Record the exact block name, seed item name, and mature `state.age`. With the
turtle over the first crop cell, configure and run the farm:

```text
setup farm flax 3 3 south <crop-name> <seed-name> <mature-age> base-service
farm flax
```

The farmer follows a checkpointed serpentine path, harvests only mature crops,
replants immediately, unloads to the discovered chest, and returns home. A
missing hoe reports `NEEDS_TOOL`; missing seeds for a dig-and-replant crop report
`NEEDS_SUPPLIES`; an absent scanner reports `NEEDS_SCANNER`; and a missing/full
output chest reports `NEEDS_OUTPUT`.

Without a registered service station, the farmer uses only onboard fuel, tool,
and seeds. Failures appear on the controller and are broadcast to the relay
pocket with the turtle name. The controller retains the latest 100 failures, and
an enabled pocket automatically displays the latest 10 after reconnecting.
Registered tool, seed, and fuel chests can be added later without changing the
discovered farm.

## Geo Scanner Survey

Put an Advanced Peripherals Geo Scanner in a turtle inventory and run `survey`
with an optional radius up to eight blocks. The worker swaps the scanner in,
records exact wool patterns and chest candidates, and returns the observation to
the controller. `surveys` displays persisted results. Surveys never change room
or tunnel intent automatically; use the setup commands to approve names,
dimensions, and roles.

## First Test

1. Start the deployment PC and upload both mining targets.
2. Install/reboot the mining PC and one turtle.
3. Give the turtle fuel, a modem, and a configured pickaxe. If fuel is in its
   inventory, startup consumes recognized fuel automatically.
4. Ensure GPS works and one horizontal neighbor is open for heading detection.
5. At the mining PC run `turtles` and note the assigned turtle name.
6. Send a clear-path travel job:

   ```text
   travel <turtle-name> <x> <y> <z>
   ```

7. From a safe excavation start, run:

   ```text
   dig <turtle-name> east 8 service
   ```

8. Reboot during a longer tunnel to verify GPS recovery and cell-level resume.
9. Put red wool below an endpoint and verify a subsequent dig stops at CAP.

## Safety Summary

- GPS verifies physical position and heading at boot.
- All movement passes through `lib/nav.lua` and is persisted transactionally.
- Unexplained displacement requires explicit `worker recover` approval.
- Worker and map state use validated primary, temporary, previous, and backup
  generations.
- Tunnel jobs checkpoint depth and cross-section cell.
- Farm jobs checkpoint every cell and replant before advancing.
- Service stations separate externally stocked supplies from storage output.
- Oriented wool patterns provide visible physical recovery references.
- Floor marker differences become player commands or repair tasks.
- Deployment downloads are staged and syntax-checked before application files
  are replaced.
