# Commit Hook with Claude Logging

A smart Git pre-commit hook that automatically tracks and logs your Claude AI interactions, creating organized commit histories with AI-assisted development records.

## Installation

1) Full install (hook + verba/ + shell edits)

```bash
curl -fsSL https://raw.githubusercontent.com/verbadocs/commit-hook/main/scripts/install-hook.sh | bash -s --
```

2) Single-repo Init (hook + verba/, no shell edits)

```bash
curl -fsSL https://raw.githubusercontent.com/verbadocs/commit-hook/main/scripts/install-hook.sh | bash -s -- --no-shell-edit
```
3) Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/verbadocs/commit-hook/main/scripts/install-hook.sh | bash -s -- --uninstall
```




### What the installer does:

1. Downloads and installs the pre-commit hook to `.git/hooks/pre-commit`
2. Creates a `verba/` directory for storing AI interaction logs
3. Configures a `claude()` shell function that logs your interactions
4. Backs up any existing configurations safely

## Features

- **Automatic Claude Logging**: Captures all your Claude interactions in `verba/prompts.txt`
- **Smart Pre-commit Hook**: Automatically includes Claude session logs in your commits
- **Organized History**: Creates timestamped prompt logs for each commit
- **Zero Configuration**: Works out of the box after installation


## How it Works

1. **Claude Logging**: The `claude()` function wraps the Claude CLI and logs all interactions to `verba/prompts.txt`
2. **Pre-commit Processing**: Before each commit, the hook processes new Claude interactions since the last commit
3. **Automatic Documentation**: Creates markdown files in `verba/prompt_history/` with organized logs
4. **Commit Integration**: Automatically adds the generated logs to your commit

## Usage

After installation:

1. **Test the hook**: `git commit --allow-empty -m 'hook test'`
2. **Use Claude**: `claude` (instead of the regular CLI)
3. **Make commits**: Your Claude interactions will be automatically included

## File Structure

```
your-repo/
├── verba/
│   ├── prompts.txt                 # Raw Claude interaction logs
│   └── prompt_history/             # Organized prompt logs per commit
│       └── prompt-logs-YYYYMMDD-HHMMSS.md
└── .git/hooks/
    └── pre-commit                  # The installed hook
```

## Requirements

- Git repository
- Bash shell
- `curl` or `wget`
- Claude CLI installed and configured

## Configuration

The installer automatically configures everything, but you can customize:

- `HOOK_URL`: Change the source URL for the pre-commit hook
- `INIT_IF_MISSING`: Set to `true` to auto-initialize Git repos

## Troubleshooting

- **Restart your terminal** or run `source ~/.zshrc` after installation
- Check that the Claude CLI is properly installed and configured
- Verify the hook is executable: `ls -la .git/hooks/pre-commit`

---

*This tool helps maintain a complete record of AI-assisted development sessions alongside your code changes.*
