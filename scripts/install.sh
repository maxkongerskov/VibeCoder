#!/usr/bin/env bash
#
# Install the AgentOS / VibeCoder CLI globally.
#
# Usage:
#   ./scripts/install.sh
#
# This will:
#   1. Build a release version of the CLI (fast, small, no debug symbols)
#   2. Install the binary as `agentos` (and `vibecoder` alias) into a location on your PATH
#
# By default it tries (in order):
#   - $HOME/.local/bin
#   - /usr/local/bin
#   - /opt/homebrew/bin (Apple Silicon Homebrew)
#
# You can force a prefix with: PREFIX=/some/dir ./scripts/install.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Building release CLI (optimized, no debug symbols)..."
swift build -c release

BINARY=".build/release/agentos"

if [[ ! -f "$BINARY" ]]; then
    echo "Error: Release binary not found at $BINARY"
    exit 1
fi

# Determine install prefix
if [[ -n "${PREFIX:-}" ]]; then
    INSTALL_DIR="$PREFIX"
else
    for candidate in \
        "$HOME/.local/bin" \
        "$HOME/bin" \
        "/usr/local/bin" \
        "/opt/homebrew/bin"
    do
        parent="$(dirname "$candidate")"
        if mkdir -p "$parent" 2>/dev/null && [[ -w "$parent" ]]; then
            INSTALL_DIR="$candidate"
            break
        fi
    done
fi

if [[ -z "${INSTALL_DIR:-}" ]]; then
    echo "Could not find a writable directory on PATH."
    echo "Please run with PREFIX=~/.local/bin ./scripts/install.sh"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "→ Installing to $INSTALL_DIR/agentos"
install -m 755 "$BINARY" "$INSTALL_DIR/agentos"

# Also install as vibecoder alias
if [[ "$INSTALL_DIR/agentos" != "$INSTALL_DIR/vibecoder" ]]; then
    ln -sf "$INSTALL_DIR/agentos" "$INSTALL_DIR/vibecoder" 2>/dev/null || true
fi

# Add a small wrapper note
echo "✓ Binary installed."

echo ""
echo "✓ Installed successfully!"
echo ""
echo "Make sure $INSTALL_DIR is on your PATH:"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
echo ""
echo "Test it:"
echo "  agentos version"
echo "  agentos models list --backend lmstudio"
echo ""
echo "Typical usage (from inside any project):"
echo "  agentos \"add dark mode toggle to settings\""
echo ""
echo "With planner + worker (big thinker plans, fast worker executes):"
echo "  agentos \"refactor the networking layer\" \\"
echo "    --planner lmstudio/your-reasoning-model \\"
echo "    --worker lmstudio/your-fast-coder \\"
echo "    --project ."
echo ""
echo "Tip: Add the export to your ~/.zshrc or ~/.zprofile"
