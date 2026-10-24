FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
ENV NODE_ENV=production PORT=3400 HOST=0.0.0.0 DATA_DIR=/data MAX_USERS=50
USER node
EXPOSE 3400
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:3400/api/health || exit 1
CMD ["node", "server.js"]
