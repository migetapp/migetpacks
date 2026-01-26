# migetpacks - Auto-detecting buildpacks for container images
# Built by miget.com - https://miget.com
# Uses miget/container-os which comes with dockerd out of the box

FROM miget/container-os:latest

# Install only packages not already in container-os + yq for YAML parsing
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    jq \
    unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH} -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Configure Docker daemon with IPv6 support
COPY etc/docker/daemon.json /etc/docker/daemon.json

# Copy buildpack files and make executable
WORKDIR /buildpack
COPY bin/ /buildpack/bin/
COPY lib/ /buildpack/lib/
COPY LICENSE *.md /buildpack/
RUN chmod +x /buildpack/bin/* /buildpack/lib/*

# Set buildpack directory
ENV BUILDPACK_DIR=/buildpack
ENV PORT=5000

# Create workspace
WORKDIR /workspace

# Entry point for Shipwright
ENTRYPOINT ["/buildpack/bin/entrypoint"]
