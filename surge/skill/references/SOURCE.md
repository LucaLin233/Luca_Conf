# Upstream Source and Synchronization

## Current snapshot

Synchronized from the Surge Skill bundled on the user's Mac mini on 2026-09-02:

- SSH source alias: `macmini` (synchronization only; never a runtime dependency)
- Source directory: `/Applications/Surge.app/Contents/Resources/Skills/surge/`
- Surge for macOS: `6.9.0` (`12250`, formal release; bundled Skill files unchanged from build 12130)
- Core: `6009000`
- Controller Protocol: `25`
- Upstream `SKILL.md`: `904a33f378a45d89e945f470c446f5511d156c977d248f40a7652342ed121f05`
- Upstream `references/command-reference.md` before Minis invocation adaptation: `66f0b248fa7f696ea5f9b8511729f6c82a25c3bee23a6f5305ce4bdf6b64df4b`
- Upstream `references/plugin-authoring.md`: `d41b905588c8a941e5c208854f76b05b8a395f981a6027ba758a8b9ee4ac7193`
- `agents/openai.yaml`: `ef5cdcb1edd583d4b673774aa1e3b1c153b83df23cf1105191e8aac4d09912b1`
- `assets/logo.png`: `6e8ba4a6ee0ac71c7c03e4a5c7ee457d2f782abe71542e9819dc35443fb1d6f9`

The exact official `SKILL.md` snapshot is retained as `upstream-SKILL.md`. The local `SKILL.md` merges its operational guidance with Minis/iOS transport, credential, privacy, and safety rules. The command reference is copied from upstream and automatically receives a small Minis-specific invocation preface.

## Local additions that must survive synchronization

- `scripts/surge_cli.py`: Linux/iSH implementation of External Controller protocol plus the explicit-file official HTTPS `--check` fallback.
- `scripts/surge_ios.py`: localhost HTTP API fallback.
- `scripts/test_policy_descriptor.py`: local helper for testing an unconfigured node through `/v1/scripting/evaluate` plus `$httpClient` `policy-descriptor`, without changing the Profile.
- `scripts/sync_upstream.sh`: repeatable import command.
- `scripts/adapt_upstream_reference.py`: replaces only command-reference section 1.1 with Minis invocation rules.
- `scripts/install.sh`: installs the symlink; Minis environment variable `SURGE_CLI_PASSWORD` is the default credential path.
- `scripts/acceptance.sh`: non-destructive read-only acceptance test.
- `scripts/package_release.py`: scans and builds a sanitized ZIP for sharing.
- `references/controller-cli.md`: protocol and installation notes.
- `references/http-api.md`: HTTP API fallback reference.
- `references/plugin-authoring.md`: exact official macOS plugin authoring guide, synchronized from upstream.
- `SKILL.md`: curated Minis overlay; never blindly overwrite with the macOS file.

Do not sync credential files, profiles, request bodies, API keys, Controller passwords, or any other secrets into the Skill directory.

## Update command

```sh
/var/minis/skills/surge/scripts/sync_upstream.sh
```

Optional SSH alias argument:

```sh
/var/minis/skills/surge/scripts/sync_upstream.sh macmini
```

The script updates the exact upstream snapshot, command reference, plugin authoring guide, agent metadata, and icon. It deliberately preserves the local `SKILL.md` and scripts. After synchronization, compare `references/upstream-SKILL.md` with the previous upstream hash and manually merge any new workflows or capability notes into local `SKILL.md`.

## Runtime architecture

The Minis CLI does not execute the macOS Mach-O binary and does not need SSH at runtime. It connects to Surge iOS External Controller (default `127.0.0.1:6170`) using:

1. password plus CRLF;
2. welcome JSON plus CRLF;
3. one textual command line plus CRLF (bare verb, each following argv item double-quoted);
4. one or more JSON Lines result/event frames.

Surge iOS Protocol 25 still accepts the legacy `{"argv":[...]}` request, but the formal Surge Mac 6.9.0 build 12250 CLI emits the textual format, which the Minis client now follows. Its bundled official Skill/reference files are byte-identical to those first synchronized from build 12130.

Because the Controller parses most command arguments, newly supported ordinary commands can generally be passed through without adding an HTTP endpoint mapping. The local client must still reproduce official CLI-side conversions (currently `summary`, `profile diff`, `rule temp`, `watch speed`, and script-file Base64/mock-type encoding). Online `plugin` operations are ordinary Controller commands on macOS; `plugin validate` and `plugin pack` are local macOS CLI tools and are not implemented in iSH. Human-readable formatters in `surge_cli.py` are optional; `--raw` is the authoritative Controller response.
