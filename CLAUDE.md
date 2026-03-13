# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`cl` is a single-file Python CLI (`./cl`) that replaces the `claude` command with an fzf-based session picker. It reads Claude Code's internal session data from `~/.claude/` and presents a live-updating list of recent sessions grouped by directory, with state indicators showing whether each session is idle or mid-turn.

## Running and testing

There are no tests, build steps, or dependencies beyond Python 3.8+ stdlib and `fzf`. To test changes:

```bash
python3 cl --picker-lines       # dump picker output (fast, no fzf)
python3 cl --settings-lines     # dump settings output
python3 cl --toggle SET:use_tmux  # toggle a setting
python3 cl --settings           # launch settings fzf panel
python3 cl                      # full picker (requires interactive terminal)
```

Syntax check: `python3 -c "import py_compile; py_compile.compile('cl', doraise=True)"`

## Architecture

Everything lives in `./cl` — a single executable Python script with no internal module imports. The sections are:

- **Settings** (~line 38): `load_settings()`/`save_settings()` with per-process cache, persisted to `~/.claude/cl-settings.json`
- **Launch** (~line 81): `launch_claude()` for direct exec, or `create_and_enter_tmux()` for the tmux wrapper path. `start_session()` dispatches between them based on the `use_tmux` setting and platform.
- **tmux** (~line 94): Session creation with `destroy-unattached` via a `client-attached` hook (can't set it on a detached session or tmux kills it immediately)
- **Session history** (~line 198): `get_history_sessions()` reads `~/.claude/history.jsonl` for session metadata, falls back to scanning `~/.claude/projects/*/` JSONL files. `get_session_tail()` reads the last 32KB of a session file to extract the latest message and turn state.
- **Display** (~line 381): Builds fzf input lines grouped into sections (new session, current dir, other). `build_settings_lines()` builds the settings panel.
- **fzf wiring** (~line 546): `run_fzf()` launches fzf with `load:reload-sync()` for live refresh and `tab:become()` to swap to settings. `run_settings_fzf()` uses `enter:execute-silent()+reload()` for toggle-and-refresh.
- **main** (~line 619): Dispatches internal commands (`--picker-lines`, `--settings-lines`, `--toggle`, `--settings`) used by fzf subprocess calls, then falls through to the interactive picker.

## Key patterns

- **fzf line format**: `KEY\tVISIBLE_CONTENT` — the key column (session ID, `NEW`, `SEP`, `TMUX:name`, `SET:key`) is hidden via `--with-nth 2..` and extracted from stdout after selection.
- **fzf live reload**: The picker re-invokes itself as `cl --picker-lines --delay` every 2s. The `--delay` flag sleeps 2s before generating output (cross-platform alternative to shell `sleep`).
- **fzf panel switching**: Tab uses `become()` to exec `cl --settings` or `cl` (no args), replacing the fzf process with a new invocation in the other mode.
- **Turn state detection**: A completed turn ends with `system:stop_hook_summary` or `system:turn_duration` in the session JSONL. If the last non-metadata entry is `assistant` or `progress`, the session is mid-turn.
- **Path encoding**: Claude Code encodes project paths by replacing `/`, ` `, and `~` with `-`. This encoding is lossy (hyphens in folder names are ambiguous), so we always encode from the known real path rather than trying to decode directory names.

## Cross-platform notes

- `IS_WINDOWS` and `TMUX_AVAILABLE` are set at module level
- Windows uses `subprocess.call` instead of `os.execvp` (which doesn't truly replace the process on Windows)
- `shlex.quote` is used for fzf reload commands; Windows paths with backslashes are normalized in `encode_project_path`
- `get_session_tail` uses binary mode + manual decode to avoid text-mode seek issues with multi-byte UTF-8
