FROM node:22-slim

ARG API_URL=http://localhost:5001

WORKDIR /app
COPY package.json index.js ./

ENV API_URL=$API_URL

# Create non-root user (handle existing GID/UID 1000)
RUN (getent group 1000 || groupadd -g 1000 miget) && \
    (id -u 1000 &>/dev/null || useradd -u 1000 -g 1000 -m miget)
RUN chown -R 1000:1000 /app
USER 1000

EXPOSE 5000
ENV PORT=5000

CMD ["node", "index.js"]
