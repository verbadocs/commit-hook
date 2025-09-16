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
  
  echo "[$(date -Iseconds)] Claude session started" >> "$log_file"
  
  # Function to extract code diffs from most recent prompt - exact copy of final_code_diffs.sh logic
  extract_code_diffs() {
    if [[ ! -f "$session_file" ]]; then
      return
    fi
    
    # Check if session file has enough content
    local file_size=$(wc -l < "$session_file" 2>/dev/null || echo "0")
    if [[ $file_size -lt 10 ]]; then
      return
    fi
    
    
    
    # Clean the session file first - exact same as final_code_diffs.sh
    local temp_full_file=$(mktemp)
    cat "$session_file" | \
        LC_ALL=C sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
        LC_ALL=C tr -d '\r' > "$temp_full_file"
    
    # Find the line number of the most recent user input (starts with "> " after cleaning)
    local last_prompt_line=$(grep -n "^> " "$temp_full_file" | tail -1 | cut -d: -f1)
    
    if [[ -z "$last_prompt_line" ]]; then
      rm "$temp_full_file"
      return
    fi
    
    # Extract the actual user prompt text
    local most_recent_prompt=$(sed -n "${last_prompt_line}p" "$temp_full_file" | sed 's/^> //')
    
    
    # Check if we've already logged this prompt (separate from diff processing)
    local prompt_logged_marker="/tmp/claude-logged-$(basename "$session_file").marker"
    local already_logged=""
    if [[ -f "$prompt_logged_marker" ]]; then
      already_logged=$(cat "$prompt_logged_marker" 2>/dev/null || echo "")
    fi
    
    # If this is a new prompt we haven't logged yet, log it immediately
    if [[ "$most_recent_prompt" != "$already_logged" ]]; then
      echo "" >> "$log_file"
      echo "[$(date -Iseconds)] User Prompt: $most_recent_prompt" >> "$log_file"
      echo "" >> "$log_file"
      # Mark this prompt as logged
      echo "$most_recent_prompt" > "$prompt_logged_marker"
      # Clear diff checksums for new prompt
      rm -f "/tmp/claude-prompt-diffs-$(basename "$session_file").hash"
    fi
    
    
    # Find the next user input after the most recent one (to limit scope)
    local next_prompt_line=$(grep -n "^> " "$temp_full_file" | awk -F: -v last="$last_prompt_line" '$1 > last {print $1; exit}')
    
    # Extract only the content between the most recent prompt and the next prompt (or end of file)
    local temp_file=$(mktemp)
    local start_line=$((last_prompt_line + 1))
    local end_line
    
    if [[ -n "$next_prompt_line" ]]; then
      end_line=$((next_prompt_line - 1))
    else
      end_line=$(wc -l < "$temp_full_file")
    fi
    
    # Extract only the content between the most recent prompt and the next prompt (or end of file)
    # This naturally avoids duplicates from previous prompts
    if [[ -n "$next_prompt_line" ]]; then
      # Extract between last prompt and next prompt
      sed -n "$((last_prompt_line + 1)),$((next_prompt_line - 1))p" "$temp_full_file" > "$temp_file"
    else
      # Extract from last prompt to end of file
      tail -n +$((last_prompt_line + 1)) "$temp_full_file" > "$temp_file"
    fi
    
    # Process both diff lines and Write operations
    local current_file=""
    local temp_matches=$(mktemp)
    local temp_writes=$(mktemp)
    
    # Find traditional diff lines (for Update operations)
    grep -n -E '^[[:space:]]*[0-9]+[[:space:]]*[+→-][[:space:]]' "$temp_file" > "$temp_matches"
    
    # Find Write operations and their content
    grep -n "⏺.*Write(" "$temp_file" > "$temp_writes"
    
    # Track diffs for this prompt to avoid duplicates
    local prompt_diff_hash_file="/tmp/claude-prompt-diffs-$(basename "$session_file").hash"
    local logged_new_content=false
    
    # Process traditional diff lines (Update operations)
    if [[ -s "$temp_matches" ]]; then
      while IFS=':' read -r session_line content; do
        # Check for filename patterns before this diff line
        local filename_before=$(head -n "$session_line" "$temp_file" | grep -E "⏺.*Update\(" | tail -1 | sed -E 's/.*⏺.*Update\(([^)]+)\).*/\1/')
        
        # Clean up the line and format it
        local clean_line=$(echo "$content" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        
        # Skip very short or empty lines
        if [[ ${#clean_line} -gt 10 ]]; then
          # Create a hash of this diff line to check for duplicates within this prompt
          local diff_hash=$(echo "$filename_before:$clean_line" | shasum -a 256 | cut -d' ' -f1)
          
          # Check if we've already logged this exact diff for this prompt
          if [[ ! -f "$prompt_diff_hash_file" ]] || ! grep -q "$diff_hash" "$prompt_diff_hash_file" 2>/dev/null; then
            # This is a new diff for this prompt, log it
            logged_new_content=true
            
            # If we found a new filename, show it
            if [[ -n "$filename_before" && "$filename_before" != "$current_file" ]]; then
              current_file="$filename_before"
              echo "" >> "$log_file"
              echo "FILE: $current_file" >> "$log_file"
              echo "----------------------------------------" >> "$log_file"
            fi
            
            echo "$clean_line" >> "$log_file"
            
            # Mark this diff as logged for this prompt
            echo "$diff_hash" >> "$prompt_diff_hash_file"
          fi
        fi
      done < "$temp_matches"
    fi
    
    # Process Write operations (new file creation)
    if [[ -s "$temp_writes" ]]; then
      while IFS=':' read -r write_line write_content; do
        # Extract filename from Write operation
        local write_filename=$(echo "$write_content" | sed -E 's/.*⏺.*Write\(([^)]+)\).*/\1/')
        
        if [[ -n "$write_filename" ]]; then
          # Create a hash for this write operation
          local write_hash=$(echo "WRITE:$write_filename" | shasum -a 256 | cut -d' ' -f1)
          
          # Check if we've already logged this write operation for this prompt
          if [[ ! -f "$prompt_diff_hash_file" ]] || ! grep -q "$write_hash" "$prompt_diff_hash_file" 2>/dev/null; then
            logged_new_content=true
            
            # Show the filename
            if [[ "$write_filename" != "$current_file" ]]; then
              current_file="$write_filename"
              echo "" >> "$log_file"
              echo "FILE: $current_file" >> "$log_file"
              echo "----------------------------------------" >> "$log_file"
            fi
            
            # Read the complete file content directly from filesystem
            # Handle both absolute and relative paths
            local file_to_read="$write_filename"
            if [[ ! "$write_filename" =~ ^/ ]]; then
              # If it's a relative path, make it relative to the current working directory
              file_to_read="$(pwd)/$write_filename"
            fi
            
            # Wait for file to exist and be fully written (with timeout)
            local max_attempts=30  # 30 attempts = ~60 seconds max wait
            local attempt=0
            local file_found=false
            
            while [[ $attempt -lt $max_attempts ]]; do
              if [[ -f "$file_to_read" ]]; then
                # File exists, wait a moment for it to be fully written
                sleep 1
                # Check if file size is stable (not still being written)
                local size1=$(wc -c < "$file_to_read" 2>/dev/null || echo "0")
                sleep 1
                local size2=$(wc -c < "$file_to_read" 2>/dev/null || echo "0")
                
                if [[ "$size1" == "$size2" ]] && [[ "$size1" -gt 0 ]]; then
                  file_found=true
                  break
                fi
              fi
              sleep 2
              ((attempt++))
            done
            
            # Read and log the complete file content
            if [[ "$file_found" == true ]]; then
              cat "$file_to_read" >> "$log_file"
            else
              echo "# File not found or still being written: $file_to_read (waited ${max_attempts} attempts)" >> "$log_file"
            fi
            
            # Mark this write operation as logged
            echo "$write_hash" >> "$prompt_diff_hash_file"
          fi
        fi
      done < "$temp_writes"
    fi
    
    # Only add trailing empty line if we actually logged new content
    if [[ "$logged_new_content" == true ]]; then
      echo "" >> "$log_file"
    fi
    
    rm "$temp_matches"
    rm "$temp_writes"
    
    # Clean up
    rm "$temp_file"
    rm "$temp_full_file"
  }
  
  # Start background monitoring process with output redirection
  {
    # Initial delay
    sleep 3
    
    # Monitor while session is active
    while [[ -f "$session_file.active" ]]; do
      extract_code_diffs 2>/dev/null
      sleep 2
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
  extract_code_diffs 2>/dev/null
  
  # Kill monitor process if still running
  if kill -0 $monitor_pid 2>/dev/null; then
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
  fi
  
  # Cleanup
  rm -f "$session_file"
  rm -f "/tmp/claude-logged-$(basename "$session_file").marker"
  rm -f "/tmp/claude-prompt-diffs-$(basename "$session_file").hash"
  
  (echo "[$(date -Iseconds)] Claude session ended" >> "$log_file") 2>/dev/null
}
EOF

echo "✔ Configured Claude to log parsed prompts to prompts.txt"
echo "   Log file: $REPO_ROOT/prompts.txt"

# === 6) Smoke test hint ===
echo "👉 Test hook with:  git commit --allow-empty -m 'hook test'"
echo "👉 Test Claude logging with:  claude"
echo "👉 Restart your terminal or run: source ~/.zshrc"
