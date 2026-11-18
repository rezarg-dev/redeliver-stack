# syntax=docker/dockerfile:1

# hadolint does not know about named build contexts and reports every
# "COPY --from=source" as a reference to an undefined stage.
# hadolint global ignore=DL3022

# The application source is not part of this repository. It comes in through
# a named build context called "source", which compose.yaml points at the
# redeliver git repository. To build without compose:
#
#   docker build --build-context source=https://github.com/rezarg-dev/redeliver.git#main app

# ---- dependencies ----------------------------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app

# Only the manifests are copied here, so this layer is rebuilt when the
# dependencies change and not on every source change.
COPY --from=source package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# ---- runtime ---------------------------------------------------------------
FROM node:22-alpine

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000 \
    DATABASE_PATH=/data/redeliver.db

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=source package.json ./
COPY --from=source src ./src
COPY --from=source scripts ./scripts

# The database lives in /data. Creating the directory with the right owner
# here means a fresh named volume mounted on it is writable by "node".
RUN mkdir /data && chown node:node /data
VOLUME /data

# The "node" user of the base image. Given as numbers so that a runtime can
# verify the container is not root without looking inside the image.
USER 1000:1000
EXPOSE 3000

# The image has no curl or wget on purpose; Node can do the request itself.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/healthz').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]

CMD ["node", "--disable-warning=ExperimentalWarning", "src/server.js"]
