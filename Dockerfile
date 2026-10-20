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

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/flux-launch.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console

RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/gmod/server", "/mnt/gmod/server/garrysmod"]

# One port: the game and the Steam query over UDP, RCON over TCP.
EXPOSE 27015/udp 27015/tcp

HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -f srcds_linux >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
