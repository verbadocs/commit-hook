#!/usr/bin/env bash
# install-hook.sh — installs a remote pre-commit into .git/hooks
set -euo pipefail

# === CONFIG ===
# Change this to the raw URL of your pre-commit hook in GitHub:
HOOK_URL="${HOOK_URL:-https://raw.githubusercontent.com/verbadocs/commit-hook/main/.githooks/pre-commit}"

# Set INIT_IF_MISSING=true to auto "git init" when run outside a repo
INIT_IF_MISSING="${INIT_IF_MISSING:-false}"

# === FUNCTIONS ===
have() { command -v "$1" >/dev/null 2>&1; }

fetch_to_file() {
  local url="$1" out="$2"
  if have curl; then
    curl -fsSL "$url" -o "$out"
  elif have wget; then
    wget -qO "$out" "$url"
  else
    echo "❌ Need curl or wget to download $url" >&2
    exit 1
  fi
}

timestamp() { date +%Y%m%d-%H%M%S; }

# === 1) Ensure we are in a git repo (or init if allowed) ===
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  if [ "$INIT_IF_MISSING" = "true" ]; then
    echo "🔧 No git repository detected. Running: git init"
    git init
  else
    echo "❌ Not a git repository. Run inside a repo or set INIT_IF_MISSING=true" >&2
    exit 1
  fi
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# === 2) Resolve hooks dir and destination path ===
HOOKS_DIR="$(git rev-parse --git-path hooks)"
DEST="$HOOKS_DIR/pre-commit"
mkdir -p "$HOOKS_DIR"

# === 3) Backup an existing hook if present ===
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  BAK="$DEST.bak.$(timestamp)"
  cp "$DEST" "$BAK"
  echo "🗂  Backed up existing pre-commit -> $BAK"
fi

# === 4) Download to a temp file, then atomically move into place ===
TMP="$(mktemp)"
echo "⬇️  Downloading hook from: $HOOK_URL"
fetch_to_file "$HOOK_URL" "$TMP"

# Quick sanity check
if ! head -n1 "$TMP" | grep -qE '^#!'; then
  echo "⚠️  Warning: downloaded hook has no shebang on the first line." >&2
fi

mv "$TMP" "$DEST"
chmod +x "$DEST"

echo "✔ Installed .git/hooks/pre-commit"
echo "   Repo: $REPO_ROOT"
echo "   Hook: $DEST"

# === 5) Smoke test hint ===
echo "👉 Test it with:  git commit --allow-empty -m 'hook test'"
