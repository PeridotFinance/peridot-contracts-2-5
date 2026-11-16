# DLMM keeper image (its own image, its own Droplet role). The role is the CONFIGURATION (DLMM_KEEPER_CONFIG) and the secrets injected by the host:
# the RPC endpoint (environment), the keystore file and the password FILE (mounted).
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json tsconfig.build.json ./
RUN npm ci --ignore-scripts
COPY src ./src
RUN npm run build:prod

FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY scripts/entrypoint.sh scripts/host-config.js ./scripts/
COPY config ./config
# state (exit marker, send history, PENDING marker, backoff, alert state) AND the HALT file must live on a PERSISTENT disk: mount it at /data
RUN mkdir -p /data && chown -R node:node /data /app
USER node
VOLUME ["/data"]
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["run"]
