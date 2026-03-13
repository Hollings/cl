#!/usr/bin/env bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$REPO_DIR/cl"

# Ensure the script is executable
chmod +x "$SCRIPT"

# Pick install location
if [ -d "$HOME/.local/bin" ]; then
    INSTALL_DIR="$HOME/.local/bin"
elif [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

ln -sf "$SCRIPT" "$INSTALL_DIR/cl"
echo "Installed: $INSTALL_DIR/cl -> $SCRIPT"

# Check if install dir is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "Add to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

# Check dependencies
missing=""
command -v claude >/dev/null 2>&1 || missing="$missing claude"
command -v tmux   >/dev/null 2>&1 || missing="$missing tmux"
command -v fzf    >/dev/null 2>&1 || missing="$missing fzf"
command -v python3 >/dev/null 2>&1 || missing="$missing python3"

if [ -n "$missing" ]; then
    echo ""
    echo "Missing dependencies:$missing"
    echo ""
    if command -v brew >/dev/null 2>&1; then
        echo "  brew install$missing"
    elif command -v apt >/dev/null 2>&1; then
        echo "  sudo apt install$missing"
    else
        echo "  Install:$missing"
    fi
fi
