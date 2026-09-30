# syntax=docker/dockerfile:1
# Linux AMD64 manifest of node:24.21.0-alpine. Alpine instead of Debian slim:
# far fewer OS packages, so far fewer inherited vulnerabilities.
# Build with --platform linux/amd64.
ARG NODE_IMAGE=node:24.21.0-alpine@sha256:83f1c388c31fb2e51f7cbd4dea949b96260798c98f206e8e4696bc93bd964e3a

FROM ${NODE_IMAGE} AS dependencies
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force

FROM ${NODE_IMAGE}
ENV NODE_ENV=production PORT=3000
# Trust store for managed PostgreSQL TLS; override DB_CA_FILE to use another CA.
ENV DB_CA_FILE=/app/certs/rds-global-bundle.pem
WORKDIR /app
COPY package.json ./
COPY --from=dependencies /app/node_modules ./node_modules
COPY app.js ./
COPY bin ./bin
COPY lib ./lib
COPY scripts ./scripts
COPY certs ./certs
# Files stay root-owned and read-only to the runtime user.
USER node
EXPOSE 3000
STOPSIGNAL SIGTERM
# Node runs as PID 1 with its own SIGTERM/SIGINT handlers; no shell wrapper.
ENTRYPOINT ["node", "bin/www"]
