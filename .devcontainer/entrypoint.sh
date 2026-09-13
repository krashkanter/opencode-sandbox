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
    # stay /root and opencode would write config and state somewhere the
    # unprivileged user cannot read.
    home_dir=$(getent passwd "$RUN_AS" | cut -d: -f6)
    export HOME="${home_dir:-/home/$RUN_AS}"
    export USER="$RUN_AS"
    export LOGNAME="$RUN_AS"

    exec setpriv --reuid="$RUN_AS" --regid="$RUN_AS" --init-groups -- "$@"
fi

# --- unprivileged entry ------------------------------------------------------
# We are not root, so we cannot program netfilter and cannot read the rules back
# to check whether anyone else did. Two ways to legitimately be here:
#
#   1. Dev Containers, where postStartCommand applies the firewall after start.
#      That path opts in explicitly via SANDBOX_FIREWALL_DEFERRED=1.
#   2. Someone ran the bare image (`docker run <image>`), which gets NO firewall.
#
# Case 2 previously started the agent with unrestricted egress while looking
# identical to a sandboxed run. Refuse it: a sandbox that silently isn't one is
# worse than no sandbox, because it is trusted.
if [[ "${SANDBOX_FIREWALL_DEFERRED:-0}" != "1" && "${FIREWALL_REQUIRED:-1}" == "1" ]]; then
    cat >&2 <<'MSG'
[entrypoint] REFUSING TO START — no egress firewall.

This container started unprivileged, so it cannot apply the egress allowlist,
and nothing indicates anything else applied it. The agent would run with
unrestricted network access.

The image on its own is not the sandbox. Start it one of these ways:

  docker compose run --rm opencode           (recommended)
  docker compose -f compose.yaml -f compose.pull.yaml run --rm opencode

Both grant NET_ADMIN, apply the allowlist, then drop privileges.

To deliberately run without a firewall (you accept unrestricted egress):
  FIREWALL_REQUIRED=0
MSG
    exit 1
fi

if [[ "${SANDBOX_FIREWALL_DEFERRED:-0}" == "1" ]]; then
    echo "[entrypoint] unprivileged start; firewall deferred to postStartCommand." >&2
else
    echo "[entrypoint] WARNING: starting with NO egress firewall (FIREWALL_REQUIRED=0)." >&2
fi

exec "$@"
