########## Stage 1: render the docs to a static bundle ##########
# Runs "mint dev" (a production Next.js server) and crawls it into /dist
# with staticmint. The runtime image never runs Mintlify.
FROM node:20-bookworm-slim AS export

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Mintlify CLI (the "mint" package; the old "mintlify" package is
# deprecated). Pinned: the CLI resolves its renderer ("client") version
# through https://releases.mintlify.com/mint-version-map.json, so a
# pinned CLI freezes the renderer once upstream stamps a max for it.
ARG MINT_VERSION=4.2.800
RUN npm i -g mint@${MINT_VERSION}

# staticmint crawls the mint dev preview into the static bundle
ARG STATICMINT_VERSION=v0.1.1
RUN arch="$(dpkg --print-architecture)" && \
    curl -fsSL -o /usr/local/bin/staticmint \
      "https://github.com/migetapp/staticmint/releases/download/${STATICMINT_VERSION}/staticmint-linux-${arch}" && \
    chmod +x /usr/local/bin/staticmint

WORKDIR /docs
COPY . .

ARG SITE_URL=https://migetpacks.com
# -wait-tries is high because the first "mint dev" run downloads the client bundle.
RUN staticmint -start-server -wait-tries 300 \
    -site-url "${SITE_URL}" -out /dist

########## Stage 2: static runtime (nginx + Meilisearch) ##########
FROM miget/container-os:latest

# Node.js is only needed for the one-time Meilisearch indexing at startup
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs nginx curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ARG MEILISEARCH_VERSION=v1.35.1
RUN arch="$(dpkg --print-architecture)" && \
    case "$arch" in arm64) arch=aarch64 ;; esac && \
    curl -fsSL -o /usr/bin/meilisearch \
      "https://github.com/meilisearch/meilisearch/releases/download/${MEILISEARCH_VERSION}/meilisearch-linux-${arch}" && \
    chmod +x /usr/bin/meilisearch

WORKDIR /app

# Source files (index-search.js reads docs.json for the title suffix)
COPY . .

# Meilisearch client for indexing (after COPY to ensure it's not overwritten)
RUN npm i meilisearch@0.33.0

# The rendered static site
COPY --from=export /dist /app/dist

# nginx + supervisord configuration
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord/*.conf /etc/supervisor/conf.d/

RUN chmod +x /app/scripts/startup.sh && \
    mkdir -p /data/meilisearch

# Expose the port
EXPOSE 5000
