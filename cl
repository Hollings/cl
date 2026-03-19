#!/usr/bin/env python3
"""cl - Claude Code session manager

Run without arguments to pick from recent sessions.
Run with arguments to start a new session directly.

On systems with tmux, sessions run inside tmux so you can attach from
SSH. Sessions auto-destroy when all terminals disconnect.
Without tmux, sessions launch directly (still get the picker).
"""

import os
import sys

# Windows console defaults to cp1252 which can't handle unicode symbols
# used in the picker (e.g. ⟳, ●). Force UTF-8 early before any output.
if sys.platform == "win32":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import json
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from shutil import which

IS_WINDOWS = sys.platform == "win32"
CLAUDE_DIR = Path.home() / ".claude"
HISTORY_FILE = CLAUDE_DIR / "history.jsonl"
PROJECTS_DIR = CLAUDE_DIR / "projects"
SETTINGS_FILE = CLAUDE_DIR / "cl-settings.json"

CLAUDE_BIN = "claude"
TMUX_PREFIX = "cl/"
TMUX_AVAILABLE = not IS_WINDOWS and which("tmux") is not None


def _reset_terminal():
    """Reset terminal modes that fzf leaves enabled on Windows.

    fzf enables mouse tracking and focus reporting but doesn't always
    clean up on Windows Terminal.  Without this, the next program
    (Claude Code) inherits the state and [I/[O/mouse sequences leak
    into its input as visible garbage.

    Writes directly via os.write to bypass Python's I/O buffering.
    """
    reset = (
        "\x1b[?1000l"  # disable mouse click tracking
        "\x1b[?1002l"  # disable mouse button tracking
        "\x1b[?1003l"  # disable all mouse motion tracking
        "\x1b[?1006l"  # disable SGR extended mouse mode
        "\x1b[?1004l"  # disable focus reporting
        "\x1b[?25h"    # ensure cursor visible
    )
    try:
        os.write(2, reset.encode())
    except OSError:
        pass

# Setting definitions: key -> (label, description, default)
SETTING_DEFS = {
    "use_tmux": ("tmux wrapping", "Wrap sessions in tmux for SSH attach", True),
    "skip_permissions": ("skip permissions", "--dangerously-skip-permissions flag", True),
}


# --- settings ---


_settings_cache = None


def load_settings():
    """Load settings from disk, falling back to defaults. Cached per process."""
    global _settings_cache
    if _settings_cache is not None:
        return _settings_cache
    defaults = {k: v[2] for k, v in SETTING_DEFS.items()}
    if not SETTINGS_FILE.exists():
        _settings_cache = defaults
        return defaults
    try:
        with open(SETTINGS_FILE) as f:
            saved = json.loads(f.read())
        _settings_cache = {**defaults, **saved}
    except (json.JSONDecodeError, OSError):
        _settings_cache = defaults
    return _settings_cache


def save_settings(settings):
    global _settings_cache
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f, indent=2)
    _settings_cache = None  # invalidate cache


def use_tmux():
    return TMUX_AVAILABLE and load_settings().get("use_tmux", True)


def get_base_flags():
    flags = []
    if load_settings().get("skip_permissions", True):
        flags.append("--dangerously-skip-permissions")
    return flags


# --- launch (no tmux) ---


def launch_claude(project_dir, claude_args):
    """Launch claude directly, replacing this process."""
    os.chdir(project_dir)
    cmd = [CLAUDE_BIN] + get_base_flags() + list(claude_args)
    if IS_WINDOWS:
        _reset_terminal()
        rc = subprocess.call(cmd)
        _reset_terminal()
        sys.exit(rc)
    else:
        os.execvp(CLAUDE_BIN, cmd)


# --- tmux ---


def tmux(*args):
    """Run a tmux command, return CompletedProcess."""
    return subprocess.run(["tmux"] + list(args), capture_output=True, text=True)


def tmux_session_exists(name):
    # Use '=' prefix for exact match — without it, tmux does prefix matching
    # (e.g., "cl/foo" would also match "cl/foobar")
    return tmux("has-session", "-t", f"={name}").returncode == 0


def tmux_env_all(session_name):
    """Read all tmux environment variables for a session as a dict."""
    result = tmux("show-environment", "-t", f"={session_name}")
    if result.returncode != 0:
        return {}
    env = {}
    for line in result.stdout.strip().split("\n"):
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    return env


def get_live_sessions():
    """Return dict of active cl/ tmux sessions: name -> info."""
    if not use_tmux():
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
        env = tmux_env_all(name)
        sessions[name] = {
            "attached": len(parts) > 1 and parts[1] == "1",
            "claude_sid": env.get("CL_SID"),
            "project": env.get("CL_PROJECT", ""),
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
    target = f"={name}"  # exact match — tmux does prefix matching without '='
    cmd = "switch-client" if os.environ.get("TMUX") else "attach-session"
    os.execvp("tmux", ["tmux", cmd, "-t", target])


def create_and_enter_tmux(project_dir, claude_args, claude_sid=None):
    """Create a tmux session running claude, then attach.

    Uses a client-attached hook to enable destroy-unattached, so the
    session dies when all viewers disconnect (no orphans). The hook is
    deferred because setting destroy-unattached on a session with zero
    clients kills it immediately.
    """
    name = make_tmux_name(project_dir)
    cmd_str = " ".join(shlex.quote(a) for a in [CLAUDE_BIN] + get_base_flags() + list(claude_args))
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", name, "-c", project_dir, cmd_str],
        check=True,
    )
    target = f"={name}"
    if claude_sid:
        tmux("set-environment", "-t", target, "CL_SID", claude_sid)
    tmux("set-environment", "-t", target, "CL_PROJECT", project_dir)
    tmux("set-hook", "-t", target, "client-attached", "set destroy-unattached on")
    enter_tmux(name)


# --- session history ---


def encode_project_path(path):
    """Encode a path the way Claude Code names project directories."""
    return path.replace("\\", "/").replace("/", "-").replace(" ", "-").replace("~", "-")


def extract_message_text(entry):
    """Pull plain text from a user or assistant message entry."""
    content = entry.get("message", {}).get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                return part["text"]
    return ""


def parse_session_cwd(path):
    """Extract the cwd from a session JSONL file."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "cwd" in entry:
                return entry["cwd"]
    return None


def get_session_tail(session_file):
    """Read the tail of a session file and return (last_message, is_waiting).

    is_waiting is True if claude has finished its turn and is waiting for
    user input (safe to resume without desync).
    """
    try:
        size = session_file.stat().st_size
    except OSError:
        return "", True
    if size == 0:
        return "", True

    # Read the tail — last 32KB covers the most recent messages.
    # Use binary mode for seek (byte offsets from stat() are unreliable in
    # text mode with multi-byte UTF-8), then decode.
    tail_bytes = min(size, 32 * 1024)
    try:
        with open(session_file, "rb") as f:
            if tail_bytes < size:
                f.seek(size - tail_bytes)
                f.readline()  # skip partial first line
            raw = f.read()
        lines = raw.decode("utf-8", errors="replace").splitlines(True)
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
        t, sub = entry.get("type", ""), entry.get("subtype", "")
        # These mark the end of a completed turn
        if t == "system" and sub in ("stop_hook_summary", "turn_duration"):
            break
        if t == "user":
            break
        if t in ("assistant", "progress"):
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
        with open(HISTORY_FILE, encoding="utf-8", errors="replace") as f:
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
                ts = entry.get("timestamp", 0)
                if sid not in sessions:
                    sessions[sid] = {"project": entry.get("project", ""), "last_ts": ts}
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
                    cwd = parse_session_cwd(session_file)
                    if cwd:
                        sessions[sid] = {
                            "project": cwd,
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
            "last_ts": info["last_ts"],
            "file": session_file,
        })

    result.sort(key=lambda x: x["last_ts"], reverse=True)
    return result


# --- display ---


def relative_time(ts_ms):
    if ts_ms <= 0:
        return "?"
    diff_s = (datetime.now(timezone.utc).timestamp() * 1000 - ts_ms) / 1000
    if diff_s < 60:
        return "now"
    if diff_s < 3600:
        return f"{int(diff_s / 60)}m"
    if diff_s < 86400:
        return f"{int(diff_s / 3600)}h"
    days = diff_s / 86400
    return f"{int(days / 30)}mo" if days >= 30 else f"{int(days)}d"


def short_path(path):
    home = str(Path.home())
    if path.startswith(home):
        return "~" + path[len(home):]
    if IS_WINDOWS:
        norm_path, norm_home = path.replace("/", "\\"), home.replace("/", "\\")
        if norm_path.startswith(norm_home):
            return "~" + norm_path[len(norm_home):]
    return path


def truncate(text, length=50):
    text = text.replace("\n", " ").strip()
    return text[:length - 3] + "..." if len(text) > length else text


def format_session_line(key, state, time_str, proj, msg):
    """Format a single session line for fzf."""
    return (
        f"{key}\t{state} \x1b[33m{time_str:>4}\x1b[0m"
        f"  \x1b[36m{proj}\x1b[0m  {truncate(msg)}"
    )


def separator(label):
    """A dim, non-selectable separator line."""
    return f"SEP\t\x1b[2m  --- {label} ---\x1b[0m"


def _render_live_block(live_dict, history, lines):
    """Render live tmux sessions into lines (shared by local/other sections)."""
    for tname, info in live_dict.items():
        attached = info["attached"]
        status = "\x1b[32m●\x1b[0m" if attached else "\x1b[33m○\x1b[0m"
        label = "attached" if attached else "detached"
        proj = short_path(info["project"]) if info["project"] else tname
        msg = ""
        if info["claude_sid"]:
            match = next((h for h in history if h["id"] == info["claude_sid"]), None)
            if match:
                msg = truncate(get_session_tail(match["file"])[0])
        lines.append(
            f"TMUX:{tname}\t{status} \x1b[2m{label:>8}\x1b[0m  \x1b[36m{proj}\x1b[0m  {msg}"
        )


def _render_history_block(sessions, lines):
    """Render history sessions into lines (shared by local/other sections)."""
    for s in sessions:
        last_msg, is_waiting = get_session_tail(s["file"])
        state = "\x1b[32m●\x1b[0m" if is_waiting else "\x1b[33m⟳\x1b[0m"
        lines.append(format_session_line(
            s["id"], state, relative_time(s["last_ts"]),
            short_path(s["project"]), last_msg,
        ))


def build_picker_lines(live, history, cwd):
    """Build the fzf input lines, grouped by context."""
    live_sids = {v["claude_sid"] for v in live.values() if v["claude_sid"]}
    cwd_short = short_path(cwd)

    def is_local(project):
        return project == cwd or short_path(project) == cwd_short

    # Split history into current dir vs elsewhere, skip live sessions
    local_sessions, other_sessions = [], []
    for s in history[:50]:
        if s["id"] not in live_sids:
            (local_sessions if is_local(s["project"]) else other_sessions).append(s)

    # Split live tmux sessions the same way
    local_live, other_live = {}, {}
    for tname, info in live.items():
        target = local_live if is_local(info.get("project", "")) else other_live
        target[tname] = info

    lines = [f"NEW\t\x1b[32m   +\x1b[0m  {cwd_short}  \x1b[2mnew session\x1b[0m"]

    # --- Sessions in current directory ---
    if local_live or local_sessions:
        lines.append(separator(cwd_short))
    _render_live_block(local_live, history, lines)
    _render_history_block(local_sessions, lines)

    # --- All other sessions ---
    if other_live or other_sessions:
        lines.append(separator("other sessions"))
    _render_live_block(other_live, history, lines)
    _render_history_block(other_sessions, lines)

    return lines


def build_settings_lines():
    """Build fzf lines for the settings panel."""
    settings = load_settings()
    lines = []
    for key, (label, desc, default) in SETTING_DEFS.items():
        val = settings.get(key, default)
        if key == "use_tmux" and not TMUX_AVAILABLE:
            indicator = "\x1b[2m---\x1b[0m"
            note = f"\x1b[2m{label}  (tmux not installed)\x1b[0m"
        else:
            on = val
            indicator = "\x1b[32m ON\x1b[0m" if on else "\x1b[31mOFF\x1b[0m"
            note = f"{label}  \x1b[2m{desc}\x1b[0m"
        lines.append(f"SET:{key}\t  [{indicator}]  {note}")
    return lines


def run_fzf(lines):
    """Show fzf session picker with live reload, return selected key or None."""
    script = shlex.quote(os.path.abspath(sys.argv[0]))
    python = shlex.quote(sys.executable)
    reload_cmd = f"{python} {script} --picker-lines --delay"
    settings_cmd = f"{python} {script} --settings"

    try:
        result = subprocess.run(
            [
                "fzf", "--ansi", "--no-sort",
                "--header", " Sessions  [tab: settings]",
                "--delimiter", "\t", "--with-nth", "2..",
                "--height", "~50%", "--reverse",
                "--bind", f"load:reload-sync({reload_cmd})",
                "--bind", f"tab:become({settings_cmd})",
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

    if IS_WINDOWS:
        _reset_terminal()

    if result.returncode != 0 or not result.stdout.strip():
        return None
    return result.stdout.strip().split("\t")[0]


def run_settings_fzf():
    """Show fzf settings panel. Returns to session picker on Tab."""
    script = shlex.quote(os.path.abspath(sys.argv[0]))
    python = shlex.quote(sys.executable)

    try:
        subprocess.run(
            [
                "fzf", "--ansi", "--no-sort",
                "--header", " Settings  [tab: sessions]  [enter: toggle]",
                "--delimiter", "\t", "--with-nth", "2..",
                "--height", "~50%", "--reverse",
                "--bind", f"tab:become({python} {script})",
                "--bind", f"enter:execute-silent({python} {script} --toggle {{1}})+reload({python} {script} --settings-lines)",
            ],
            input="\n".join(build_settings_lines()),
            text=True,
        )
    except FileNotFoundError:
        pass
    if IS_WINDOWS:
        _reset_terminal()


# --- main ---


def start_session(project_dir, claude_args, claude_sid=None):
    """Start a claude session — in tmux if available, direct otherwise."""
    if use_tmux():
        create_and_enter_tmux(project_dir, claude_args, claude_sid)
    else:
        launch_claude(project_dir, claude_args)


def main():
    args = sys.argv

    # Internal: print picker lines to stdout (used by fzf reload)
    if "--picker-lines" in args:
        if "--delay" in args:
            import time
            time.sleep(2)
        cwd = os.getcwd()
        print("\n".join(build_picker_lines(get_live_sessions(), get_history_sessions(), cwd)))
        return

    # Internal: print settings lines to stdout (used by fzf reload)
    if "--settings-lines" in args:
        print("\n".join(build_settings_lines()))
        return

    # Internal: toggle a setting
    if "--toggle" in args:
        idx = args.index("--toggle")
        if idx + 1 < len(args):
            key = args[idx + 1].removeprefix("SET:")
            if key in SETTING_DEFS and not (key == "use_tmux" and not TMUX_AVAILABLE):
                settings = load_settings()
                settings[key] = not settings.get(key, SETTING_DEFS[key][2])
                save_settings(settings)
        return

    # Settings panel
    if "--settings" in args:
        run_settings_fzf()
        return

    # Self-update via git pull
    if "--update" in args:
        repo_dir = Path(__file__).resolve().parent
        if not (repo_dir / ".git").exists():
            print("Not a git install — update manually.")
            sys.exit(1)
        result = subprocess.run(
            ["git", "-C", str(repo_dir), "pull", "--ff-only"],
        )
        sys.exit(result.returncode)

    # Pass-through: args go straight to claude
    if len(args) > 1:
        start_session(os.getcwd(), args[1:])
        return  # start_session normally never returns (execvp), but guard against it

    history = get_history_sessions()
    live = get_live_sessions()

    # Nothing to pick from — just launch
    if not history and not live:
        start_session(os.getcwd(), [])
        return

    cwd = os.getcwd()
    key = run_fzf(build_picker_lines(live, history, cwd))

    if key is None or key == "SEP":
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
