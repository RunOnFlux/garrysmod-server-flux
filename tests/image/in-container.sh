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
acf="${dir}/steamapps/appmanifest_4020.acf"
# /tmp/fake-slow: a long download (a stop must not wait for it). /tmp/fake-0x6: an update from an installed
# build fails with Steam's "state is 0x6" (exit code = the file's content) until the record is gone, as a fresh
# install over the top is what gets past it. /tmp/steamcmd-calls counts the runs.
echo run >>/tmp/steamcmd-calls
if [ -f /tmp/fake-slow ]; then sleep 30; exit 0; fi
if [ -f /tmp/fake-0x6 ] && [ -f "${acf}" ]; then
  echo "Error! App '4020' state is 0x6 after update job."
  exit "$(cat /tmp/fake-0x6)"
fi
mkdir -p "${dir}/garrysmod" "${dir}/steamapps"
echo '"AppState" { "appid" "4020" }' >"${acf}"
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
s.bind((socket.gethostbyname(socket.gethostname()), ${GAME_PORT:-31000}))
while True:
    d, a = s.recvfrom(4096)
    if len(d) > 25:
        s.sendto(b\"\\xff\\xff\\xff\\xffI\\x11n\\x00m\\x00f\\x00g\\x00\\x00\\x00\\x00\\x10\\x00\", a)
    else:
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

# --- Updates: the depotcache, "state is 0x6", a stop during a download -----------------------------------
# The Steam home's depotcache is a link onto the install volume (a redeploy keeps the manifests).
check "the depotcache is on the install volume" "0" "$(status test -L /root/.local/share/Steam/depotcache)"
check "and points into it" "/tmp/srv/flux-steam/depotcache" "$(readlink /root/.local/share/Steam/depotcache)"

# An installed build whose update fails with "state is 0x6" and exit 0: the old build must NOT just start;
# the install is redone once (fresh), which the stand-in accepts.
echo 0 >/tmp/fake-0x6
: >/tmp/steamcmd-calls
FLUX_SERVER_DIR=/tmp/srv GAME_PORT=31002 /opt/flux/flux-entrypoint.sh >/tmp/sup3.log 2>&1 &
sup3=$!
check "state 0x6 with exit 0 is a failure, not a started old build" "0" "$(status wait_for "grep -q 'updating as a new install' /tmp/sup3.log" 20)"
check "and the fresh install gets the server up" "0" "$(status wait_for "grep -q 'ready: the server answers on port 31002' /tmp/sup3.log" 30)"
check "the retry is not a validate (a fresh install, not a re-hash)" "1" "$(status grep -q 'with validate' /tmp/sup3.log)"
check "SteamCMD ran twice" "2" "$(wc -l </tmp/steamcmd-calls | tr -d ' ')"
kill -TERM "${sup3}"
wait "${sup3}"
check "and it stops with 0" "0" "$?"
rm -f /tmp/fake-0x6

# A stop in the middle of a download: the supervisor ends at once with 0, not after Docker's 10 s kill.
touch /tmp/fake-slow
rm -rf /tmp/srv4
FLUX_SERVER_DIR=/tmp/srv4 GAME_PORT=31003 /opt/flux/flux-entrypoint.sh >/tmp/sup4.log 2>&1 &
sup4=$!
check "a slow update is under way" "0" "$(status wait_for "[ -s /tmp/steamcmd-calls ] && grep -q 'updating the server from Steam' /tmp/sup4.log" 10)"
sleep 1
t0="$(date +%s)"
kill -TERM "${sup4}"
wait "${sup4}"
rc4=$?
check "a stop during the download exits 0, not 42" "0" "${rc4}"
check "within a few seconds" "0" "$(status test $(($(date +%s) - t0)) -le 5)"
check "and says it was stopped before the server started" "0" "$(status grep -q 'stopped on request before the server started' /tmp/sup4.log)"
check "SteamCMD is not left running" "1" "$(status pgrep -x steamcmd)"
rm -f /tmp/fake-slow

# --- The daily restart: GMOD_RESTART_TIME, on an empty server ------------------------------------------
# A time about a minute away, 0 humans (the stand-in answers the challenge with an info of 0 players).
rm -rf /tmp/srv5
soon="$(date -u -d '+65 seconds' +%H:%M)"
FLUX_SERVER_DIR=/tmp/srv5 GAME_PORT=31004 GMOD_RESTART_TIME="${soon}" FLUX_RESTART_WAIT_MINUTES=1 /opt/flux/flux-entrypoint.sh >/tmp/sup5.log 2>&1 &
sup5=$!
check "the first generation is ready" "0" "$(status wait_for "grep -q 'ready: the server answers on port 31004' /tmp/sup5.log" 30)"
check "the next restart time is published for the panel" "0" "$(status test -s /tmp/flux-next-restart)"
check "at the set time an empty server is restarted as planned" "0" "$(status wait_for "grep -q 'planned: the daily restart: restarting the server' /tmp/sup5.log" 150)"
check "in place, as a restart someone asked for" "0" "$(status wait_for "grep -q 'planned: the daily restart (${soon} UTC): restarting the server in place' /tmp/sup5.log" 20)"
check "and the next generation comes up" "0" "$(status wait_for "[ \"\$(grep -c 'ready: the server answers on port 31004' /tmp/sup5.log)\" -ge 2 ]" 30)"
check "it does not count against the crash budget" "1" "$(status grep -q 'restarts within' /tmp/sup5.log)"
kill -TERM "${sup5}"
wait "${sup5}"
check "and stops with 0" "0" "$?"
check "a bad restart time is said and ignored" "0" "$(status grep -q "GMOD_RESTART_TIME='25:99' is not HH:MM" <<<"$(FLUX_SERVER_DIR=/tmp/srv5 GAME_PORT=31005 GMOD_RESTART_TIME=25:99 timeout 8 /opt/flux/flux-entrypoint.sh 2>&1)")"
pkill -f 'srcds_linux|script -qfec' 2>/dev/null

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/tmp/srv
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "/tmp/srv/garrysmod/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q "Garry's Mod server image by FluxCloud - https://runonflux.com" /tmp/sup.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/sup.log)" -ge 2 ] && echo 1 || echo 0)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
