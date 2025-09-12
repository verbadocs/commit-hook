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
  local processed_lines_file="/tmp/claude-processed-$(date +%s).txt"
  
  echo "[$(date -Iseconds)] Claude session started" >> "$log_file"
  
  # Function to process new prompts and responses from session file
  process_new_prompts() {
    if [[ ! -f "$session_file" ]]; then
      return
    fi
    
    # Get number of lines already processed
    local processed_lines=0
    if [[ -f "$processed_lines_file" ]]; then
      processed_lines=$(cat "$processed_lines_file" 2>/dev/null || echo "0")
    fi
    
    # Get total lines in file
    local total_lines=$(wc -l < "$session_file" 2>/dev/null || echo "0")
    
    # Only process if there are new lines
    if [[ $total_lines -le $processed_lines ]]; then
      return
    fi
    
    # Process only new lines
    local new_lines=$((total_lines - processed_lines))
    local content
    if ! content=$(tail -n "$new_lines" "$session_file" 2>/dev/null); then
      return
    fi
    
    # Track what we've seen to avoid duplicates
    local -A seen_prompts
    local -A seen_responses
    local -A seen_tools
    
    while IFS= read -r line; do
      if [[ -z "$line" ]]; then
        continue
      fi
      
      # Remove ANSI codes and carriage returns, then trim
      local clean_line=$(printf '%s\n' "$line" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      
      # Skip empty lines after cleaning
      if [[ -z "$clean_line" ]]; then
        continue
      fi
      
      # Check if it's a user prompt line (starts with "> " and length > 2)
      if [[ "$clean_line" == "> "* ]] && [[ ${#clean_line} -gt 2 ]]; then
        local prompt="${clean_line:2}"
        
        # Filter out UI hints and duplicates
        if [[ ! "$prompt" == *"Try"* ]] && [[ ! "$prompt" == *"<filepath>"* ]] && [[ ${#prompt} -gt 0 ]]; then
          if [[ -z "${seen_prompts[$prompt]}" ]]; then
            seen_prompts[$prompt]=1
            # Use a subshell to avoid script capturing this output
            (echo "[$(date -Iseconds)] User Prompt: $prompt" >> "$log_file") 2>/dev/null
          fi
        fi
      # Check if it's a Claude response line
      elif [[ "$clean_line" == "⏺ "* ]]; then
        local response="${clean_line:2}"
        
        # Capture text responses
        if [[ ${#response} -gt 0 ]] && [[ ! "$response" == *"("*")"* ]]; then
          if [[ -z "${seen_responses[$response]}" ]]; then
            seen_responses[$response]=1
            (echo "[$(date -Iseconds)] Claude Response: $response" >> "$log_file") 2>/dev/null
          fi
        # Capture tool calls
        elif [[ "$response" == *"("*")"* ]]; then
          if [[ -z "${seen_tools[$response]}" ]]; then
            seen_tools[$response]=1
            (echo "[$(date -Iseconds)] Tool Call: $response" >> "$log_file") 2>/dev/null
          fi
        fi
      # Check for tool results
      elif [[ "$clean_line" == "⎿ "* ]] && [[ ${#clean_line} -gt 10 ]]; then
        local result="${clean_line:2}"
        if [[ ! "$result" == *"Tip:"* ]] && [[ ! "$result" == *"interrupt"* ]]; then
          (echo "[$(date -Iseconds)] Tool Result: $result" >> "$log_file") 2>/dev/null
        fi
      fi
    done <<< "$content"
    
    # Update processed lines count
    echo "$total_lines" > "$processed_lines_file"
  }
  
  # Start background monitoring process with output redirection
  {
    # Initial delay
    sleep 3
    
    # Monitor while session is active
    while [[ -f "$session_file.active" ]]; do
      process_new_prompts 2>/dev/null
      sleep 5
    done
  } >/dev/null 2>&1 &
  
  local monitor_pid=$!
  
  # Create active marker file
  touch "$session_file.active"
  
  # Start Claude with script capture, but redirect stderr to avoid capturing log writes
  script -q "$session_file" claude "$@" 2>/dev/null
  
  # Claude has exited, stop monitoring
  rm -f "$session_file.active"
  
  # Final processing of any remaining content
  sleep 1
  process_new_prompts 2>/dev/null
  
  # Kill monitor process if still running
  if kill -0 $monitor_pid 2>/dev/null; then
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
  fi
  
  # Cleanup
  rm -f "$session_file"
  rm -f "$processed_lines_file"
  
  (echo "[$(date -Iseconds)] Claude session ended" >> "$log_file") 2>/dev/null
}
EOF

echo "✔ Configured Claude to log parsed prompts to prompts.txt"
echo "   Log file: $REPO_ROOT/prompts.txt"

# === 6) Smoke test hint ===
echo "👉 Test hook with:  git commit --allow-empty -m 'hook test'"
echo "👉 Test Claude logging with:  claude"
echo "👉 Restart your terminal or run: source ~/.zshrc"
