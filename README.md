# cl

Session manager for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Pick from recent sessions, see what each one is doing, and resume without desync.

```
 Sessions  [tab: settings]
   +  ~/myproject                new session
  --- ~/myproject ---
 ● 1m  ~/myproject              Done. Here's the updated config...
 ⟳ 3m  ~/myproject              Running the test suite now...
  --- other sessions ---
 ● 2h  ~/frontend               Fixed the auth redirect bug, ...
 ● 5d  ~                        Done. The drive is formatted...
```

- **Live-updating** — the picker refreshes every 2 seconds so you can watch a session finish
- **Session state** — `●` idle (safe to resume), `⟳` processing (resuming may desync)
- **Last message preview** — see what claude said most recently, not just the first prompt
- **tmux integration** (macOS/Linux) — sessions run inside tmux so you can SSH in and attach to a running session from another machine
- **Settings panel** — press Tab to toggle features like tmux wrapping
- **Cross-platform** — works on macOS, Linux, and Windows (PowerShell)

## Install

```bash
git clone https://github.com/Hollings/cl.git
cd cl
./install.sh        # macOS / Linux
# or
./install.ps1       # Windows (PowerShell)
```

This symlinks `cl` into `~/.local/bin` (or copies on Windows) and checks for missing dependencies.

### Dependencies

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI)
- [fzf](https://github.com/junegunn/fzf) — fuzzy finder for the picker UI
- [tmux](https://github.com/tmux/tmux) — optional, enables SSH attach to running sessions
- Python 3.8+

## Usage

```bash
cl                    # open the session picker
cl "fix the auth bug" # start a new session with a prompt (skip picker)
cl --update           # self-update from GitHub
```

### Picker controls

| Key | Action |
|-----|--------|
| Enter | Select session / toggle setting |
| Tab | Switch between sessions and settings |
| Esc | Exit |
| Type | Filter sessions by fuzzy search |

### Settings

Press Tab in the picker to access settings. Changes persist to `~/.claude/cl-settings.json`.

| Setting | Default | Description |
|---------|---------|-------------|
| tmux wrapping | ON | Wrap sessions in tmux for SSH attach. Disable for direct launch. |
| skip permissions | ON | Pass `--dangerously-skip-permissions` to claude. |

### tmux behavior

When tmux wrapping is enabled:

- Each session runs inside a tmux session named `cl/<project>`
- SSH into the machine, run `cl`, and attach to the running session — same terminal, no desync
- Sessions auto-destroy when all terminals viewing them disconnect (no orphans)
- Closing a tab doesn't leave zombie tmux sessions

When tmux is off or unavailable (Windows), sessions launch directly.

## How it works

`cl` reads Claude Code's session data from `~/.claude/`:

- **`history.jsonl`** — maps session IDs to project paths and timestamps
- **`projects/<encoded-path>/<session-id>.jsonl`** — full session transcripts

For each session, it reads the tail of the JSONL file to extract the latest message and determine whether claude is idle or mid-turn. The turn boundary is detected by looking for `system:stop_hook_summary` entries that mark completed turns.
