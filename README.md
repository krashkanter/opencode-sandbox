# opencode-sandbox

Run [opencode](https://github.com/anomalyco/opencode) against the
[Token Harbor](https://tokenharbor.ai) model gateway inside a container that
**cannot reach the internet except for hosts you named**, and **cannot touch your
home directory**.

This is a configuration project. It composes existing, maintained pieces rather
than reimplementing them:

| Piece | Source |
| --- | --- |
| Base image | [`mcr.microsoft.com/devcontainers/javascript-node`](https://github.com/devcontainers/images) — Microsoft's official Dev Containers image |
| Editor integration | The [Dev Containers specification](https://containers.dev/) |
| Egress allowlist | The firewall pattern from [Anthropic's Claude Code devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer), parameterised |
| Agent | [`opencode-ai`](https://www.npmjs.com/package/opencode-ai), opencode's official npm distribution |
| Runtime | [Bun](https://bun.sh), pinned to match the host toolchain |

## Why

An agent that can run shell commands and reach the network is a data-exfiltration
path wearing a helpful hat. A prompt injection in a README, or one compromised
transitive dependency, is enough. Two controls do most of the work here:

- **Default-deny egress.** `iptables` drops every outbound packet that is not in
  an `ipset` built from an explicit domain allowlist. Reaching an attacker's
  endpoint fails in the kernel, not in the model's judgement.
- **No ambient authority.** The agent runs as uid 1000 with all capabilities
  dropped, `no-new-privileges`, and exactly one host directory (`./workspace`)
  mounted. Its own provider config is mounted read-only, so it cannot rewrite
  the gateway it talks to.

Neither is a jail. A determined exploit against the kernel or a bug in the
allowlist still gets out. This raises cost; it does not eliminate risk.

## Quick start

```bash
cp .env.example .env       # then put your Token Harbor key in it
docker compose run --rm opencode
```

`.env` is gitignored. The key is injected at runtime and is never baked into the
image or written into any tracked file.

### Verify the sandbox actually holds

```bash
docker compose run --rm -T --entrypoint /usr/local/bin/entrypoint.sh opencode sh -s < scripts/verify.sh
```

Checks that the process is unprivileged, that off-allowlist egress is blocked,
that the gateway answers, and that a real model round-trip succeeds.

### As a Dev Container

Open the folder in VS Code and *Reopen in Container*. `.devcontainer/devcontainer.json`
mounts only `./workspace`, and re-resolves the allowlist on every start via
`postStartCommand` (these hosts sit behind rotating CDN IPs).

Export `TOKENHARBOR_API_KEY` on the host first — the devcontainer reads it from
your environment rather than from `.env`.

## Pull and run — no repository or Compose required

The published image includes the non-secret Token Harbor provider configuration
and supports both `linux/amd64` and `linux/arm64`. Your key is supplied only
when the container starts.

Create a working folder and a local token file:

```bash
mkdir opencode-work && cd opencode-work
printf 'TOKENHARBOR_API_KEY=thk_live_replace_me\n' > .env
```

Keep `.env` private and never commit or send it. Then pull and run the hardened
container:

```bash
docker pull ghcr.io/krashkanter/opencode-sandbox:latest

docker run -it --rm --init \
  --user 0:0 \
  --cap-drop ALL \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges:true \
  --cpus 2 --memory 4g --pids-limit 512 \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --tmpfs /run/opencode:rw,exec,nosuid,mode=1777,size=256m \
  --env-file .env \
  --mount type=bind,src="$(pwd)",dst=/workspace \
  --mount type=volume,src=opencode-sandbox-state,dst=/home/node/.local/share/opencode \
  ghcr.io/krashkanter/opencode-sandbox:latest
```

The bind mount is the only host folder the agent can access. The named volume
persists its session state without putting it in that folder. To start fresh,
replace `opencode-sandbox-state` with a new volume name.

The command intentionally starts as root only long enough to apply the
network allowlist, then drops to the unprivileged `node` user before opencode
starts. Do not omit the capabilities, `no-new-privileges`, or the two `tmpfs`
mounts. A plain `docker run ghcr.io/…` is rejected rather than silently running
without the firewall.

For PowerShell, replace `$(pwd)` with `${PWD}`. In Git Bash, the command above
works as written.

## Configuration

Everything lives in `.env`:

| Variable | Purpose |
| --- | --- |
| `TOKENHARBOR_API_KEY` | Gateway key, `thk_live_…`. Required. |
| `OPENCODE_MODEL` | Default model opencode boots with. |
| `ALLOWED_DOMAINS` | Space-separated egress allowlist. **A host not listed here is unreachable.** |
| `SANDBOX_CPUS` / `SANDBOX_MEMORY` | Resource ceilings. |

Adding a dependency host (a private registry, an API the agent must call) means
adding it to `ALLOWED_DOMAINS` — that is the intended friction.

### Models

`opencode/opencode.jsonc` registers Token Harbor as an OpenAI-compatible
provider and exposes:

- `tokenharbor/deepseek-v4.1-flash:free` — free rolling 7-day allowance, never
  billed. **This is the default.**
- `tokenharbor/deepseek-v4.1-flash` — paid, zero-data-retention route. 1M
  context, $0.30/$1.20 per 1M tokens in/out. Requires account balance; with a
  zero balance the gateway returns `402 balance_zero`.

Both advertise tool calling, which opencode depends on.

Point this at another gateway by editing `baseURL` and the `models` map — the
firewall allowlist is the only other thing that needs to know.

## Layout

```
.devcontainer/
  Dockerfile          image: base + opencode + bun + netfilter tooling
  devcontainer.json   Dev Containers wiring
  entrypoint.sh       firewall, then drop root via setpriv
  init-firewall.sh    default-deny egress allowlist
opencode/
  opencode.jsonc      provider + model config (mounted read-only)
scripts/
  verify.sh           sandbox self-test
compose.yaml          hardened service definition
workspace/            the only host directory the agent can see
```

## Notes

- The firewall flushes only the `filter` table. Flushing `nat` would remove the
  DNAT rule Docker installs for its embedded resolver at `127.0.0.11`, breaking
  DNS and silently emptying the allowlist.
- Privilege drop uses `setpriv`, not `sudo`: `sudo` needs setuid escalation,
  which `no-new-privileges` forbids. This costs `CAP_SETUID`/`CAP_SETGID`, which
  are consumed during startup and gone before the agent runs.
- `/tmp` is mounted `noexec`, but opencode's TUI (OpenTUI) extracts a native `.so`
  at startup and `dlopen()`s it — which `noexec` blocks with *"failed to map
  segment from shared object"*. Rather than dropping the hardening, `TMPDIR`
  points at a separate small exec-permitted tmpfs (`/run/opencode`), so generic
  writes to `/tmp` still cannot be executed. `scripts/verify.sh` asserts both.
- The entrypoint refuses an unprivileged start unless something else is known to
  have applied the firewall. Dev Containers opts in with
  `SANDBOX_FIREWALL_DEFERRED=1` because its `postStartCommand` applies the rules
  after the container is already up.
- If the firewall fails to come up the container refuses to start. Override with
  `FIREWALL_REQUIRED=0` only if you understand what you are giving up.

## License

MIT — see [LICENSE](LICENSE).
