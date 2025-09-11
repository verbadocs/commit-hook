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

# === 5) Configure Claude logging for this repo ===
echo "🔧 Configuring Claude logging to prompts.txt in this repo..."

# Remove existing claude function if it exists
if grep -q "claude() {" ~/.zshrc 2>/dev/null; then
  cp ~/.zshrc ~/.zshrc.bak.$(timestamp)
  echo "🗂  Backed up .zshrc"
  perl -i -pe 'BEGIN{undef $/;} s/claude\(\) \{.*?\n\}//smg' ~/.zshrc
fi

# Add new claude function with prompt parsing
cat >> ~/.zshrc << 'EOF'

claude() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    local repo_root="$(git rev-parse --show-toplevel)"
    local log_file="$repo_root/prompts.txt"
  else
    local log_file="~/claude.log"
  fi
  
  local session_file="/tmp/claude-session-$(date +%s).log"
  local last_processed_position=0
  
  echo "[$(date -Iseconds)] Claude session started" >> "$log_file"
  
  # Function to process new prompts from session file
  process_new_prompts() {
    if [[ ! -f "$session_file" ]]; then
      return
    fi
    
    local file_content
    if ! file_content=$(cat "$session_file" 2>/dev/null); then
      return
    fi
    
    # Only process content after our last position
    local new_content="${file_content:$last_processed_position}"
    if [[ ${#new_content} -eq 0 ]]; then
      return
    fi
    
    # Track prompts seen in this processing run to avoid duplicates
    local -A seen_prompts
    
    # Process new lines for prompts - split by newlines exactly like the extension
    while IFS= read -r line; do
      if [[ -z "$line" ]]; then
        continue
      fi
      
      # Remove ANSI codes and carriage returns, then trim (handle non-ASCII bytes)
      local clean_line=$(echo "$line" | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r' | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      
      # Check if it's a user prompt line (starts with "> " and length > 2)
      if [[ "$clean_line" == "> "* ]] && [[ ${#clean_line} -gt 2 ]]; then
        # Extract prompt (substring from position 2, like extension)
        local prompt="${clean_line:2}"
        
        # Filter out UI hints - exactly like extension
        if [[ ! "$prompt" == *"Try"* ]] && [[ ! "$prompt" == *"<filepath>"* ]] && [[ ${#prompt} -gt 0 ]]; then
          # Only log if we haven't seen this exact prompt in this processing run
          if [[ -z "${seen_prompts[$prompt]}" ]]; then
            seen_prompts[$prompt]=1
            echo "[$(date -Iseconds)] User Prompt: $prompt" >> "$log_file"
          fi
        fi
      fi
    done <<< "$new_content"
    
    # Update our position to full file length
    last_processed_position=${#file_content}
  }
  
  # Start background monitoring process
  {
    # Initial delay before first processing (like the extension)
    sleep 2
    process_new_prompts
    
    # Then process every 5 seconds
    while [[ -f "$session_file.active" ]]; do
      sleep 5
      process_new_prompts
    done
  } &
  local monitor_pid=$!
  
  # Create active marker file
  touch "$session_file.active"
  
  # Start Claude with script capture
  script -q "$session_file" claude "$@"
  
  # Claude has exited, stop monitoring
  rm -f "$session_file.active"
  
  # No need for final processing - the background monitor will catch everything
  
  # Kill monitor process if still running
  kill $monitor_pid 2>/dev/null
  wait $monitor_pid 2>/dev/null
  
  # Cleanup
  rm -f "$session_file"
  
  echo "[$(date -Iseconds)] Claude session ended" >> "$log_file"
}
EOF

echo "✔ Configured Claude to log parsed prompts to prompts.txt"
echo "   Log file: $REPO_ROOT/prompts.txt"

# === 6) Smoke test hint ===
echo "👉 Test hook with:  git commit --allow-empty -m 'hook test'"
echo "👉 Test Claude logging with:  claude"
echo "👉 Restart your terminal or run: source ~/.zshrc"
