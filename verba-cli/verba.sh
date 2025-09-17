#!/usr/bin/env bash
set -euo pipefail

# Single source of truth for the installer URL
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/verbadocs/commit-hook/main/scripts/install-hook-new.sh}"

usage() {
  cat <<USAGE
verba — let's version your prompts!

Usage:
  verba install          # full install: hook + verba/ + shell rc edits (claude())
  verba init             # hook + verba/ only (NO shell rc edits)
  verba init --git-init  # run 'git init' if needed, then same as 'init'
  verba uninstall        # remove hook and the claude() block

Env:
  INSTALL_URL=<url>      # override installer URL
USAGE
}

cmd="${1:-}"

case "$cmd" in
  install)
    # Full install = do everything (no flags)
    curl -fsSL "$INSTALL_URL" | bash -s --
    ;;

  init)
    shift || true
    if [[ "${1:-}" == "--git-init" ]]; then
      # Allow creating a new repo and skip shell edits
      curl -fsSL "$INSTALL_URL" | bash -s -- --no-shell-edit --init-if-missing
    else
      # Must be inside a git repo (no shell edits)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        curl -fsSL "$INSTALL_URL" | bash -s -- --no-shell-edit
      else
        echo "Not a git repo. Run 'git init' first or use: verba init --git-init" >&2
        exit 1
      fi
    fi
    ;;

  uninstall)
    curl -fsSL "$INSTALL_URL" | bash -s -- --uninstall
    ;;

  ""|-h|--help|help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
