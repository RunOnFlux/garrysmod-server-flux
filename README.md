# garrysmod-server-flux

The Garry's Mod dedicated server image the [Flux](https://runonflux.io/) marketplace deploys:
`runonflux/garrysmod-server-flux`.

It runs the game's native Linux server (Steam app 4020, srcds), installed and updated with
SteamCMD on every start, under a small supervisor. Written from scratch; same family as
`runonflux/unturned-server-flux` and `runonflux/7dtd-server-flux`.

## Why it exists

The image the marketplace deployed before (ich777/steamcmd:garrysmod) could not do what the
marketplace sells:

| | Previous image | This image |
|---|---|---|
| Settings | One variable, `GAME_PARAMS`, expanded unquoted by the shell (word-split and globbed) | `GMOD_*` variables, validated one by one and quoted |
| The console in the logs | srcds writes its console only to a terminal: once the map was up the container log went silent, so the platform's Console tab showed nothing (measured) | srcds runs in a pseudo-terminal; every console line reaches the container's output |
| Log on the volume | `-condebug`'s `console.log`, appended to forever, inside the synced folder | `garrysmod/flux/logs/*-console.log`, 20 MB each, the newest 10 kept |
| Bans | Forgotten on restart unless the line said `+exec banned_user.cfg` | Always on the line |
| Console commands from inside | None | `flux-console <command>` prints the answer |
| `docker stop` | srcds killed | `quit` on the console: 1.4 s, exit 0 (measured) |
| Server crashes | srcds_run's own restart loop | Restarted in place, updated first; the container ends after 5 crashes in an hour (exit 42) |

## Configuration

The variable names are the ones the Flux games hub writes.

| Variable | Default | |
|---|---|---|
| `GMOD_HOSTNAME` | | `+hostname`: the name in the server browser (63 characters, no double quotes) |
| `GMOD_GAMEMODE` | `sandbox` | `+gamemode`: the gamemode's folder name (terrortown, darkrp...) |
| `GMOD_MAP` | `gm_construct` | `+map`, without .bsp |
| `GMOD_MAXPLAYERS` | `16` | `+maxplayers`, 2 to 128 |
| `GMOD_WORKSHOP_COLLECTION` | | `+host_workshop_collection`: a Workshop collection ID, downloaded on start (no API key needed) |
| `GMOD_PASSWORD` | | `+sv_password`, no spaces or quotes |
| `GMOD_RCON_PASSWORD` | | `+rcon_password`, no spaces or quotes. Without it RCON stays off |
| `GMOD_GSLT` | | `+sv_setsteamaccount`: a Steam game server token for App ID 4000 |
| `GMOD_EXTRA_ARGS` | | Anything else for the command line, as shell words. Not the port |
| `GAME_PORT` | `27015` | The port srcds binds: game and A2S over UDP, RCON over TCP |
| `SKIP_UPDATE` | | `true`: start the installed build without asking Steam |
| `FLUX_GAME_LOG_MAX_BYTES` / `FLUX_GAME_LOG_KEEP` | `20000000` / `10` | Console log rotation |
| `FLUX_STOP_GRACE` | `30` | Seconds a stop may take before srcds is killed |
| `FLUX_RESTART_MAX_ATTEMPTS` / `FLUX_RESTART_WINDOW` | `5` / `3600` | Crashes allowed per window before the container ends with 42 |

A value that cannot be passed safely is left out, and the supervisor's log says which and why;
the server starts on the rest. Gameplay cvars (sandbox limits, TTT, FastDL) belong in
`garrysmod/cfg/server.cfg`, which srcds runs on every map load and the image never touches.

## Volumes

| Path | What | On Flux |
|---|---|---|
| `/mnt/gmod/server` | The install, about 6 GB. Disposable: SteamCMD rebuilds it | `ml:` (local, never synced) |
| `/mnt/gmod/server/garrysmod` | The game folder: `cfg/` (server.cfg, the ban list), `data/`, `addons/`, `gamemodes/`, `maps/`, `sv.db`, and `flux/` (our log and the console logs) | primary, `g:` |
| `/mnt/gmod/server/garrysmod/cache` | Workshop downloads. Downloaded again on a new node | `ml:` |

The game folder is synced whole, its ~1.1 GB of stock .vpk files included: every customer file
lives somewhere in it, and naming them one by one does not fit Flux's 200-character mount string.

## Measured (2026-10-08, Garry's Mod 2026.09.17, build 260917)

- first start on empty volumes, the spec's layout: 6.9 GB from SteamCMD, A2S answering 209 s
  after start, a 21-addon Workshop collection mounted
- `docker stop`: 1.4 s to exit 0, through the console's `quit`
- `quit` over RCON: restarted in place in the same container
- a ban written with `banid` + `writeid` survived a restart
- RCON (`status`, `banid`, `writeid`, `listid`) and A2S on the bound port

## Development

```bash
./tests/test-flux.sh
docker build -t garrysmod-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A push to `main` tests, builds, tests the built image and publishes `:latest`, `:<VERSION>` and
`:<sha>`. FluxOS's image update service checks every running app's tag every six hours and
soft-redeploys onto a new image, so a published `:latest` reaches running servers within hours.

## Versions

- **1.0.1** (2026-10-19): the launcher's warnings no longer end up inside the launch line (a process
  substitution inside `$(...)` wrote its log lines into the captured result).
- **1.0.0** (2026-10-08): first release.
