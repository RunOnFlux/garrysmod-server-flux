#!/bin/bash
# PID 1, and the supervisor of the Garry's Mod server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on its
# own is followed by the next one in place:
#
#   - every start: SteamCMD update, the launch line from the environment (flux-launch.py), then
#     srcds in a PSEUDO-TERMINAL fed by a FIFO. srcds only writes its console to a terminal: run
#     plainly in a container it goes silent once the map is up (the previous image did, measured),
#     so the platform's log showed nothing past the start. Here every console line reaches the
#     container's output and a rotated log on the game volume
#   - SIGTERM/SIGINT from Docker: `quit` on the console (sv.db and the ban list are on disk already)
#   - the server ending on its own: a new generation in the same container, updated first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# Same shape as runonflux/unturned-server-flux and runonflux/7dtd-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-30}"

s="${FLUX_SERVER_DIR}"
g="${FLUX_GAME_DIR}"

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${g}" "$(dirname "${FLUX_LOG}")" "${FLUX_GAME_LOG_DIR}"

if ! port="$(flux_valid_port "${GAME_PORT:-27015}")"; then
  flux_log "ERROR GAME_PORT='${GAME_PORT:-}' is not a port from 1024 to 65535; refusing to start"
  exit 42
fi
export GAME_PORT="${port}"
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, port ${port})"

game_pid=""
game_rc=0
terminating=0
generation=0
restart_history=()

rm -f "${FLUX_CONSOLE_FIFO}"
mkfifo -m 600 "${FLUX_CONSOLE_FIFO}"
exec 3<>"${FLUX_CONSOLE_FIFO}"

stop_server() {
  [ -n "${game_pid}" ] || return 0
  if ! printf 'quit\n' >&3; then
    flux_log "WARN the console did not take the command; stopping the server with a signal"
    kill -TERM "${game_pid}" 2>/dev/null
  fi
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested ($1): quitting the server, no restart will follow"
  stop_server
}
trap 'term_handler TERM' TERM
trap 'term_handler INT' INT

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/srcds_run" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  # No `validate` on the first attempt: it re-hashes the whole 7 GB install, and would put back
  # stock files the owner changed in the game folder. A broken install fails the first attempt,
  # and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086  # validate is "" or "validate"
    if steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" ${validate} +quit; then
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    sleep 5
  done
  if [ -x "${s}/srcds_run" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# The console, line by line: carriage returns and terminal escapes dropped, onto the container's
# output and into the current log file, which is rotated at FLUX_GAME_LOG_MAX_BYTES.
# shellcheck disable=SC2329  # used in a process substitution below
console_writer() {
  local line file bytes=0
  file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
  : >"${file}"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    # shellcheck disable=SC2001  # a regex, not a fixed string
    line="$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<<"${line}")"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >>"${file}"
    bytes=$((bytes + ${#line} + 1))
    if [ "${bytes}" -ge "${FLUX_GAME_LOG_MAX_BYTES}" ]; then
      file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
      : >"${file}"
      bytes=0
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
    fi
  done
}

start_generation() {
  local launch line build
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" "${FLUX_EXIT_FILE}"

  update_server || return 1
  [ "${terminating}" = "1" ] && return 2

  # The build, for the panel's Overview: garrysmod.ver names it.
  build="$(tr -dc '0-9.\n' <"${g}/garrysmod.ver" 2>/dev/null | head -1)"
  [ -n "${build}" ] && flux_log "Garry's Mod build ${build}"

  launch="$(python3 /opt/flux/flux-launch.py 2> >(while IFS= read -r line; do flux_log "launch: ${line}"; done))"
  if [ -z "${launch}" ]; then
    flux_log "ERROR could not build the launch line"
    return 1
  fi
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  flux_log "starting the server (generation ${generation})"
  (
    cd "${s}" || exit 1
    export TERM=xterm
    # srcds' own exit code goes to a file: `script` itself does not end when srcds does (it goes
    # on reading the FIFO, which never closes), so the supervisor watches srcds and ends `script`.
    exec script -qfec "${launch}; echo \$? >${FLUX_EXIT_FILE}" /dev/null <"${FLUX_CONSOLE_FIFO}"
  ) > >(console_writer) 2>&1 &
  game_pid=$!
  return 0
}

sweep_generation() {
  pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
  game_pid=""
}

# Waits for srcds to end. `script` outlives it (see start_generation), so srcds is what is
# watched: once it has run and is gone, `script` is ended too. A requested stop or restart that is
# not honoured within FLUX_STOP_GRACE ends the server by force; the grace runs from when the
# request was first seen. Sets game_rc to srcds' exit code (143 when it had to be killed).
wait_for_generation() {
  local asked_at=0 now seen=0 killed=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if pgrep -f "${FLUX_GAME_PROCESS}" >/dev/null 2>&1; then
      seen=1
    elif [ "${seen}" = "1" ] || [ -f "${FLUX_EXIT_FILE}" ]; then
      # KILL, not TERM: with srcds gone `script` has nothing left to pass on, and it ignores a
      # TERM while it spins on the FIFO (measured: 97% CPU, still running ten minutes later).
      kill -KILL "${game_pid}" 2>/dev/null
      break
    fi
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
        kill -KILL "${game_pid}" 2>/dev/null
        killed=1
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
  if [ "${killed}" = "1" ]; then
    game_rc=143
  else
    game_rc="$(tr -dc '0-9' <"${FLUX_EXIT_FILE}" 2>/dev/null)"
    [ -n "${game_rc}" ] || game_rc=1
  fi
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc="${game_rc}"

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  # srcds ends with 0 when it was told to quit (the console's quit, an admin's RCON quit): that is
  # a restart someone asked for.
  if [ -z "${reason}" ] && [ "${rc}" = "0" ]; then
    reason="requested: the server quit (exit 0)"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
