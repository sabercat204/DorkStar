# ─── Stage 1: Builder ────────────────────────────────────────────────────────
# Installs all dependencies and builds the SvelteKit app with adapter-node.
FROM node:22-alpine AS builder

WORKDIR /app

# Copy package manifests first for layer caching
COPY package.json package-lock.json ./

# Install all dependencies (including devDependencies needed for the build)
RUN npm ci

# Copy the rest of the source
COPY . .

# Build with adapter-node so the output is a standalone Node.js server
ENV SVELTE_ADAPTER=node
RUN npm run build

# Prune devDependencies — only keep production deps for the final image
RUN npm prune --production

# ─── Stage 2: Production ─────────────────────────────────────────────────────
# Minimal runtime image with only the built output and production node_modules.
FROM node:22-alpine AS production

WORKDIR /app

# Install Playwright + Chromium for Tier 3 headless engine dispatch.
# Uses the Playwright CLI to download the browser and its system dependencies.
RUN apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    && npm install -g playwright@1.52.0 \
    && playwright install chromium --with-deps 2>/dev/null || true

# Copy built output from builder stage
COPY --from=builder /app/build ./build
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json

# Runtime environment
ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0

# Tell Playwright to use the system Chromium installed above
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 3000

# Health check — verifies the server is responding before marking container healthy
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD wget -qO- http://localhost:3000/ > /dev/null || exit 1

# SvelteKit adapter-node produces build/index.js as the server entry point
CMD ["node", "build/index.js"]
