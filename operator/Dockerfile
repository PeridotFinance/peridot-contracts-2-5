# Operator / treasury-keeper image. One image, three roles: the role is the CONFIGURATION (OPERATOR_CONFIG) and the secrets injected by the host.
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json tsconfig.build.json ./
RUN npm ci --ignore-scripts
COPY src ./src
COPY scripts ./scripts
RUN npm run build:prod

FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY scripts/entrypoint.sh ./scripts/entrypoint.sh
COPY config ./config
# state (monitor index, alert state, keeper / executor ledgers and halt flags) must live on a PERSISTENT disk: mount it at /data
RUN mkdir -p /data /run/secrets && chown -R node:node /data /run/secrets /app
USER node
VOLUME ["/data"]
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["run"]
