# syntax=docker/dockerfile:1

# Microsoft's official Dev Containers base. Ships Node and a non-root `node`
# user, so we inherit upstream's patching cadence instead of curating a distro.
ARG VARIANT=22-trixie
FROM mcr.microsoft.com/devcontainers/javascript-node:${VARIANT}

# Pinned so a rebuild is reproducible. Bump deliberately.
ARG OPENCODE_VERSION=1.18.30
ARG BUN_VERSION=1.4.2

# iptables/ipset/dnsutils back the egress allowlist; aggregate collapses the
# GitHub CIDR list; jq parses api.github.com/meta; unzip unpacks the Bun release.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        dnsutils \
        iproute2 \
        aggregate \
        jq \
        curl \
        ca-certificates \
        git \
        less \
        unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# opencode's official npm distribution.
RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force

# Bun, pinned to match the host toolchain. opencode is a Bun-native project and
# the workspaces run here are bun-first, so parity matters more than image size.
ENV BUN_INSTALL=/usr/local/bun
ENV PATH=${BUN_INSTALL}/bin:${PATH}
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" \
    && chmod -R a+rx "${BUN_INSTALL}" \
    && bun --version

# The firewall needs root via iptables; the agent itself must never have it.
# Narrow sudoers entry so `node` may run the firewall script and nothing else.
# (Used by the Dev Containers path; the Compose path drops root via setpriv.)
COPY init-firewall.sh entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
    && echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh' \
        > /etc/sudoers.d/init-firewall \
    && chmod 0440 /etc/sudoers.d/init-firewall

# XDG paths opencode reads config from and writes state to.
ENV XDG_CONFIG_HOME=/home/node/.config \
    XDG_DATA_HOME=/home/node/.local/share
RUN mkdir -p "$XDG_CONFIG_HOME/opencode" "$XDG_DATA_HOME/opencode" \
    && chown -R node:node /home/node/.config /home/node/.local

USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["opencode"]
