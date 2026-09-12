#!/bin/sh
# Install the bundled Minis Surge CLI. Credentials belong in Minis environment variables.
set -eu
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TARGET="/usr/local/bin/surge-cli"

chmod 755 "$SELF_DIR"/*.py "$SELF_DIR"/*.sh
ln -sf "$SELF_DIR/surge_cli.py" "$TARGET"
python3 - "$SELF_DIR/surge_cli.py" "$SELF_DIR/adapt_upstream_reference.py" <<'PY'
import sys
for name in sys.argv[1:]:
    source=open(name,encoding="utf-8").read()
    compile(source,name,"exec")
PY

echo "Installed: $TARGET -> $SELF_DIR/surge_cli.py"
if [ -n "${SURGE_CLI_PASSWORD:-}" ]; then
  echo "SURGE_CLI_PASSWORD: set"
  echo "Run: $SELF_DIR/acceptance.sh"
else
  echo "SURGE_CLI_PASSWORD: missing"
  echo "Set it in Minis Settings -> Environment Variables, then run:"
  echo "  $SELF_DIR/acceptance.sh"
fi
