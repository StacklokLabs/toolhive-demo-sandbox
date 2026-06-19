# =============================================================================
# Stage 1: packages
# Create a minimal monorepo skeleton containing only package.json files.
# This layer is cached independently of source code changes.
# =============================================================================
FROM node:22-bookworm-slim AS packages

WORKDIR /app

COPY . .

# Remove everything except package.json from each workspace directory
RUN find packages plugins -mindepth 2 -maxdepth 2 \! -name "package.json" \
    -exec rm -rf {} + 2>/dev/null || true


# =============================================================================
# Stage 2: build
# Full build environment. Installs all deps, compiles TypeScript, and runs
# the Backstage backend bundler.
# =============================================================================
FROM node:22-bookworm-slim AS build

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        g++ \
        build-essential \
        libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --chown=node:node .yarn ./.yarn
COPY --chown=node:node .yarnrc.yml yarn.lock backstage.json ./

COPY --chown=node:node --from=packages /app/packages ./packages
COPY --chown=node:node --from=packages /app/plugins ./plugins
COPY --chown=node:node package.json ./

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn install --immutable

# Copy full source code
COPY --chown=node:node . .

RUN yarn tsc
RUN yarn build:backend --config ../../app-config.yaml


# =============================================================================
# Stage 3: runner
# Minimal production image with only runtime dependencies.
# =============================================================================
FROM node:22-bookworm-slim AS runner

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        g++ \
        build-essential \
        libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

COPY --chown=node:node .yarn ./.yarn
COPY --chown=node:node .yarnrc.yml backstage.json ./

ENV NODE_ENV=production

COPY --chown=node:node preload.js ./

ENV NODE_OPTIONS="--no-node-snapshot --require /app/preload.js"

COPY --chown=node:node --from=build /app/yarn.lock ./
COPY --chown=node:node --from=build /app/package.json ./
COPY --chown=node:node --from=build /app/packages/backend/dist/skeleton.tar.gz ./

RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz

RUN --mount=type=cache,target=/home/node/.cache/yarn,sharing=locked,uid=1000,gid=1000 \
    yarn workspaces focus --all --production && yarn cache clean

COPY --chown=node:node examples ./examples
COPY --chown=node:node templates ./templates

COPY --chown=node:node --from=build /app/packages/backend/dist/bundle.tar.gz ./
COPY --chown=node:node app-config.yaml app-config.production.yaml ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

EXPOSE 7007

CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
