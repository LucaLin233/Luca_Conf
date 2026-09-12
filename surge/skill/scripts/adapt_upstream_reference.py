#!/usr/bin/env python3
"""Apply Minis transport notes to an upstream Surge command reference."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
start = text.index("## 1. CLI Usage")
end = text.index("### 1.2 Response envelope", start)
replacement = '''## 1. CLI Usage

> Minis adaptation: this command catalog is synchronized from the Surge-bundled Skill. In Minis, `/usr/local/bin/surge-cli` connects directly to Surge iOS External Controller. Use this section's adapted invocation rules; the remaining command semantics are upstream documentation and platform restrictions still apply.

### 1.1 Basic format

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

'''
path.write_text(text[:start] + replacement + text[end:])

# The upstream baseline includes a full profile dump, which may expose proxy
# addresses or subscription URLs. Keep it opt-in in the Minis reference.
text = path.read_text()
text = text.replace(
    "Before mutating settings, collect context with `environment`, `dump policy`, and `dump profile`.",
    "Before mutating settings, collect context with `status`, `environment`, and `dump policy`. Run `dump profile` only when necessary and treat its output as sensitive.",
)
path.write_text(text)
