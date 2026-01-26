# Example custom Dockerfile for migetpacks
# This demonstrates using a user-provided Dockerfile instead of auto-detection

FROM node:22-slim

WORKDIR /app

# Copy application files
COPY package.json ./
COPY index.js ./
COPY logo.png ./

# Install dependencies (if any)
RUN npm install --omit=dev 2>/dev/null || true

# Create non-root user (handle existing GID/UID 1000)
RUN (getent group 1000 || groupadd -g 1000 miget) && \
    (id -u 1000 &>/dev/null || useradd -u 1000 -g 1000 -m miget)
RUN chown -R 1000:1000 /app
USER 1000

EXPOSE 5000
ENV PORT=5000

CMD ["node", "index.js"]
