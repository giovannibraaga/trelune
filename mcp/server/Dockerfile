# Trelune MCP: Node only, no npm dependencies.
FROM node:24-alpine
WORKDIR /app
COPY server.mjs .
USER node
ENV NODE_USE_ENV_PROXY=1 DATA_DIR=/data
CMD ["node", "/app/server.mjs", "--daemon"]
