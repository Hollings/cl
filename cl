#!/usr/bin/env python3
"""cl - Claude Code session manager

Run without arguments to pick from recent sessions.
Run with arguments to start a new session directly.

On systems with tmux, sessions run inside tmux so you can attach from
SSH. Sessions auto-destroy when all terminals disconnect.
Without tmux, sessions launch directly (still get the picker).
"""

import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from shutil import which

IS_WINDOWS = sys.platform == "win32"
CLAUDE_DIR = Path.home() / ".claude"
HISTORY_FILE = CLAUDE_DIR / "history.jsonl"
PROJECTS_DIR = CLAUDE_DIR / "projects"

CLAUDE_BIN = "claude"
BASE_FLAGS = ["--dangerously-skip-permissions"]
TMUX_PREFIX = "cl/"
HAS_TMUX = not IS_WINDOWS and which("tmux") is not None


# --- launch (no tmux) ---


def launch_claude(project_dir, claude_args):
    """Launch claude directly, replacing this process."""
    os.chdir(project_dir)
    cmd = [CLAUDE_BIN] + BASE_FLAGS + list(claude_args)
    if IS_WINDOWS:
        # os.execvp on Windows spawns a child; use subprocess for cleaner exit
        sys.exit(subprocess.call(cmd))
    else:
        os.execvp(CLAUDE_BIN, cmd)


# --- tmux ---


def tmux(*args):
    """Run a tmux command, return CompletedProcess."""
    return subprocess.run(["tmux"] + list(args), capture_output=True, text=True)


def tmux_env(session_name, var):
    """Read a tmux environment variable, or None."""
    result = tmux("show-environment", "-t", session_name, var)
    if result.returncode == 0 and "=" in result.stdout:
        return result.stdout.strip().split("=", 1)[1]
    return None


def tmux_session_exists(name):
    return tmux("has-session", "-t", name).returncode == 0


def get_live_sessions():
    """Return dict of active cl/ tmux sessions: name -> info."""
    if not HAS_TMUX:
        return {}

    result = tmux("list-sessions", "-F", "#{session_name}\t#{session_attached}")
    if result.returncode != 0:
        return {}

    sessions = {}
    for line in result.stdout.strip().split("\n"):
        if not line or not line.startswith(TMUX_PREFIX):
            continue
        parts = line.split("\t")
        name = parts[0]
        sessions[name] = {
            "attached": len(parts) > 1 and parts[1] == "1",
            "claude_sid": tmux_env(name, "CL_SID"),
            "project": tmux_env(name, "CL_PROJECT") or "",
        }
    return sessions


def make_tmux_name(project_path):
    """Generate a unique tmux session name like cl/projectname."""
    basename = Path(project_path).name or "home"
    basename = basename.replace(".", "_").replace(":", "_")
    name = f"{TMUX_PREFIX}{basename}"

    if not tmux_session_exists(name):
        return name
    for i in range(2, 100):
        candidate = f"{name}-{i}"
        if not tmux_session_exists(candidate):
            return candidate
    return f"{name}-{os.getpid()}"


def enter_tmux(name):
    """Attach to or switch to a tmux session (never returns)."""
    if os.environ.get("TMUX"):
        os.execvp("tmux", ["tmux", "switch-client", "-t", name])
    else:
        os.execvp("tmux", ["tmux", "attach-session", "-t", name])


def create_and_enter_tmux(project_dir, claude_args, claude_sid=None):
    """Create a tmux session running claude, then attach.

    Uses a client-attached hook to enable destroy-unattached, so the
    session dies when all viewers disconnect (no orphans). The hook is
    deferred because setting destroy-unattached on a session with zero
    clients kills it immediately.
    """
    name = make_tmux_name(project_dir)
    cmd_str = " ".join(shlex.quote(a) for a in [CLAUDE_BIN] + BASE_FLAGS + list(claude_args))

    subprocess.run(
        ["tmux", "new-session", "-d", "-s", name, "-c", project_dir, cmd_str],
        check=True,
    )

    if claude_sid:
        tmux("set-environment", "-t", name, "CL_SID", claude_sid)
    tmux("set-environment", "-t", name, "CL_PROJECT", project_dir)
    tmux("set-hook", "-t", name, "client-attached", "set destroy-unattached on")

    enter_tmux(name)


# --- session history ---


def encode_project_path(path):
    """Encode a path the way Claude Code names project directories."""
    # Normalize Windows backslashes
    path = path.replace("\\", "/")
    return path.replace("/", "-").replace(" ", "-").replace("~", "-")


def extract_message_text(entry):
    """Pull plain text from a user or assistant message entry."""
    content = entry.get("message", {}).get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                text = part.get("text", "")
                if text:
                    return text
    return ""


def parse_session_file(path):
    """Extract cwd and first user message from a session JSONL file."""
    cwd = first_msg = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not cwd and "cwd" in entry:
                cwd = entry["cwd"]
            if not first_msg and entry.get("type") == "user":
                first_msg = extract_message_text(entry)
            if cwd and first_msg:
                break
    return cwd, first_msg


def get_session_tail(session_file):
    """Read the tail of a session file and return (last_message, is_waiting).

    is_waiting is True if claude has finished its turn and is waiting for
    user input (safe to resume without desync).
    """
    try:
        size = session_file.stat().st_size
    except OSError:
        return "", True

    # Read the tail — last 32KB covers the most recent messages
    tail_bytes = min(size, 32 * 1024)
    try:
        with open(session_file) as f:
            if tail_bytes < size:
                f.seek(size - tail_bytes)
                f.readline()  # skip partial first line
            lines = f.readlines()
    except OSError:
        return "", True

    # Determine state: walk backwards to find the last turn-ending marker
    is_waiting = True
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = entry.get("type", "")
        sub = entry.get("subtype", "")
        # These mark the end of a completed turn
        if t == "system" and sub in ("stop_hook_summary", "turn_duration"):
            is_waiting = True
            break
        if t == "user":
            # Last entry is user — claude hasn't responded yet
            is_waiting = True
            break
        if t in ("assistant", "progress"):
            # Claude is mid-turn
            is_waiting = False
            break
        # Skip metadata entries (file-history-snapshot, last-prompt, etc.)

    # Find the last message with text
    last_msg = ""
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") in ("user", "assistant"):
            text = extract_message_text(entry)
            if text:
                last_msg = text
                break

    return last_msg, is_waiting


def get_history_sessions():
    """Build session list from history.jsonl + project directory scan."""
    sessions = {}

    # Primary: history.jsonl has real project paths and session IDs
    if HISTORY_FILE.exists():
        with open(HISTORY_FILE) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                sid = entry.get("sessionId")
                if not sid:
                    continue
                project = entry.get("project", "")
                ts = entry.get("timestamp", 0)
                display = entry.get("display", "")
                if sid not in sessions:
                    sessions[sid] = {"project": project, "first_msg": display, "last_ts": ts}
                elif ts > sessions[sid]["last_ts"]:
                    sessions[sid]["last_ts"] = ts

    # Secondary: scan project dirs for sessions missing from history
    if PROJECTS_DIR.exists():
        for project_dir in PROJECTS_DIR.iterdir():
            if not project_dir.is_dir():
                continue
            for session_file in project_dir.glob("*.jsonl"):
                sid = session_file.stem
                if sid in sessions:
                    continue
                try:
                    cwd, first_msg = parse_session_file(session_file)
                    if cwd:
                        sessions[sid] = {
                            "project": cwd,
                            "first_msg": first_msg or "",
                            "last_ts": session_file.stat().st_mtime * 1000,
                        }
                except (OSError, json.JSONDecodeError):
                    continue

    # Keep only sessions whose files still exist on disk, resolve file paths
    result = []
    for sid, info in sessions.items():
        encoded = encode_project_path(info["project"])
        session_file = PROJECTS_DIR / encoded / f"{sid}.jsonl"
        if not session_file.exists():
            continue
        result.append({
            "id": sid,
            "project": info["project"],
            "first_msg": info["first_msg"],
            "last_ts": info["last_ts"],
            "file": session_file,
        })

    result.sort(key=lambda x: x["last_ts"], reverse=True)
    return result


# --- display ---


def relative_time(ts_ms):
    now = datetime.now(timezone.utc).timestamp() * 1000
    diff_s = (now - ts_ms) / 1000
    if diff_s < 60:
        return "now"
    if diff_s < 3600:
        return f"{int(diff_s / 60)}m"
    if diff_s < 86400:
        return f"{int(diff_s / 3600)}h"
    days = diff_s / 86400
    if days < 30:
        return f"{int(days)}d"
    return f"{int(days / 30)}mo"


def short_path(path):
    home = str(Path.home())
    if path.startswith(home):
        return "~" + path[len(home):]
    # Windows: also try with normalized separators
    if IS_WINDOWS:
        norm_path = path.replace("/", "\\")
        norm_home = home.replace("/", "\\")
        if norm_path.startswith(norm_home):
            return "~" + norm_path[len(norm_home):]
    return path


def truncate(text, length=50):
    text = text.replace("\n", " ").strip()
    return text[:length - 3] + "..." if len(text) > length else text


def build_picker_lines(live, history, cwd):
    """Build the fzf input lines."""
    live_sids = {v["claude_sid"] for v in live.values() if v["claude_sid"]}
    lines = []

    # New session option
    lines.append(f"NEW\t\x1b[32m   +\x1b[0m  {short_path(cwd)}  \x1b[2mnew session\x1b[0m")

    # Active tmux sessions
    for tname, info in live.items():
        if info["attached"]:
            status, label = "\x1b[32m●\x1b[0m", "attached"
        else:
            status, label = "\x1b[33m○\x1b[0m", "detached"

        proj = short_path(info["project"]) if info["project"] else tname
        msg = ""
        if info["claude_sid"]:
            match = next((h for h in history if h["id"] == info["claude_sid"]), None)
            if match:
                msg_text, _ = get_session_tail(match["file"])
                msg = truncate(msg_text)

        lines.append(
            f"TMUX:{tname}\t{status} \x1b[2m{label:>8}\x1b[0m  \x1b[36m{proj}\x1b[0m  {msg}"
        )

    # Historical sessions not currently in tmux
    for s in history[:50]:
        if s["id"] in live_sids:
            continue
        last_msg, is_waiting = get_session_tail(s["file"])
        state = "\x1b[32m●\x1b[0m" if is_waiting else "\x1b[33m⟳\x1b[0m"
        lines.append(
            f"{s['id']}\t{state} \x1b[33m{relative_time(s['last_ts']):>4}\x1b[0m"
            f"  \x1b[36m{short_path(s['project'])}\x1b[0m  {truncate(last_msg)}"
        )

    return lines


def run_fzf(lines):
    """Show fzf picker with live reload, return selected key or None."""
    # Build the reload command: wait 2s then regenerate lines
    script = shlex.quote(os.path.abspath(sys.argv[0]))
    python = shlex.quote(sys.executable)
    # Use --delay so the sleep is cross-platform (no reliance on sleep cmd)
    reload_cmd = f"{python} {script} --picker-lines --delay"

    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--no-sort",
                "--header", " Claude Code Sessions",
                "--delimiter", "\t", "--with-nth", "2..",
                "--height", "~50%", "--reverse",
                "--bind", f"load:reload({reload_cmd})",
            ],
            input="\n".join(lines),
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        print("fzf is required.")
        if IS_WINDOWS:
            print("  scoop install fzf  OR  winget install junegunn.fzf")
        elif which("brew"):
            print("  brew install fzf")
        else:
            print("  https://github.com/junegunn/fzf#installation")
        sys.exit(1)

    if result.returncode != 0 or not result.stdout.strip():
        return None
    return result.stdout.strip().split("\t")[0]


# --- main ---


def start_session(project_dir, claude_args, claude_sid=None):
    """Start a claude session — in tmux if available, direct otherwise."""
    if HAS_TMUX:
        create_and_enter_tmux(project_dir, claude_args, claude_sid)
    else:
        launch_claude(project_dir, claude_args)


def main():
    # Internal: print picker lines to stdout (used by fzf reload)
    if "--picker-lines" in sys.argv:
        if "--delay" in sys.argv:
            import time
            time.sleep(2)
        history = get_history_sessions()
        live = get_live_sessions()
        cwd = os.getcwd()
        print("\n".join(build_picker_lines(live, history, cwd)))
        return

    # Pass-through: args go straight to claude
    if len(sys.argv) > 1:
        start_session(os.getcwd(), sys.argv[1:])

    history = get_history_sessions()
    live = get_live_sessions()

    # Nothing to pick from — just launch
    if not history and not live:
        start_session(os.getcwd(), [])

    cwd = os.getcwd()
    key = run_fzf(build_picker_lines(live, history, cwd))

    if key is None:
        sys.exit(0)
    elif key == "NEW":
        start_session(cwd, [])
    elif key.startswith("TMUX:"):
        enter_tmux(key[5:])
    else:
        session = next((s for s in history if s["id"] == key), None)
        if not session:
            print(f"Session not found: {key}")
            sys.exit(1)
        start_session(session["project"], ["-r", key], claude_sid=key)


if __name__ == "__main__":
    main()
