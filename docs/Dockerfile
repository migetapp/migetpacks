FROM node:22-slim

# Install mintlify globally (pinned version - same as miget-mintlify)
RUN npm i -g mintlify@4.2.255

WORKDIR /app

# Copy docs content
COPY . .

# Expose port
EXPOSE 5000

# Run mintlify dev
CMD ["npx", "mintlify", "dev", "--port", "5000"]
