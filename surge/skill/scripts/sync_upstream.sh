#!/bin/sh
# Atomically sync the official Surge Skill snapshot from a Mac installation.
set -eu
HOST="${1:-macmini}"
REMOTE="/Applications/Surge.app/Contents/Resources/Skills/surge"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
LOCAL="$(dirname "$SELF_DIR")"
TMP="$(mktemp -d /tmp/surge-skill.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/upstream"
scp -q -r "$HOST:$REMOTE/." "$TMP/upstream/"
for file in SKILL.md agents/openai.yaml assets/logo.png references/command-reference.md references/plugin-authoring.md; do
  [ -f "$TMP/upstream/$file" ] || { echo "Missing upstream file: $file" >&2; exit 1; }
done

mkdir -p "$TMP/staged/references" "$TMP/staged/agents" "$TMP/staged/assets"
cp "$TMP/upstream/SKILL.md" "$TMP/staged/references/upstream-SKILL.md"
cp "$TMP/upstream/references/command-reference.md" "$TMP/staged/references/command-reference.md"
cp "$TMP/upstream/references/plugin-authoring.md" "$TMP/staged/references/plugin-authoring.md"
cp "$TMP/upstream/agents/openai.yaml" "$TMP/staged/agents/openai.yaml"
cp "$TMP/upstream/assets/logo.png" "$TMP/staged/assets/logo.png"
python3 "$SELF_DIR/adapt_upstream_reference.py" "$TMP/staged/references/command-reference.md"
VERSION="$(ssh "$HOST" '/Applications/Surge.app/Contents/Applications/surge-cli version' | sed -n '1p')"
[ -n "$VERSION" ] || { echo "Unable to determine upstream Surge version" >&2; exit 1; }

mkdir -p "$LOCAL/agents" "$LOCAL/assets" "$LOCAL/references"
for file in references/upstream-SKILL.md references/command-reference.md references/plugin-authoring.md agents/openai.yaml assets/logo.png; do
  cp "$TMP/staged/$file" "$LOCAL/$file.new"
  chmod 644 "$LOCAL/$file.new"
  mv "$LOCAL/$file.new" "$LOCAL/$file"
done

echo "Synchronized: $VERSION"
sha256sum "$LOCAL/references/upstream-SKILL.md" "$LOCAL/references/command-reference.md" "$LOCAL/agents/openai.yaml" "$LOCAL/assets/logo.png"
echo "Review upstream-SKILL.md changes and merge new operational guidance into SKILL.md when needed. Minis transport and safety overlays were preserved."
