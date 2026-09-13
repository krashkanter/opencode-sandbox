#!/usr/bin/env bash
#
# Raise the firewall while we still have root, then permanently drop to an
# unprivileged user and exec the agent. setpriv rather than sudo: sudo relies on
# setuid escalation, which `no-new-privileges` (correctly) forbids.
set -euo pipefail

RUN_AS="${RUN_AS_USER:-node}"

start_firewall() {
    if [[ "${ENABLE_FIREWALL:-1}" != "1" ]]; then
        echo "[entrypoint] WARNING: ENABLE_FIREWALL=0 — egress is unrestricted." >&2
        return 0
    fi
    if /usr/local/bin/init-firewall.sh; then
        return 0
    fi
    echo "[entrypoint] firewall failed to initialise." >&2
    # Fail closed. Running the agent unsandboxed is the exact thing being avoided.
    if [[ "${FIREWALL_REQUIRED:-1}" == "1" ]]; then
        echo "[entrypoint] refusing to start. Set FIREWALL_REQUIRED=0 to override." >&2
        exit 1
    fi
}

if [[ "$(id -u)" -eq 0 ]]; then
    # Compose path: root at entry purely to program netfilter.
    start_firewall

    # setpriv changes uid/gid but leaves the environment alone, so HOME would
    # stay /root and opencode would write its config and state somewhere the
    # unprivileged user cannot read.
    home_dir=$(getent passwd "$RUN_AS" | cut -d: -f6)
    export HOME="${home_dir:-/home/$RUN_AS}"
    export USER="$RUN_AS"
    export LOGNAME="$RUN_AS"

    exec setpriv --reuid="$RUN_AS" --regid="$RUN_AS" --init-groups -- "$@"
fi

# Dev Containers path: already unprivileged, firewall applied by postStartCommand.
exec "$@"
