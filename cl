#!/usr/bin/env python3
"""cl - Claude Code session manager with tmux integration

Run without arguments to pick from recent sessions.
Run with arguments to start a new session directly.

Every session runs inside tmux so you can attach from SSH.
Sessions auto-destroy when all terminals disconnect.
"""

import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
HISTORY_FILE = CLAUDE_DIR / "history.jsonl"
PROJECTS_DIR = CLAUDE_DIR / "projects"

CLAUDE_BIN = "claude"
BASE_FLAGS = ["--dangerously-skip-permissions"]
TMUX_PREFIX = "cl/"


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


def create_and_enter(name, project_dir, claude_args, claude_sid=None):
    """Create a tmux session running claude, then attach.

    Uses a client-attached hook to enable destroy-unattached, so the
    session dies when all viewers disconnect (no orphans). The hook is
    deferred because setting destroy-unattached on a session with zero
    clients kills it immediately.
    """
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
    return path.replace("/", "-").replace(" ", "-").replace("~", "-")


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
                content = entry.get("message", {}).get("content", "")
                if isinstance(content, str):
                    first_msg = content
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "text":
                            first_msg = part.get("text", "")
                            break
            if cwd and first_msg:
                break
    return cwd, first_msg


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

    # Keep only sessions whose files still exist on disk
    result = []
    for sid, info in sessions.items():
        encoded = encode_project_path(info["project"])
        if not (PROJECTS_DIR / encoded / f"{sid}.jsonl").exists():
            continue
        result.append({
            "id": sid,
            "project": info["project"],
            "first_msg": info["first_msg"],
            "last_ts": info["last_ts"],
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
    return "~" + path[len(home):] if path.startswith(home) else path


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
                msg = truncate(match["first_msg"])

        lines.append(
            f"TMUX:{tname}\t{status} \x1b[2m{label:>8}\x1b[0m  \x1b[36m{proj}\x1b[0m  {msg}"
        )

    # Historical sessions not currently in tmux
    for s in history[:50]:
        if s["id"] in live_sids:
            continue
        lines.append(
            f"{s['id']}\t  \x1b[33m{relative_time(s['last_ts']):>8}\x1b[0m"
            f"  \x1b[36m{short_path(s['project'])}\x1b[0m  {truncate(s['first_msg'])}"
        )

    return lines


def run_fzf(lines):
    """Show fzf picker, return selected key or None."""
    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--no-sort",
                "--header", " Claude Code Sessions",
                "--delimiter", "\t", "--with-nth", "2..",
                "--height", "~50%", "--reverse",
            ],
            input="\n".join(lines),
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        print("fzf required: brew install fzf")
        sys.exit(1)

    if result.returncode != 0 or not result.stdout.strip():
        return None
    return result.stdout.strip().split("\t")[0]


# --- main ---


def main():
    # Pass-through: args go straight to claude in a new tmux session
    if len(sys.argv) > 1:
        cwd = os.getcwd()
        create_and_enter(make_tmux_name(cwd), cwd, sys.argv[1:])

    history = get_history_sessions()
    live = get_live_sessions()

    # Nothing to pick from — just launch
    if not history and not live:
        cwd = os.getcwd()
        create_and_enter(make_tmux_name(cwd), cwd, [])

    cwd = os.getcwd()
    key = run_fzf(build_picker_lines(live, history, cwd))

    if key is None:
        sys.exit(0)
    elif key == "NEW":
        create_and_enter(make_tmux_name(cwd), cwd, [])
    elif key.startswith("TMUX:"):
        enter_tmux(key[5:])
    else:
        session = next((s for s in history if s["id"] == key), None)
        if not session:
            print(f"Session not found: {key}")
            sys.exit(1)
        name = make_tmux_name(session["project"])
        create_and_enter(name, session["project"], ["-r", key], claude_sid=key)


if __name__ == "__main__":
    main()
