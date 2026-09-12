# Surge CLI / Controller Command Reference (for AI Agents)

This document is the Surge CLI operational reference for AI agents. It covers
the product-oriented commands intended for routine use and the advanced
controller commands that are not all shown by `-h`.

## 1. CLI Usage

> Minis adaptation: this command catalog is synchronized from the Surge-bundled Skill. In Minis, `/usr/local/bin/surge-cli` connects directly to Surge iOS External Controller. Use this section's adapted invocation rules; the remaining command semantics are upstream documentation and platform restrictions still apply.

### 1.1 Controller protocol requirements

执行前核对协议门槛，不满足或未知时不得直接执行；`surge-cli --raw version` 可读当前协议。

| 命令 / 功能 | 最低协议 |
|---|---|
| `rule`、`dns`、`http probe`、`security ban` | ≥20 |
| `geoip`、性能 / 规则使用 / 虚拟 IP dump、`benchmark rule-matching` | ≥22 |
| `vmnet`（macOS only） | ≥23 |
| `plugin`（macOS only）、`restart-engine` | ≥24 |

已验证组合：Surge iOS 5.22.0（Controller 5.102.0 build 3830）/ Protocol 25，兼容旧 JSON `argv` 请求，客户端已对齐 macOS 6.9.0 build 12250 文本编码。

### 1.2 Basic format

```bash
surge-cli [--remote host:port] [--password-stdin] [--raw] <command> [args...]
```

Executable location in Minis:

```bash
/usr/local/bin/surge-cli
```

- `--raw`: output raw JSON (recommended for agents).
- `--remote` / `-r`: connect to another Controller; the Minis default is `127.0.0.1:6170`.
- Authentication comes from `--password-stdin`, `SURGE_CLI_PASSWORD`, or a secure prompt. Never put the password in `--remote`; the Minis CLI does not use password files.
- `--check <path>` / `-c <path>`: upload the explicitly named UTF-8 profile to Surge's official beta validation service (`https://services.nssurge.com/v1/config/validate`). This is remote validation, not the bundled macOS local parser. The CLI never uploads the active profile automatically; warn about profile secrets and redact a copy first when appropriate.
- `--help` / `-h`: print help.
- If no command is provided, the Minis implementation prints help rather than entering an interactive terminal.
- Command keywords are handled by the connected Controller.

### 1.2 Response envelope

Responses are JSON and usually include:

- `result`: success text
- `error`: error text
- payload fields (for example `requests`, `environment`)
- `hasMore` for streaming commands (`true` means more chunks follow)

## 2. Full Command Catalog

The table below is the full command catalog handled by the controller (not just
the subset shown in `-h`). High-priority subcommands may also appear as their
own rows.

| Command | Args | Description | Notes |
|---|---|---|---|
| `status` | none | summarize profile name and full path, mode, features, uptime, and version | see 3.14 |
| `dump summary` | none | show a passive snapshot of network configuration, DNS, and warnings | recommended first network diagnostic, see 3.15 |
| `version` | none | show app, Core, protocol, OS, and device versions | see 3.14 |
| `mode` | `[get \| set <rule\|direct\|proxy>]` | get or change outbound mode | direct mode name is `direct` |
| `global-policy` | `[get \| set <policy>]` | get or change the global proxy policy | |
| `policy-group` | `list \| get <group> \| set <group> <policy\|auto>` | inspect and select policy groups | `auto` clears an automatic-group override |
| `profile` | `list \| current \| diff \| check <name> \| switch <name>` | inspect, compare, validate, and switch profiles | `list`/`check` are macOS only |
| `module` | `list \| enable <name...> \| disable <name...>` | inspect and change module state | changes schedule a profile reload |
| `feature` | `list \| get <name> \| set <name> <on\|off>` | inspect and change runtime features | see 3.14 |
| `device` | `list \| show <identifier\|mac>` | inspect gateway-mode devices | macOS only |
| `log` | `[file\|memory] [line-count]` or `watch` | show retained logs or continuously follow new logs | defaults to `file 100`; maximum 10000, see 3.16 |
| `watch` | `[event ...]` | subscribe to events; without args unsubscribes | `watch request` is common |
| `dump` | `<type> [extra]` | dump runtime state data | see 3.2 |
| `test` | `<type>` | environment diagnostics | see 3.3 |
| `environment` | none | return current environment dictionary | |
| `set` | `<key>=<value> ...` | update environment | see 4 |
| `set-log-level` | `<level>` | change runtime log level | does not write profile, see 3.16 |
| `stop` | none | stop Surge | |
| `kill` | `<connection-id>` | terminate a connection | |
| `test-group` | `<group-name>` | retest a policy group immediately | |
| `test-all-policies` | none | retest all policies | |
| `test-policy` | `<policy...>` | test one or more policies | |
| `test-policy-udp` | `<policy...>` | UDP policy test | |
| `test-policy-external-ip` | `<policy>` | probe external IP via a policy | STUN-based |
| `test-policy-nat-type` | `<policy>` | probe NAT type via a policy | STUN-based |
| `test-policy-bandwidth` | `<download\|upload> <policy>` | run bandwidth diagnostics via a policy | streaming output |
| `benchmark` | `encryption [data-size-mib]` \| `rule-matching` | benchmark local encryption throughput or rule matching speed | encryption is streaming, see 3.3.1; rule-matching see 3.12 |
| `rule` | `<match\|explain> <host\|url> [port] [key=value ...]` | evaluate the rule set without creating a connection | see 3.9 |
| `dns` | `<lookup\|trace> <domain> [interface=<bsd-name>]` | resolve via Surge's DNS with optional resolver trace | see 3.10 |
| `geoip` | `<ip-address>` | look up the local GeoIP/ASN databases | see 3.10 |
| `http` | `probe <url> [policy]` | send an HTTP HEAD request and report status, timing, route, and headers | rule-set routing when policy omitted |
| `security` | `ban <list\|clear>` | inspect or clear unauthorized-access bans | |
| `vmnet` | `<status\|arp\|ndp\|ra>` | inspect the VMNET virtual interface (gateway mode) | macOS only, see 3.13 |
| `flush` | `<type>` | flush data | currently only `dns` |
| `reload` | none | reload main profile, applying only the changed sections | falls back to a full engine restart automatically when a change requires one |
| `restart-engine` | none | completely restart the engine and reload the profile from scratch | closes all connections, clears all caches and temporary rules |
| `show-policy` | `<policy-name>` | show policy details | |
| `retrieve-data` | `<record-id> <request\|response> [replica-dir]` | fetch captured request/response body | data-channel command |
| `test-network` | none | network delay test | returns `time` |
| `script` | `list \| run <cron-name> \| evaluate <base64-js> [mockType] [timeout] [engine] [argument]` | inspect and run scripts | CLI has an evaluate wrapper, see 3.4 |
| `diagnostics` | none | start diagnostics event stream | pair with `stop-diagnostics` |
| `stop-diagnostics` | none | stop diagnostics event stream | |
| `get-resource` | `device-icon <id...>` | fetch device icons (Base64) | |
| `set-dhcp-device` | `<mac> <type> [value]` | set DHCP device parameters | macOS only, see 3.5 |
| `remove-device-record` | `<identifier...>` | remove device records | macOS only |
| `switch-profile` | `<profile-name>` | switch to another profile | |
| `managed-profile` | `update` | update and reload the active managed profile | macOS only |
| `update-profile` | `<base64-rule-section>` | update Rule section | macOS only |
| `proxy-runtime-status` | `<line-hash>` | inspect one proxy's live runtime and recent errors | essential for Tailscale/WireGuard diagnosis, see 3.1 |
| `add-temp-rule` | `<rule>` | add temporary rule | |
| `del-temp-rule` | `<rule>` | delete temporary rule | |
| `update-temp-rule` | `<rule> <new-policy>` | change policy of temporary rule | |
| `flush-temp-rule` | none | clear all temporary rules | |
| `unattended-upgrade` | none | unattended upgrade | macOS only |
| `provider-message` | `<base64-data>` | send message to Packet Tunnel Provider | unsupported on macOS |
| `external-resource` | `list \| update <key\|all>` | external resource listing and update | |
| `plugin` | `list \| info \| parameters \| install \| load-unpacked \| configure \| enable \| disable \| select \| uninstall \| validate \| pack` | manage third-party plugins | macOS only; needs protocol ≥24. `validate`/`pack` run offline; `install` is not available in this version |
| `test-ponte` | `<device-ponte-name>` | Ponte diagnostics | streaming output |
| `logbook` | `<limit>` | show recent logbook records | macOS/iOS, see 3.16 |
| `script-log` | `<log-name> <session-id>` | show one script execution log | macOS/iOS, see 3.16 |
| `reconnect-device` | `<mac>` | reconnect an AP client | macOS only |

## 3. Subcommand Details

### 3.0 `plugin` (macOS only, controller protocol ≥24)

Plugins are third-party extensions (JavaScript running in an isolated JavaScriptCore context, independent of the proxy core). In this release the only plugin type is `ap-controller` (integrations that populate the device panel's Wi-Fi columns and allow reconnecting clients).

Online subcommands (require a running Surge):

- `plugin list` — payload `{"plugins": [ {id, name, version, type, state, source, parameters, values, ...} ]}`. `state` is one of `unconfigured | enabled | disabled | error`; `source` is `builtin | url | unpacked`.
- `plugin info <id>` — one plugin object (same schema, always includes the `parameters` schema and current `values`).
- `plugin parameters <id>` — the parameter schema rendered for configuration: each parameter with type, required, constraints (enum values, range), default and current value, plus a ready-to-copy `plugin configure` invocation. Use this to discover what a plugin needs before configuring.
- `plugin install <manifest-url>` — download + verify (sha256) + unpack from a hosted manifest URL. **Not available in this version** (the CLI rejects it); use `plugin load-unpacked` with a local directory instead.
- `plugin load-unpacked <directory>` — register a local developer directory (containing `main.js` + `manifest.json` + 256x256 `icon.png`) as an `unpacked` plugin; re-reads the manifest on each call.
- `plugin configure <id> <key=value> ...` — set typed parameter values. Runs the plugin's `system.validate` when it declares support; on success the plugin becomes `enabled`. **A plugin must be configured before it can be used.**
- `plugin enable <id>` / `plugin disable <id>` — toggle. Enabling also selects the plugin as active for its type.
- `plugin select <type> <id|none>` — choose the active plugin for a type (only needed when more than one is enabled).
- `plugin uninstall <id>` — remove a url/unpacked plugin (builtins can only be disabled).

Offline subcommands (never connect to Surge; pure local tooling):

- `plugin validate <directory>` — parse + schema-check a plugin source directory (manifest + `main.js` + 256x256 `icon.png`).
- `plugin pack <directory> [asset-url]` — zip the package (excluding `manifest.json`) and emit a hosted `manifest.json` with the computed `asset.sha256`. Manifests live only at the hosted URL; the zip never contains one.

Typical flow for setting up a plugin (this version installs from local
directories only):

```bash
surge-cli plugin load-unpacked ~/plugins/unifi
surge-cli plugin parameters com.example.unifi   # discover what needs to be configured
surge-cli plugin configure com.example.unifi host=https://192.168.1.1 key=<api-key>
surge-cli plugin list        # confirm state == enabled
```

### 3.1 Tailscale and WireGuard diagnostics: `proxy-runtime-status`

```bash
surge-cli dump policy
surge-cli proxy-runtime-status <line-hash>
surge-cli proxy-runtime-status <line-hash>
```

`proxy-runtime-status` is the primary per-proxy diagnostic command and is
especially important for Tailscale and WireGuard. General status, summary, and
connectivity-test commands do not expose the tunnel's internal runtime state.
Use `dump policy` to find the proxy's `line-hash`, shown in square brackets in
human-readable output, then pass it to this command.

The common response includes traffic and speed, UDP relay support, test
capability, runtime details, and recent connection errors. WireGuard adds the
effective underlying policy, active TCP/UDP connection counts, and each peer's
handshake state. Tailscale adds session and error state, local addresses, Exit
Node selection, DERP connections and reachability, peer paths, and MagicDNS or
other runtime peer details when available.

For a Tailscale or WireGuard connection, routing, relay, Exit Node, or handshake
problem, collect this command before broad log searches.

### 3.2 `dump <type>`

Supported `type` values:

- `active`
- `recent`
- `request`
- `dns`
- `traffic`
- `auto-test-group-result`
- `policy`
- `rule`
- `map-remote`
- `map-local`
- `profile`
- `event`
- `policy-group-sub-policies`
- `traffic-stat` (optional second arg: `prefix`)
- `traffic-stat-host`
- `temp-rule`
- `summary`
- `virtual-ip-db`
- `virtual-ip <ip|domain-substring>` (targeted query, see 3.11)
- `smart-group-info`
- `performance` (see 3.11)
- `rule-usage` (see 3.11)

`surge-cli -h` shows only a subset.

For profile display mode in CLI:

```bash
surge-cli dump profile original
surge-cli dump profile effective
```

### 3.3 `test <type>`

Supported `type` values:

- `v4-router`
- `dns`
- `encrypted-dns`
- `external-ip`
- `nat-type`

Note: `test-policy*` commands are separate top-level commands, not part of `test <type>`.

### 3.3.1 Encryption throughput benchmark

```bash
surge-cli benchmark encryption
surge-cli benchmark encryption 25
surge-cli benchmark encryption 100
```

`benchmark encryption [data-size-mib]` runs the encryption benchmark on the
device where Surge is running. With a remote Controller connection, it measures
the remote Surge device rather than the `surge-cli` host. The command streams
throughput and correctness results for supported stream and AEAD encryption
implementations; it does not measure network or proxy bandwidth.

The data size defaults to 100 MiB and accepts integers from 1 to 1024 MiB. Raw
chunks use `type` values `start`, `line`, and `complete`. Interrupting or
disconnecting the CLI cancels the benchmark after the active primitive call.

### 3.4 `script`

Routine forms:

```bash
surge-cli script list
surge-cli script run <cron-name>
```

`run` executes an enabled or disabled configured cron script by name and
returns its output plus result or exception.

Evaluate convenience form:

Common CLI form:

```bash
surge-cli script evaluate <script-js-path> [mock-script-type] [timeout] [engine] [argument]
```

CLI reads `<script-js-path>`, converts it to Base64, and sends it to controller `script evaluate`.

Supported `mock-script-type` strings:

- `http-request`
- `http-response`
- `cron`
- `event`
- `rule`
- `dns`
- `generic`

Supported `engine` strings:

- `auto`
- `jsc`
- `webview`

### 3.5 `set-dhcp-device` subtypes (macOS only)

```text
set-dhcp-device <mac> takeover [0|1]
set-dhcp-device <mac> disable-udp-fast-path [0|1]
set-dhcp-device <mac> address [ipv4-or-empty]
set-dhcp-device <mac> name [display-name-or-empty]
set-dhcp-device <mac> icon [icon-name-or-empty]
```

### 3.6 `external-resource`

- `external-resource list`
- `external-resource update <hash-key>`
- `external-resource update all`

`list` includes `ready`, and remote resources may include `updatedAt`.

### 3.7 `managed-profile`

- `managed-profile update`

The command forcibly checks the active managed profile, waits for download,
validation, and file replacement, and schedules a profile reload when the
content changed. It returns `updated` or `unchanged`.

### 3.8 `watch` event types

Supported event names:

- `real-time-speed`
- `auto-test-group`
- `traffic`
- `request`
- `request-update`
- `summary`
- `environment`
- `dns`
- `diagnostics`
- `reload`
- `shutdown`
- `device-name-map`
- `policy-benchmark`
- `device-info`
- `dns-flush`
- `log` (live log stream; prefer `log watch`)

Examples:

```bash
surge-cli watch request
surge-cli watch summary environment traffic
surge-cli watch speed        # CLI alias of real-time-speed, rendered as ↓/↑ rates
surge-cli watch              # unsubscribe
```

### 3.9 `rule match` / `rule explain` and temporary rules

```bash
surge-cli rule match example.com 443
surge-cli rule match https://example.com process-path=/usr/bin/curl
surge-cli rule explain https://example.com
```

Both evaluate the active rule set without creating a connection and return the
matched rule and final policy. `rule explain` additionally walks the
policy-group resolution: every group hop with its decision reason, the current
smart group pick, the underlying proxy chain, and the evaluation notes — use it
to answer "why did this request go through that policy".

A bare hostname defaults to TCP port 443; an HTTP(S) URL supplies URL, HTTP
Host, SNI, protocol, and port. `key=value` options override individual
descriptor fields: `hostname`, `dest-port` (alias `port`), `process-path`,
`user-agent`, `url`, `sni`, `http-host`, `source-address`, `source-port`,
`is-local` (alias `local`), `client-mac`, `listen-port`, `protocol`,
`device-name`. An empty value (for example `sni=`) clears an optional field.

Temporary rules: the CLI form `rule temp <list|add|remove|set-policy|flush>`
maps onto the controller commands `dump temp-rule`, `add-temp-rule`,
`del-temp-rule`, `update-temp-rule`, and `flush-temp-rule`. Temporary rules
take effect immediately, precede all profile rules, and are discarded when
Surge stops. Quote a rule that contains spaces:

```bash
surge-cli rule temp add "DOMAIN-SUFFIX,example.com,Proxy"
```

### 3.10 `dns lookup` / `dns trace` / `geoip`

```bash
surge-cli dns lookup example.com
surge-cli dns trace example.com interface=en0
surge-cli geoip 8.8.8.8
```

`dns lookup` resolves through Surge's DNS pipeline and reports A/AAAA records,
the answering server, interface, path, timing, and cache expiry. `dns trace`
additionally includes the resolver trace log. `interface=<bsd-name>` forces the
lookup through one network interface and fails when it is unavailable.

`geoip` looks up an IP address in the local GeoIP and ASN databases — the same
data `GEOIP` and `IP-ASN` rules match against — and reports the country code,
ASN, AS organization, and both database dates. Fields are `null` when the
address is not present in a database.

### 3.11 `dump performance` / `dump rule-usage` / `dump virtual-ip`

- `dump performance`: engine memory footprint (`memory-bytes`), uptime, active
  request count, DNS cache entries, virtual IP entries, temporary rule count,
  and active ban count. Useful when tracking the iOS Network Extension memory
  limit on a remote device.
- `dump rule-usage`: per-rule match counters accumulated since the app last
  collected them (the apps drain the counters periodically, on iOS every 6
  hours). The dump itself is non-destructive.
- `dump virtual-ip <ip|domain-substring>`: targeted query of the virtual IP
  database — exact match for an IPv4 address, case-insensitive substring match
  for a domain. `dump virtual-ip-db` remains the full dump.

### 3.12 `benchmark rule-matching`

```bash
surge-cli benchmark rule-matching
```

Measures the average matching time of the active rule set using random
hostnames (worst-case full scan; the result is a single response with
`average-ns`, not a stream). Useful for judging the cost of very large rule
sets on the device running Surge.

### 3.13 `vmnet` (macOS only)

```bash
surge-cli vmnet status
surge-cli vmnet arp
surge-cli vmnet ndp
surge-cli vmnet ra
```

Inspects the VMNET virtual interface that backs the enhanced/gateway mode.
`status` always answers (reporting `running: false` when the interface is
down); the table commands error with "The VMNET virtual interface is not
active" when the interface is not running.

- `status`: interface configuration — main interface and MACs, IPv4 self/router
  addresses, IPv6 link-local/global addresses, advertised prefix, IPv6 router,
  MTU, and the sizes of the ARP/NDP/RA tables.
- `arp`: the IPv4 neighbor table learned from gateway clients (`ip`, `mac`,
  `age-seconds`).
- `ndp`: the IPv6 neighbor table in the same shape.
- `ra`: IPv6 RA takeover state — per-client MAC, learned link-local address,
  and time since the last RA sent; known routers with their remaining RA
  lifetimes (these are excluded from takeover while valid); and blacklisted
  clients.

Use `arp`/`ndp` when a gateway client cannot be reached, and `ra` when IPv6
takeover does not appear to affect a device.

### 3.14 Daily management commands

These commands provide stable, task-oriented entry points so clients do not
need to know the internal `environment` key paths:

```bash
surge-cli status
surge-cli dump summary
surge-cli version

surge-cli mode
surge-cli mode set rule
surge-cli global-policy
surge-cli global-policy set "Proxy"

surge-cli policy-group list
surge-cli policy-group get "Proxy"
surge-cli policy-group set "Proxy" "Hong Kong"
surge-cli policy-group set "Automatic" auto

surge-cli profile list
surge-cli profile current
surge-cli profile diff
surge-cli profile check "Default.conf"
surge-cli profile switch "Default.conf"

surge-cli module list
surge-cli module enable "Module A" "Module B"
surge-cli module disable "Module A"

surge-cli script list
surge-cli script run "Daily Job"

surge-cli feature list
surge-cli feature get mitm
surge-cli feature set mitm on

surge-cli device list
surge-cli device show AA:BB:CC:DD:EE:FF
```

`feature` names available on all supported controller platforms are `mitm`,
`rewrite`, `scripting`, `capture`, `packet-capture`, and `cellular-mode`.
macOS additionally exposes `system-proxy` and `enhanced-mode`.

Mutation commands return the resulting state, not just a generic success
message. `feature set system-proxy` and `feature set enhanced-mode` wait for
the actual state transition and fail if it does not complete. An invalid
`profile check` also returns a command error, making its CLI exit status useful
in automation.

Profile `list` and
`check`, and all `device` operations, are available only on macOS. `status`
displays the active profile's absolute path in `profile-path`; profiles that do
not originate from a local file report no path.

### 3.15 First-line network diagnostics: `dump summary`

```bash
surge-cli dump summary
```

Use `dump summary` near the start of network troubleshooting. It returns a
passive snapshot of the current network setup and does not send probes or
change any settings. Depending on the platform and active network, it can show:

- profile configuration warnings and performance-impact warnings;
- available and primary interfaces, IP addresses, and the default IPv4 router;
- Wi-Fi or cellular details when available;
- effective plain and encrypted DNS servers;
- subnet-specific behavior such as TCP Fast Open and cellular fallback.

The `Network Indicators` values for external IP, NAT type, and bandwidth are
not active test results. Use `test external-ip`, `test nat-type`,
`test v4-router`, `test dns`, `test encrypted-dns`, or the corresponding
`test-policy-*` command when an active measurement is needed.

With `--raw`, the response also includes `canPingRouter`, `canTestDNS`, and
`canTestEncryptDNS`, which indicate which follow-up tests are available.

### 3.16 Log commands

Read retained logs:

```bash
surge-cli log
surge-cli log 500
surge-cli log file 1000
surge-cli log memory 500
```

`log` returns the latest 100 lines from `file` by default. A number by itself
changes the line count while keeping the default source. The permitted range is
1 to 10000 lines, and output is ordered from older to newer.

| Source | Contents | Best for |
|---|---|---|
| `memory` | all log levels, limited to the most recent entries | investigating something that just happened with maximum detail |
| `file` | the complete history retained in the current log file, limited to the configured log level | reviewing a longer time range |

Use `memory` for recent detail and `file` for longer history.

Watch new logs:

```bash
surge-cli log watch
```

`log watch` prints new, unfiltered log lines from the moment the subscription
starts. It does not replay either retained source. The command keeps running
until interrupted and may remain quiet when no new logs are produced.

With `--raw`, a retained-log response contains `source`,
`requested-line-count`, `line-count`, and `log`. Each watched log event contains
`level`, `module`, and `log`.

Related commands:

```bash
surge-cli set-log-level <log-level>
surge-cli logbook <limit>
surge-cli script-log <log-name> <session-id>
```

- `set-log-level` changes the runtime file log level without modifying the
  profile.
- `logbook` displays recent structured logbook records.
- `script-log` displays the log from one script execution.

### 3.17 Human-readable parsers

Unless `--raw` is used, the CLI has dedicated presentation parsers for all
user-facing `dump` types, environment tests, policy tests, policy runtime
status, daily management commands, external resources, Ponte diagnostics,
managed-profile updates, logbook records, and script logs. Mutation commands
whose useful response is only `success` continue to use the generic result
parser. Binary/data-channel commands such as `retrieve-data`,
`get-resource device-icon`, and `provider-message` intentionally retain
JSON/data-oriented output.

## 4. `set` Command and Environment Dictionary (Key Section)

### 4.1 Syntax

```bash
surge-cli set <key-path>=<value> [<key-path>=<value> ...]
```

- Multiple `key=value` pairs are allowed in one command.
- Any argument without `=` fails with `Illegal parameter`.
- `<nil>` and `(null)` are treated as `nil`.

### 4.2 Key-path behavior

- Normal key-paths are applied via key-path assignment.
- Prefix `ProxyGroupSelection.` is handled as map merge for select-group decisions.
- Prefix `AutoPolicyGroupOverride.` is handled as map merge for auto-group overrides.

Examples:

```bash
surge-cli set ProxyMode=2
surge-cli set ProxyGroupSelection.Proxy=HK
surge-cli set AutoPolicyGroupOverride.Streaming=<nil>
surge-cli set RewriteEnabled=0 ScriptingEnabled=1
```

### 4.3 Top-level environment keys

| Key | Type | Meaning | Example |
|---|---|---|---|
| `ProxyGroupSelection` | `dict<string,string>` | current selection for select groups | `ProxyGroupSelection.<group>=<policy>` |
| `AutoPolicyGroupOverride` | `dict<string,string\|nil>` | override selection for auto groups | `AutoPolicyGroupOverride.<group>=<policy-or-<nil>>` |
| `ProxyMode` | `int` | outbound mode: `0=Direct` `1=Global Proxy` `2=Rule` | `ProxyMode=2` |
| `AllProxyModePolicyNameKey` | `string` | policy name used in global proxy mode | `AllProxyModePolicyNameKey=ProxyA` |
| `MitMEnabled` | `bool` | MITM switch | `MitMEnabled=1` |
| `RewriteEnabled` | `bool` | Rewrite switch | `RewriteEnabled=1` |
| `ScriptingEnabled` | `bool` | Scripting switch | `ScriptingEnabled=1` |
| `Replica` | `bool` | HTTP capture switch | `Replica=1` |
| `ReplicaSessionParameters` | `dict` | HTTP capture session parameters | see 4.4 |
| `InMemoryCaptureFilter` | `dict` | in-memory capture filter params | see 4.5 |
| `OnDiskCaptureFilter` | `dict` | on-disk capture filter params | see 4.5 |
| `PacketCaptureEnabled` | `bool` | packet capture switch | effective on iOS/tvOS |
| `PacketCaptureParameters` | `dict` | packet capture parameters | see 4.6 |
| `SGEnvironmentCellularModeEnabledKey` | `bool` | cellular mode switch | `SGEnvironmentCellularModeEnabledKey=1` |
| `SGEnvironmentCellularModeProcessPathsKey` | `array<string>` | allowed process paths in cellular mode | complex type, see 4.7 |

### 4.4 `ReplicaSessionParameters` fields

| Field | Type | Default |
|---|---|---|
| `sizeLimit` | `int` | `52428800` (50MB) |
| `requestCountLimit` | `int` | `100` |
| `timeLimit` | `int` (seconds) | `180` |
| `mitmOverride` | `bool` | `1` |
| `mitmOverrideHostnames` | `array<string>` | built-in default list |
| `mitmOverrideHostnamesDisabled` | `array<string>` | empty |

Example (scalar updates are straightforward):

```bash
surge-cli set Replica=1 ReplicaSessionParameters.requestCountLimit=200
```

### 4.5 `InMemoryCaptureFilter` / `OnDiskCaptureFilter` fields

| Field | Type | Meaning |
|---|---|---|
| `httpOnly` | `bool` | HTTP-only capture |
| `hideCrashReporterRequest` | `bool` | hide crash reporter traffic (default `1`) |
| `hideAppleRequest` | `bool` | hide Apple traffic |
| `hideUDP` | `bool` | hide UDP traffic |
| `filterType` | `int` | `0=None` `1=Whitelist` `2=Blacklist` `3=Pattern` |
| `keywordFilter` | `array<string>` | keyword list |
| `disabledKeywordFilter` | `array<string>` | disabled keywords |

### 4.6 `PacketCaptureParameters` fields

| Field | Type | Default |
|---|---|---|
| `sizeLimit` | `int` | `1048576` (1MB) |
| `packetCountLimit` | `int` | `100` |
| `timeLimit` | `int` (seconds) | `180` |
| `packetType` | `int` | `0=Unknown` `1=ICMP` `6=TCP` `17=UDP` |

### 4.7 Type handling notes (important for agents)

- CLI sends values as strings; booleans/integers rely on runtime conversion (`boolValue` / `integerValue`).
- Complex arrays/dictionaries are not ideal to set as raw string literals from shell commands.
- Recommended approach:
  - prefer scalar key-path updates;
  - use JSON/SDK path for complex structures when possible;
  - fetch `environment` first, then apply minimal deltas.

### 4.8 Runtime behavior notes

- Successful `set` triggers environment-change notifications.
- If `MitMEnabled=1` is invalid under current runtime conditions, it is auto-corrected to `0`.
- In global proxy mode (`ProxyMode=1`), an invalid `AllProxyModePolicyNameKey` is auto-fallbacked to a valid policy (or `DIRECT`).

## 5. Practical Recommendations for AI Agents

1. Use the default rendered output; do not pass `--raw` unless a documented
   field is unavailable in the rendered form.
2. Start network troubleshooting with `status` and `dump summary`; before
   mutating settings, also collect relevant context with `environment`,
   `dump policy`, and `dump profile`.
3. For streaming commands (`diagnostics`, `test-policy-bandwidth`, `benchmark encryption`, `test-ponte`), handle incremental chunks and end conditions.
4. Check platform capability before using platform-limited commands (`update-profile`, `set-dhcp-device`, `provider-message`).
