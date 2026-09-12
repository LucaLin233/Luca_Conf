---
name: surge
description: Control and troubleshoot the Surge proxy app through surge-cli. Use whenever a task involves Surge in any way — checking or changing its state (outbound mode, policy groups, profiles, modules, features), diagnosing network problems on a machine running Surge (DNS, routing decisions, proxy connectivity, Tailscale/WireGuard tunnels, gateway-mode clients), reading Surge logs, inspecting requests and traffic, adding temporary rules, running scripts, measuring performance, or writing and packaging a Surge plugin. Prefer surge-cli over GUI instructions or profile file edits for any Surge operation that the CLI can perform.
---

# Surge CLI Operations

`surge-cli` is a full-featured control and diagnostics interface for Surge. It
can answer most questions about a running Surge instance directly — prefer
asking the CLI over guessing, reading profile files, or telling the user to
click through the GUI.

## Connecting

1. Resolve the executable: `surge-cli` in `PATH`, else
   `/Applications/Surge.app/Contents/Applications/surge-cli`.
2. Use the default rendered output — it is the supported interface for agents.
   Pass `--raw` only when a documented field is missing from the rendered form.
3. For a remote instance add `--remote host:port` (IPv6: `[addr]:port`).
   Supply the password via `--password-stdin`, `SURGE_CLI_PASSWORD`, or the
   terminal prompt — never in argv.
4. The CLI is self-documenting: `surge-cli -h` shows the command groups and
   `surge-cli help <command>` (for example `help rule match`, `help dump`)
   shows detailed usage. Use it when unsure about syntax before falling back
   to the reference file.
5. `surge-cli --check <path>` validates a profile file without a running Surge.

## Picking the Right Command

Match the question to the command family; full semantics are in the
[Command Reference](references/command-reference.md).

| Question / task | Commands |
|---|---|
| What is Surge's current state? | `status`, `version`, `environment` |
| Is the network itself healthy? | `dump summary` (passive snapshot; run it first), then `test v4-router\|dns\|encrypted-dns\|external-ip\|nat-type` for active probes |
| How would Surge route this request? | `rule match <host\|url>`; use `rule explain` when the question is "why" — it walks every policy-group hop with its decision reason |
| Is this proxy/policy working? | `test-policy`, `test-policy-udp`, `test-group`, `test-policy-bandwidth`; `http probe <url> [policy]` for a real end-to-end request |
| What is wrong with a Tailscale/WireGuard tunnel? | `dump policy` to find the proxy's `lineHash`, then `proxy-runtime-status <line-hash>` — it exposes handshakes, DERP, Exit Node, and peer paths that nothing else shows |
| What is Surge resolving this to? | `dns lookup <domain>`, `dns trace` for the resolver log, `geoip <ip>` for GEOIP/IP-ASN database checks, `flush dns` |
| What happened just now? | `log memory 500` (all levels, recent), `log file 1000` (longer history), `log watch` (follow live), `logbook`, `script-log` |
| What connections/traffic exist? | `dump active\|recent\|request\|traffic\|traffic-stat\|traffic-stat-host`, `watch request`, `watch speed`, `kill <id>` |
| Change routing behavior now | `mode set`, `global-policy set`, `policy-group set`, `rule temp add`, `set` |
| Manage configuration | `profile list\|current\|diff\|check\|switch`, `module enable\|disable`, `feature set`, `managed-profile update`, `external-resource update`, `reload` |
| Gateway-mode client problems (macOS) | `device list\|show`, `vmnet status\|arp\|ndp\|ra`, `reconnect-device` |
| Memory / performance concerns | `dump performance`, `dump rule-usage`, `benchmark rule-matching`, `benchmark encryption` |
| Run or debug scripts | `script list\|run\|evaluate` |
| Plugins | `plugin ...` — see [Plugin Authoring Guide](references/plugin-authoring.md) |

## Daily Management

Task-oriented commands cover routine operations — use them instead of raw
`set` key-paths whenever one exists, because they validate input and return
the resulting state rather than a bare success:

```bash
surge-cli mode set rule                      # rule | direct | proxy
surge-cli policy-group set "Proxy" "HK"      # select-group choice
surge-cli policy-group set "Auto" auto       # clear an auto-group override
surge-cli feature set mitm on                # mitm, rewrite, scripting, capture,
                                             # packet-capture, cellular-mode
                                             # (+ system-proxy, enhanced-mode on macOS)
surge-cli profile switch "Home.conf"
surge-cli module enable "Module A" "Module B"
```

`feature set system-proxy` / `enhanced-mode` wait for the actual state
transition and fail if it does not complete. An invalid `profile check` sets a
non-zero exit status, which makes it usable in automation.

## Mutating State Safely

- Collect context before changing anything: `environment`, `dump policy`,
  `dump profile` as relevant. Re-run the same read command afterwards to
  verify the effect.
- For raw environment updates, `set` accepts multiple `key=value` pairs in one
  command; use minimal key-path deltas. `<nil>` and `(null)` assign null.
  Key definitions are in section 4 of the [Command Reference](references/command-reference.md).
- For debugging sessions, prefer **temporary rules** over profile edits: they
  take effect immediately, precede all profile rules, and vanish when Surge
  stops, so nothing needs cleanup.

```bash
surge-cli rule temp add "DOMAIN-SUFFIX,example.com,Proxy"
surge-cli rule temp list
surge-cli rule temp flush
```

## Diagnostics Workflow

Start passive, then narrow down; do not jump straight to broad log searches.

1. `status` and `dump summary` — profile, mode, warnings, interfaces, DNS.
2. Reproduce the routing decision offline with `rule match` / `rule explain`,
   and verify its inputs with `dns lookup` / `geoip` when a rule depends on
   resolution or IP databases.
3. Test the selected policy (`test-policy`, `http probe`).
4. For per-proxy internals — especially Tailscale and WireGuard —
   `proxy-runtime-status` is the primary tool; collect it before log analysis.
5. Only then use `log memory` / `log watch` for details, or `diagnostics` for
   the streaming self-check.

For gateway-mode (macOS) client connectivity, inspect the virtual interface
directly: `vmnet arp` / `vmnet ndp` for neighbor resolution, `vmnet ra` for
IPv6 RA takeover state, and `device show <mac>` for the client's records.

## Streaming Commands

`test-policy-bandwidth`, `benchmark encryption`, `test-ponte`, `diagnostics`,
`log watch`, and `watch ...` stream output: process incremental chunks,
respect completion markers (`hasMore=false` or a command-specific completion
payload), and never assume a single response frame. A subscribed `watch` may
stay idle indefinitely; other stages time out after 60 seconds without
progress.

## Platform and Version Gates

- macOS-only: `profile list|check`, all `device` operations, `vmnet`,
  `set-dhcp-device`, `managed-profile`, `update-profile`, `plugin` (online
  subcommands), `unattended-upgrade`.
- Newer commands require a matching Controller protocol version on the Surge
  side (`rule`/`dns`/`http probe`/`security ban` ≥20; `geoip`,
  `dump performance|rule-usage|virtual-ip`, `benchmark rule-matching` ≥22;
  `vmnet` ≥23; `plugin` ≥24). An older core answers `Unknown command`; check
  `surge-cli version` when targeting a remote or outdated instance.

## Plugin Development

To write, test, or package a Surge plugin (JavaScript extensions; currently
the `ap-controller` type), follow the
[Plugin Authoring Guide](references/plugin-authoring.md). The development loop
is `plugin load-unpacked` → `plugin parameters` → `plugin configure` (runs the
plugin's own validation) → check the device panel; `plugin validate` and
`plugin pack` work offline without a running Surge.

## Reference

- [Command Reference](references/command-reference.md) — full command catalog,
  subcommand semantics, environment key definitions, response envelope.
- [Plugin Authoring Guide](references/plugin-authoring.md) — package layout,
  manifest schema, JavaScript API, testing, distribution.
