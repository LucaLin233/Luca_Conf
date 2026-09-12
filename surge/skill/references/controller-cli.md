# Minis Surge CLI

A Python reimplementation of the transport and command-line surface used by Surge's `surge-cli --remote` mode, designed for iSH/Minis on iOS.

## Protocol

The External Controller transport is a CRLF-delimited command/result stream:

1. Client sends password plus CRLF.
2. Server returns a welcome JSON object plus CRLF.
3. Client sends one textual command line plus CRLF. The command verb is bare and every following argv item is double-quoted, for example `rule "match" "example.com"`.
4. Server returns one result JSON object, or a stream of JSON event objects.

Surge iOS Protocol 25 still accepts the legacy `{"argv":[...]}` JSON request discovered in older official remote-mode clients, but the formal Surge Mac 6.9.0 build 12250 CLI emits the textual command line above. The Minis client follows the current official encoding. Arguments containing CR/LF are rejected locally; ordinary quotes and backslashes are sent verbatim inside the quoted field, matching the official client.

No HTTP API translation is used. The Surge Controller parses most command arguments, so ordinary commands track the connected Surge build. The client also reproduces the official CLI's known local conversions for `summary`, `profile diff`, `rule temp`, `watch speed`, and `script evaluate <file>` (including mock-type name to numeric ID conversion). Online `plugin` operations are ordinary Controller commands on macOS; the official CLI's offline `plugin validate` and `plugin pack` depend on local macOS tooling and are intentionally unavailable in iSH. `--raw` returns the resulting Controller JSON unchanged apart from compact serialization.

## Installation

`/usr/local/bin/surge-cli` is a symlink to `scripts/surge_cli.py`.

Default controller: `127.0.0.1:6170` (override with `SURGE_CLI_REMOTE` or `--remote`).

Credential precedence:

1. `--password-stdin`
2. `SURGE_CLI_PASSWORD` — recommended for Minis; store it in Settings → Environment Variables
3. secure interactive prompt

The CLI does not create or read password files. When `SURGE_CLI_PASSWORD` is missing, offer the Minis environment-variable settings link rather than asking the user to disclose the password in chat.

## Compatibility

Most commands are transparently passed to Surge. Human-readable formatting is implemented for common commands such as status, version, mode, features, policy groups, rule match/explain, DNS lookup/trace, modules, GeoIP, performance, and macOS VMNET diagnostics. Other commands print pretty JSON; use `--raw` for scripting and exact Controller data.

Protocol 23 adds `vmnet status|arp|ndp|ra`. The local client passes these through and can render their response, but Surge iOS currently returns `Unsupported command`; the VMNET backend is macOS-only.

Protocol 24 adds `restart-engine`. Unlike `reload`, it completely restarts the engine, closes active connections, and clears caches and temporary rules. It uses the ordinary Controller command transport and returns `{"result":"success"}` before or during the restart. The formal Surge iOS 5.22.0 release retains this documented behavior. On its internal Controller version 5.102.0 build 3830 / Protocol 25, authentication, CRLF framing, and the read-only command suite remain compatible; the clear difference between `reload` and `restart-engine` was previously verified on build 3822. Protocol 25 may contain additional capabilities not documented in the release notes; do not infer unsupported command names from the protocol number alone.

- `--check <path>` / `-c <path>` uses Surge's official beta HTTPS validation service (`https://services.nssurge.com/v1/config/validate`) because the bundled macOS local parser is unavailable in iSH. It reads only the explicitly named UTF-8 file, POSTs a JSON `profile` field, prints `OK` or `Failed: ...`, and exits 0/1 like the official CLI. This is an upload: never substitute or upload the active profile implicitly, and warn/redact when a profile may contain server addresses, subscription URLs, usernames, passwords, PSKs, or other secrets.
