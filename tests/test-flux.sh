#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and the launch line. No Docker, no Steam, no game.
# Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# launch VAR=value...: the launch line with exactly these variables (warnings on stderr dropped).
launch() { env -i PATH="${PATH}" "$@" python3 scripts/flux-launch.py 2>/dev/null; }
warnings() { { env -i PATH="${PATH}" "$@" python3 scripts/flux-launch.py >/dev/null; } 2>&1; }

# --- Inputs ------------------------------------------------------------------------------------
check "27015 is a port" "27015" "$(flux_valid_port 27015)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a requested quit is not counted" "1" "$(status flux_restart_counts 'requested: the server quit (exit 0)')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"

# --- The launch line ---------------------------------------------------------------------------
check "defaults" "./srcds_run -game garrysmod -norestart -console -port 27015 +exec banned_user.cfg +maxplayers 16 +gamemode sandbox +map gm_construct" "$(launch)"
check "everything set, quoted values as one word with their quotes" \
  "./srcds_run -game garrysmod -norestart -console -port 31015 +exec banned_user.cfg +maxplayers 32 +gamemode terrortown +map ttt_67thway +host_workshop_collection 3528279840 +hostname '\"My TTT Server\"' +sv_password '\"pw\"' +rcon_password '\"rcon12345\"' +sv_setsteamaccount 0123456789ABCDEF0123456789ABCDEF +sv_region 3" \
  "$(launch GAME_PORT=31015 GMOD_MAXPLAYERS=32 GMOD_GAMEMODE=terrortown GMOD_MAP=ttt_67thway GMOD_WORKSHOP_COLLECTION=3528279840 GMOD_HOSTNAME='My TTT Server' GMOD_PASSWORD=pw GMOD_RCON_PASSWORD=rcon12345 GMOD_GSLT=0123456789ABCDEF0123456789ABCDEF GMOD_EXTRA_ARGS='+sv_region 3')"
check "a hostname with a quote is left out" "1" "$(status grep -q hostname <<<"$(launch GMOD_HOSTNAME='bad"name')")"
check "a password with a space is left out" "1" "$(status grep -q sv_password <<<"$(launch GMOD_PASSWORD='a b')")"
check "a gamemode that is not one word falls back" "0" "$(status grep -q '+gamemode sandbox' <<<"$(launch GMOD_GAMEMODE='dark rp')")"
check "players out of range fall back" "0" "$(status grep -q '+maxplayers 16' <<<"$(launch GMOD_MAXPLAYERS=500)")"
check "a bad port falls back" "0" "$(status grep -q -- '-port 27015' <<<"$(launch GAME_PORT=80)")"
check "extra args may not set the port" "1" "$(status grep -q 'sv_lan' <<<"$(launch GMOD_EXTRA_ARGS='+sv_lan 0 -port 1')")"
# shellcheck disable=SC2016  # the $(...) is the payload, on purpose not expanded
check "a shell metacharacter stays an argument" "0" "$(status grep -qF "'\$(reboot)'" <<<"$(launch GMOD_EXTRA_ARGS='$(reboot)')")"
check "no RCON password is said" "0" "$(status grep -q 'RCON stays off' <<<"$(warnings)")"
check "a bad token is said and left out" "0" "$(status grep -q 'GMOD_GSLT' <<<"$(warnings GMOD_GSLT=nope)")"

# The line, run through a shell the way `script -c` runs it, reaches srcds as these words.
words="$(bash -c "printf '[%s]' $(launch GMOD_HOSTNAME='Flux Test Server' GMOD_RCON_PASSWORD=abc12345)")"
check "the shell hands srcds the quoted name as one word" "0" "$(status grep -qF '[+hostname]["Flux Test Server"]' <<<"${words}")"

# --- The health probe: Steam A2S against a fake server -------------------------------------------
# A UDP socket on a free port that answers with whatever it is told to: the info (0x49), the
# challenge newer srcds sends first (0x41), garbage, or nothing at all.
a2s_port="$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
fake_a2s() { # reply (python bytes literal, or "none"), then probe once
  python3 - "$1" "${a2s_port}" <<'PY' &
import socket, sys
reply, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port))
s.settimeout(8)
try:
    data, addr = s.recvfrom(4096)
    if data.startswith(b"\xff\xff\xff\xffTSource Engine Query\x00") and reply != "none":
        s.sendto(eval(reply), addr)
except OSError:
    pass
PY
  fake=$!
  sleep 0.4
  python3 scripts/flux-a2s.py "${a2s_port}" >/dev/null 2>&1
  rc=$?
  kill "${fake}" 2>/dev/null; wait "${fake}" 2>/dev/null
  echo "${rc}"
}
check "a server that answers with its info is up" "0" "$(fake_a2s 'b"\xff\xff\xff\xffI\x11name\x00"')"
check "a server that answers with a challenge is up" "0" "$(fake_a2s 'b"\xff\xff\xff\xffA\x01\x02\x03\x04"')"
check "an answer that is not Source is not a server" "1" "$(fake_a2s 'b"HTTP/1.1 400"')"
check "a socket that never answers is not a server" "1" "$(fake_a2s none)"
check "a closed port is not a server" "1" "$(python3 scripts/flux-a2s.py "${a2s_port}" >/dev/null 2>&1; echo $?)"
# The addresses it asks: the kernel's table, loopback first, the container's own after it.
cat >"${tmp}/fib_trie" <<'FIB'
Main:
  +-- 0.0.0.0/0 3 0 5
     +-- 127.0.0.0/8 2 0 2
        |-- 127.0.0.1
           /32 host LOCAL
     +-- 172.17.0.0/16 2 0 2
        |-- 172.17.0.4
           /32 host LOCAL
        |-- 172.17.255.255
           /32 link BROADCAST
FIB
check "the container's own address is asked, after the loopback" "127.0.0.1 172.17.0.4" "$(python3 -c "
import importlib.util as u, socket, sys
sp = u.spec_from_file_location('a', 'scripts/flux-a2s.py'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
socket.gethostbyname = lambda _h: '172.17.0.4'
print(' '.join(m.local_addresses(sys.argv[1])))" "${tmp}/fib_trie")"
check "an unreadable table still asks the loopback" "127.0.0.1" "$(python3 -c "
import importlib.util as u, socket
sp = u.spec_from_file_location('a', 'scripts/flux-a2s.py'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
def boom(_h): raise OSError
socket.gethostbyname = boom
print(' '.join(m.local_addresses('/nonexistent')))")"
gp() { python3 -c "import sys; sys.path.insert(0, 'scripts'); import importlib.util as u; sp = u.spec_from_file_location('a', 'scripts/flux-a2s.py'); m = u.module_from_spec(sp); sp.loader.exec_module(m); print(m.game_port(sys.argv[1]))" "$1"; }
check "the probe asks the port the launcher binds" "31015" "$(gp 31015)"
check "an empty GAME_PORT is 27015" "27015" "$(gp '')"
check "a bad GAME_PORT is the launcher's fallback" "27015" "$(gp 80)"
check "a word is the launcher's fallback" "27015" "$(gp abc)"

# --- The entrypoint: launcher warnings never reach the launch line --------------------------------
# The real launch-building lines of start_generation, run with a launcher that warns on stderr. A
# process substitution inside $(...) would write the logged warning into the launch line.
# shellcheck disable=SC2016
block="$(sed -n '/^  launch="\$(python3/,/^  fi$/p' scripts/flux-entrypoint.sh)"
# shellcheck disable=SC2329
(
  python3() { echo "./srcds_run_64 -game garrysmod"; echo "launch warning: bad value" >&2; }
  flux_log() { echo "LOG $*" >>"${tmp}/entry.log"; echo "$*"; }
  launch=""
  eval "${block//return 1/true}"
  printf '%s' "${launch}" >"${tmp}/launch.out"
) >/dev/null
captured="$(cat "${tmp}/launch.out")"
check "the warning is still logged" "LOG launch: launch warning: bad value" "$(cat "${tmp}/entry.log")"
check "launcher warnings stay out of the launch line" "./srcds_run_64 -game garrysmod" "${captured}"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
