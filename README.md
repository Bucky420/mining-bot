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
5. Optionally, drag both files from `drag-to-relay-pc/` onto a pocket computer.

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

## Controller Commands

```text
turtles
jobs
sites
travel <turtle> <x> <y> <z>
dig <turtle> <north|east|south|west> <length> [profile]
repair <turtle> <x> <y> <z> <marker-type>
survey <turtle> [radius]
farm <turtle> <farm-id> [mature-age] [seed-name]
tunnel <turtle> <tunnel-id> <length>
cancel <turtle>
retry [now|turtle-name]
help
```

Farm jobs support configured crops and seeds rather than a crop-specific
implementation. A farm can use a service station for fuel, tools, seeds, and
output, or operate from onboard supplies.

## Turtle Commands

```text
travel <x> <y> <z>
dig <north|east|south|west> <length> [profile]
farm <farm-id>
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

## Requirements

- Current CC:Tweaked
- Mining turtle or advanced mining turtle
- Wireless modem
- GPS coverage for verified startup recovery
- Advanced Peripherals Geo Scanner is optional

See the command help shown by the controller and worker for current setup
options.
