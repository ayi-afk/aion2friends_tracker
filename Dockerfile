# syntax=docker/dockerfile:1
#
# AION 2 tracker in a minimal container.
#
# The image packs the fully static Linux binary built by build_linux.bat
# (build/linux/aion2tracker: musl, HTML + SQLite inside), so the final image is `scratch`
# with nothing but that binary — a few MB, no shell, no package manager.
#
#   build_linux.bat
#   docker build -t aion2tracker .
#   docker run -d --name aion2tracker -p 8080:8080 -e A2T_PASSWORD=secret -v aion2data:/data aion2tracker
#
# The admin panel (/admin/) is reachable through the published port only when a password is
# set (A2T_PASSWORD or --password); 5 wrong passwords block that IP for a minute.
# Without a password the admin panel only answers loopback connections, i.e. not via Docker.

# --- tiny stage that only prepares the directories scratch lacks (/tmp for imports/exports, /data)
FROM alpine:3.20 AS rootfs
RUN mkdir -p /rootfs/tmp /rootfs/data && chmod 1777 /rootfs/tmp

FROM scratch
COPY --from=rootfs --chown=65532:65532 /rootfs/tmp /tmp
COPY --from=rootfs --chown=65532:65532 /rootfs/data /data
COPY --chmod=755 build/linux/aion2tracker /aion2tracker

# the database (and its WAL files) live on this volume
VOLUME /data
EXPOSE 8080
# unprivileged user (no /etc/passwd needed for a numeric uid)
USER 65532:65532

ENTRYPOINT ["/aion2tracker", "--db", "/data/aion2tracker.db", "--port", "8080"]
# extra flags can be appended: docker run ... aion2tracker --interval 10
