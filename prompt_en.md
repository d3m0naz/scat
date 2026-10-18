# scat build task (Bash TUI, macOS, without Docker/pods for now)

Build a terminal application in Bash that provides a client for monitoring and managing remote servers over SSH. The result should be a TUI (text user interface) that runs in a macOS terminal.

## Scope

- Implement the server features: managing a list of servers (add, edit, delete, persist to a config file), connecting to them over SSH, and displaying server status and system metrics (e.g., uptime, load, CPU, memory, disk usage, running processes, where the remote system provides them).
- Do NOT implement the Docker or Kubernetes/pods functionality yet. Leave a clear extension point (a separate module or function namespace) so it can be added later without restructuring the code.

## Requirements

- **Language and shell:** Bash 5.3, installed via Homebrew at `/opt/homebrew/bin/bash` (Apple Silicon, aarch64-apple-darwin25.6.0). Do NOT target the system `/bin/bash` 3.2. Use `#!/usr/bin/env bash` as the shebang, and at startup check that `BASH_VERSINFO[0]` is at least 5. If not, exit with a message telling the user to install bash via `brew install bash` and to put `/opt/homebrew/bin` first in PATH. Associative arrays, `mapfile`/`readarray`, fractional `read -t` timeouts (e.g. 0.1) and other Bash 4+/5 features are allowed.
- **Platform:** macOS (Darwin 25.x), default login shell zsh. The scripts run under bash explicitly. Avoid non-default dependencies where possible; if one is necessary (e.g., `jq`), check for it at startup and print a helpful install hint via Homebrew.
- **TUI:** Build it with plain Bash plus `tput`/ANSI escape codes (or `dialog`/`whiptail` only if clearly justified). Support keyboard navigation (arrow keys, Enter, Esc/q to go back or quit), a header/footer bar, and a clean restore of the terminal state on exit (trap on EXIT/INT/TERM).
- Handle terminal resizing gracefully and avoid flicker by redrawing only when needed.
- **Structure:** Keep the code modular: one entry script plus a `lib/` directory with focused files (config, ssh, ui, views). Use functions with clear names and comments only where the logic is non-obvious, matching the density of the surrounding code.
- **Configuration:** Store it in a user-level path (e.g., `~/.config/scat/`) with sane file permissions. Never store passwords in plain text; rely on SSH keys or the SSH agent, and document this.
- **Safety:** Validate all user input and quote variables properly. Run remote commands so they fail gracefully on timeouts or unreachable hosts (use `ssh -o ConnectTimeout=...` and `BatchMode=yes`).

## Deliverables

1. The complete file structure with all scripts, made executable.
2. A short README explaining installation (including the Homebrew Bash requirement), usage, keybindings, the config format, and which features are implemented versus planned (including the deferred Docker/pods part).
3. Basic verification: run `/opt/homebrew/bin/bash -n` on every script for syntax, and test the non-interactive parts (config read/write, command construction) with a quick script. Report the actual results. If something cannot be tested here, say so.

Before writing code, inspect the working directory for existing files and don't overwrite anything already there without checking it first. Where the feature set is ambiguous, pick the most reasonable interpretation, list those choices in the final summary, and keep them easy to change.
