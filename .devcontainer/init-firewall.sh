#!/usr/bin/env bash
#
# Default-deny egress allowlist for the opencode sandbox.
#
# Adapted from the firewall in Anthropic's Claude Code devcontainer
# (https://github.com/anthropics/claude-code/tree/main/.devcontainer), the
# reference implementation of this pattern. Changed here: the allowlist is
# driven by $ALLOWED_DOMAINS rather than hardcoded, so pointing the sandbox at a
# different model gateway is configuration, not a code edit.
#
# Threat model: an agent with tool access can read the workspace and reach the
# network. This caps the blast radius of a prompt injection or a compromised
# dependency at "can talk to the few hosts we named" — exfiltration to an
# arbitrary endpoint fails in the kernel, not in the agent's good judgement.

set -euo pipefail
IFS=$'\n\t'

ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-tokenharbor.ai opencode.ai registry.npmjs.org bun.sh api.github.com github.com objects.githubusercontent.com}"

log() { printf '[firewall] %s\n' "$*"; }

# --- start clean -----------------------------------------------------------
# Only the filter table. Flushing `nat` would tear out the DNAT rule Docker
# installs for its embedded resolver at 127.0.0.11 and break DNS outright,
# which then silently empties the entire allowlist.
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
ipset destroy allowed-domains 2>/dev/null || true

# DNS and loopback go up first: resolution has to work while we build the set.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

ipset create allowed-domains hash:net

# --- GitHub's published ranges --------------------------------------------
# Clone/push targets rotate IPs, so take the CIDR list from the horse's mouth.
if gh_meta=$(curl -fsSL --connect-timeout 10 https://api.github.com/meta 2>/dev/null); then
    if command -v aggregate >/dev/null 2>&1; then
        cidrs=$(echo "$gh_meta" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || echo "$gh_meta" | jq -r '(.web + .api + .git)[]')
    else
        cidrs=$(echo "$gh_meta" | jq -r '(.web + .api + .git)[]')
    fi
    count=0
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        [[ "$cidr" == *:* ]] && continue   # ipset here is IPv4-only
        ipset add allowed-domains "$cidr" -exist 2>/dev/null && count=$((count + 1)) || true
    done <<< "$cidrs"
    log "added $count GitHub CIDR ranges"
else
    log "WARNING: could not fetch GitHub ranges; git over HTTPS may be blocked"
fi

# --- named domains ---------------------------------------------------------
# IFS above deliberately excludes space, so split the list explicitly rather
# than relying on word splitting that will not happen.
IFS=' ' read -r -a _domains <<< "$ALLOWED_DOMAINS"
for domain in "${_domains[@]}"; do
    [[ -z "$domain" ]] && continue
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [[ -z "$ips" ]]; then
        log "WARNING: $domain resolved to nothing, skipping"
        continue
    fi
    while read -r ip; do
        [[ -z "$ip" ]] && continue
        ipset add allowed-domains "$ip" -exist
    done <<< "$ips"
    log "allowed $domain -> $(echo "$ips" | tr '\n' ' ')"
done

# --- host network ----------------------------------------------------------
# Lets host-side tooling (IDE, devcontainer CLI) reach the container.
HOST_IP=$(ip route | awk '/default/ {print $3; exit}')
if [[ -n "${HOST_IP:-}" ]]; then
    HOST_NET=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
    iptables -A INPUT  -s "$HOST_NET" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NET" -j ACCEPT
    log "allowed host network $HOST_NET"
fi

# --- default deny ----------------------------------------------------------
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

log "default-deny egress active"

# --- prove it ---------------------------------------------------------------
# A firewall nobody verified is a firewall nobody has.
if curl -fsS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
    log "ERROR: reached example.com — the allowlist is NOT enforcing"
    exit 1
fi
log "verified: off-allowlist egress is blocked"

primary="${_domains[0]}"
if curl -fsS --connect-timeout 10 -o /dev/null "https://${primary}" 2>/dev/null; then
    log "verified: ${primary} reachable"
else
    log "WARNING: ${primary} unreachable — check the allowlist"
fi
