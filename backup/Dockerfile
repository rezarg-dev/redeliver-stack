FROM alpine:3.21

# The sqlite package is not pinned: Alpine removes old package versions from
# its repositories, so a pinned version would break the build a few months
# later. The base image tag keeps it within one Alpine release.
# hadolint ignore=DL3018
RUN apk add --no-cache sqlite

COPY --chmod=755 backup.sh /usr/local/bin/backup

ENTRYPOINT ["backup"]
