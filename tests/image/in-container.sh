#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill script mkfifo timeout tail sed; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-launch.py runs" "0" "$(status python3 /opt/flux/flux-launch.py)"
check "flux-a2s.py is in the image and says no when nothing answers" "1" "$(status python3 /opt/flux/flux-a2s.py 31999)"
for script in flux-entrypoint.sh flux-console.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the 32-bit C++ runtime srcds needs is installed" "0" "$(status test -e /usr/lib32/libstdc++.so.6)"

# --- The supervisor, around a stand-in Steam and a stand-in srcds ------------------------------
# The stand-in behaves like srcds where it matters: it only reads its console from a TERMINAL
# (the reason the image runs it under `script`) and only prints to one, answers `say`, and ends
# with 0 on `quit`; `crash` ends it with 139.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/garrysmod"
echo 260917 >"${dir}/garrysmod/garrysmod.ver"
cat >"${dir}/srcds_run" <<'GAME'
#!/bin/bash
exec -a srcds_linux bash -c '
[ -t 0 ] && [ -t 1 ] || { sleep 1000; exit 1; }
echo "args: $*"
echo "VAC secure mode is activated."
if [ -z "${STUB_SILENT:-}" ]; then
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# Like srcds: the address of the container itself, not 0.0.0.0 and not the loopback.
s.bind((socket.gethostbyname(socket.gethostname()), 31000))
while True:
    _, a = s.recvfrom(4096)
    s.sendto(b\"\\xff\\xff\\xff\\xffA\\x01\\x02\\x03\\x04\", a)
" &
  trap "kill $! 2>/dev/null" EXIT
fi
while IFS= read -r line; do
  case "${line}" in
    say\ *) echo "Console: ${line#say }" ;;
    quit) echo "quitting"; exit 0 ;;
    crash) exit 139 ;;
    *) echo "Unknown command \"${line}\"" ;;
  esac
done' srcds_linux "$@"
GAME
chmod +x "${dir}/srcds_run"
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_SERVER_DIR=/tmp/srv FLUX_RESTART_BACKOFF=1
logs=/tmp/srv/garrysmod/flux/logs
GMOD_HOSTNAME='Test Server' GMOD_RCON_PASSWORD=abc12345 GAME_PORT=31000 FLUX_GAME_LOG_MAX_BYTES=400 FLUX_GAME_LOG_KEEP=3 \
  /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "srcds comes up under a terminal and its console reaches the log" "0" "$(status wait_for "grep -qh 'VAC secure' ${logs}/*-console.log 2>/dev/null" 20)"
check "the launch line arrives as words, the quoted name as one" "0" "$(status grep -qh 'args: -game garrysmod -norestart -console -port 31000 +exec banned_user.cfg' ${logs}/*-console.log)"
check "the quoted name" "0" "$(status grep -qh '+hostname "Test Server"' ${logs}/*-console.log)"
check "the console reaches the container output too" "0" "$(status grep -q 'VAC secure' /tmp/sup.log)"
check "the build is logged" "0" "$(status grep -q "Garry's Mod build 260917" /tmp/sup.log)"
check "the server answering the Steam query is said in the log" "0" "$(status wait_for "grep -q 'ready: the server answers on port 31000' /tmp/sup.log" 20)"
check "the health probe says yes while it answers" "0" "$(status python3 /opt/flux/flux-a2s.py 31000)"
check "flux-console reaches the console and prints the answer" "0" "$(status grep -q 'Console: hi there' <<<"$(flux-console say hi there)")"

for n in 1 2 3 4 5 6 7 8; do flux-console say "filler line number ${n} to roll the log over" >/dev/null; done
check "the console log is rotated and pruned" "1" "$(status test "$(find "${logs}" -name '*-console.log' | wc -l)" -gt 3)"

# A crash: restarted in place.
flux-console crash >/dev/null
check "a crash is restarted in place" "0" "$(status wait_for "grep -q 'restarting the server in place' /tmp/sup.log" 10)"
check "and the new server comes up" "0" "$(status wait_for "grep -q 'generation 2' /tmp/sup.log" 10)"
check "each generation says when it is ready" "0" "$(status wait_for "[ \"\$(grep -c 'ready: the server answers' /tmp/sup.log)\" -ge 2 ]" 20)"
check "the crash is reported with its code" "0" "$(status grep -q 'exit 139' /tmp/sup.log)"
sleep 2

kill -TERM "${sup}"
wait "${sup}"
check "a stop exits 0" "0" "$?"
check "a stop is a console quit" "0" "$(status grep -q 'stopped on request (server exited 0)' /tmp/sup.log)"
check "nothing is left running" "1" "$(status pgrep -f 'srcds_linux|script -qfec')"

# A server that never answers (the Workshop download, the map load) is never called ready, and the
# probe says no.
rm -rf /tmp/srv2
FLUX_SERVER_DIR=/tmp/srv2 STUB_SILENT=1 GAME_PORT=31001 /opt/flux/flux-entrypoint.sh >/tmp/sup2.log 2>&1 &
sup2=$!
check "a silent server is up" "0" "$(status wait_for "grep -q 'VAC secure' /tmp/sup2.log" 20)"
sleep 6
check "and is not called ready" "1" "$(status grep -q 'ready: the server answers' /tmp/sup2.log)"
check "and the health probe says no" "1" "$(status python3 /opt/flux/flux-a2s.py 31001)"
kill -TERM "${sup2}"
wait "${sup2}"
check "and it still stops on a console quit, exit 0" "0" "$?"
check "with the quit and not a kill" "0" "$(status grep -q 'stopped on request (server exited 0)' /tmp/sup2.log)"
check "nothing is left running after it" "1" "$(status pgrep -f 'srcds_linux|script -qfec')"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/tmp/srv
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "/tmp/srv/garrysmod/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q "Garry's Mod server image by FluxCloud - https://runonflux.com" /tmp/sup.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/sup.log)" -ge 2 ] && echo 1 || echo 0)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
