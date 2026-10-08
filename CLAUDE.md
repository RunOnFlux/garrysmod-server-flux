# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Garry's Mod dedicated server for Flux,
`runonflux/garrysmod-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux server, and a
supervisor in bash. Same family as `~/work/unturned-server-flux` and `~/work/7dtd-server-flux`; read it for the patterns this one
follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. The game runs as a child so a stop becomes a save, and a
server that ends on its own is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t garrysmod-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, the launch line
  (flux-launch.py), srcds in a pseudo-terminal fed by the console FIFO, its output through the
  console writer (container output + rotated log). Watches srcds itself, not `script`.
- `scripts/flux-launch.py`: the GMOD_* variables -> the shell-quoted srcds command line. The one
  place the variable-to-argument table and its validation live.
- `scripts/flux-console.sh`: `flux-console <command>` on the PATH.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.

## Things that will bite you

- **srcds writes its console only to a terminal**, and reads it only from one. Hence `script -qfec
  … /dev/null`. What the pty prints is the console, with \r and the odd escape sequence, which the
  writer strips.
- **`script` does not end when srcds does**: it goes on reading the FIFO (which never closes) and
  spins, ignoring SIGTERM. srcds' exit code is written to a file by the command `script` runs, and
  the supervisor KILLs `script` once srcds is gone.
- **Run wait_for_generation in the main shell, never in `$(...)`**: the trap's `terminating` flag
  would not reach a subshell, and flux_log's output would be captured.
- **A quoted value is passed WITH its double quotes as one word**: srcds joins argv into one
  command line and parses the quotes itself.
- **srcds does not read its ban list on start**: `+exec banned_user.cfg` is always on the line.
- **Flux stops a container with Docker's default 10 seconds.** Console quit measured 1.4 s.
- **The unit tests run with the machine's Python, not the image's.** Anything a script newly needs
  gets a check in `tests/image/in-container.sh`.
