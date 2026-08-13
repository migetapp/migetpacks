#!/bin/bash
# Startup script - runs once on container start via supervisord.
# The site itself is prerendered static files in /app/dist; this only
# handles runtime env overrides and the one-time search indexing.

# Check if already completed (in case of restart)
if [ -f /tmp/startup-complete ]; then
    echo "Startup already completed, skipping..."
    exit 0
fi

# Don't exit on error - be resilient
set +e

# Runtime robots.txt override for staging
if [ "$ALLOW_INDEXING" = "false" ]; then
    printf 'User-agent: *\nDisallow: /\n' > /app/dist/robots.txt
    echo "robots.txt: Indexing DISABLED (staging)"
fi

# Wait for Meilisearch
echo "Waiting for Meilisearch to start..."
until curl -s http://127.0.0.1:7700/health > /dev/null 2>&1; do
    sleep 2
done
echo "Meilisearch is ready"

# Index search content
echo "Indexing search content..."
cd /app && node index-search.js || echo "Search indexing failed"

# Wait for nginx to be ready
echo "Waiting for Nginx..."
until curl -s http://127.0.0.1:5000/health > /dev/null 2>&1; do
    sleep 1
done
echo "Nginx is ready"

echo "Startup complete!"

# Mark startup as complete
touch /tmp/startup-complete
