FROM node:20-bookworm-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY server/package*.json server/
RUN cd server && npm ci
COPY control/package*.json control/
RUN cd control && npm ci
COPY protocol protocol
COPY server/tsconfig.json server/
COPY server/src server/src
COPY control/tsconfig.json control/index.html control/
COPY control/src control/src
RUN cd server && npm run build && npm prune --omit=dev
RUN cd control && npm run build

FROM node:20-bookworm-slim
ENV NODE_ENV=production PORT=8080 DB_PATH=/app/data/relay.sqlite
WORKDIR /app
COPY --from=build /app/server/package.json server/package.json
COPY --from=build /app/server/node_modules server/node_modules
COPY --from=build /app/server/dist server/dist
COPY --from=build /app/control/dist control/dist
COPY --from=build /app/protocol protocol
RUN mkdir /app/data && chown node:node /app/data
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"
CMD ["node", "server/dist/index.js"]
