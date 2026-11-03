# Garry's Mod dedicated server image for Flux.
#
# Written from scratch. The game's native Linux server (Steam app 4020, srcds), installed and
# updated with SteamCMD on every start, under a supervisor that builds the launch line from the
# environment, runs srcds in a pseudo-terminal so its console reaches the logs (srcds writes
# nothing once the map is up without one), rotates those logs, quits cleanly on stop and restarts
# the server in place. See README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# srcds is a 32-bit program: it needs the 32-bit C and C++ runtimes. `script` (util-linux) gives
# it its terminal.
RUN dpkg --add-architecture i386 && apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 util-linux lib32gcc-s1 lib32stdc++6 libtinfo6:i386 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/flux-launch.py scripts/flux-a2s.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console

RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/gmod/server", "/mnt/gmod/server/garrysmod"]

# One port: the game and the Steam query over UDP, RCON over TCP.
EXPOSE 27015/udp 27015/tcp

# Healthy means the server ANSWERS the Steam query on its game port, which srcds only does after the
# Workshop collection is mounted and the map has loaded. (The check this replaces, `pgrep -f
# srcds_linux`, matched its own `sh -c` and was healthy from the first second.) The start period is
# long on purpose: a first start downloads about 7 GB and then the whole Workshop collection, and
# a few hundred addons take hours; a failure inside it does not count. It covers the CONTAINER's
# first start only: after an in-place restart (a crash, a console quit) the container is already
# healthy, and a long download then reads as unhealthy after about 2.5 minutes until the server
# answers again. Nothing on Flux acts on that (FluxOS ignores Docker health); the hub's readiness
# reads the log, not this.
HEALTHCHECK --interval=30s --timeout=10s --start-period=3h --retries=5 \
    CMD python3 /opt/flux/flux-a2s.py

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
