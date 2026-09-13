#!/usr/bin/env sh
# Self-test for the sandbox. Run inside the container:
#   docker compose run --rm -T --entrypoint /usr/local/bin/entrypoint.sh opencode sh -s < scripts/verify.sh
#
# Exits non-zero if any invariant the sandbox is supposed to guarantee is broken.
set -u
fail=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

echo "== identity =="
[ "$(id -u)" -ne 0 ] && ok "running unprivileged as $(id -un) (uid $(id -u))" \
                     || bad "running as root"
[ "$HOME" = "/home/$(id -un)" ] && ok "HOME=$HOME" || bad "HOME=$HOME (unexpected)"

echo "== toolchain =="
opencode --version >/dev/null 2>&1 && ok "opencode $(opencode --version)" || bad "opencode missing"
bun --version      >/dev/null 2>&1 && ok "bun $(bun --version)"           || bad "bun missing"

echo "== config =="
cfg="$HOME/.config/opencode/opencode.jsonc"
[ -r "$cfg" ] && ok "provider config mounted" || bad "provider config missing at $cfg"
[ -w "$cfg" ] && bad "provider config is WRITABLE (should be read-only)" \
              || ok "provider config is read-only"
[ -n "${TOKENHARBOR_API_KEY:-}" ] && ok "gateway key present (${#TOKENHARBOR_API_KEY} chars)" \
                                  || bad "TOKENHARBOR_API_KEY not set"

echo "== native library loading =="
# opencode's TUI extracts a native .so and dlopen()s it. /tmp is noexec, so this
# has to land in an exec-permitted TMPDIR or the TUI dies at startup.
if cp /bin/true /tmp/.exectest 2>/dev/null && /tmp/.exectest 2>/dev/null; then
    bad "/tmp is executable — noexec hardening lost"
else
    ok "/tmp is noexec"
fi
rm -f /tmp/.exectest
if [ -n "${TMPDIR:-}" ] && cp /bin/true "$TMPDIR/.exectest" 2>/dev/null && "$TMPDIR/.exectest" 2>/dev/null; then
    ok "TMPDIR=$TMPDIR is exec-permitted (native .so can load)"
else
    bad "TMPDIR=${TMPDIR:-unset} cannot exec — the TUI will fail to start"
fi
rm -f "${TMPDIR:-/tmp}/.exectest"

echo "== egress allowlist =="
if curl -s -o /dev/null --connect-timeout 5 https://example.com 2>/dev/null; then
    bad "example.com reachable — allowlist NOT enforcing"
else
    ok "off-allowlist host blocked"
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 \
        -H "Authorization: Bearer ${TOKENHARBOR_API_KEY:-none}" \
        https://tokenharbor.ai/v1/models 2>/dev/null)
[ "$code" = "200" ] && ok "gateway /v1/models -> 200" || bad "gateway /v1/models -> $code"

echo "== model round-trip =="
body=$(curl -s --connect-timeout 20 https://tokenharbor.ai/v1/chat/completions \
        -H "Authorization: Bearer ${TOKENHARBOR_API_KEY:-none}" \
        -H 'Content-Type: application/json' \
        -d '{"model":"deepseek-v4.1-flash:free","messages":[{"role":"user","content":"Reply with exactly: PONG"}],"max_tokens":16}' 2>/dev/null)
echo "$body" | grep -q 'PONG' && ok "deepseek-v4.1-flash:free responded" \
                              || bad "model call failed: $(echo "$body" | head -c 200)"

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
