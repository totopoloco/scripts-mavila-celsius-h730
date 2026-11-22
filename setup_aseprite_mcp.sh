#!/usr/bin/env bash
# Set up aseprite-mcp for Claude Code on Ubuntu.
#
# The Aseprite trial cannot run Lua scripts or save, and aseprite-mcp does
# both on every tool call, so this builds a CLI-only Aseprite from source
# (no UI, Lua on), the same tag as the trial. Compiling Aseprite yourself is
# allowed for personal use (Aseprite EULA, section 2(g)). Keep the trial for
# viewing: it opens the .aseprite files the MCP writes, it just can't save.
#
#   bash setup_aseprite_mcp.sh
#
# Paths can be overridden: ASEPRITE_SRC, ASEPRITE_TAG, MCP_DIR.
set -euo pipefail

ASEPRITE_TAG="${ASEPRITE_TAG:-v1.3.18.6}"
ASEPRITE_SRC="${ASEPRITE_SRC:-$HOME/aseprite-src}"
MCP_DIR="${MCP_DIR:-$HOME/aseprite-mcp}"
ASEPRITE_BIN="$ASEPRITE_SRC/build/bin/aseprite"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# 1. Prerequisites. X11 headers are needed even for the no-UI build: laf's
#    Linux platform layer requires X11, Xcursor, XInput and Xrandr.
missing=()
for tool in git cmake ninja g++; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
for hdr in X11/Xlib.h X11/Xcursor/Xcursor.h X11/extensions/XInput2.h X11/extensions/Xrandr.h; do
  [[ -f /usr/include/$hdr ]] || missing+=("$hdr")
done
if ((${#missing[@]})); then
  echo "Missing: ${missing[*]}"
  echo "Install the build dependencies, then run this again:"
  echo "  sudo apt-get install -y g++ cmake ninja-build libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev libfontconfig1-dev"
  exit 1
fi
if ! command -v uv >/dev/null; then
  echo "uv not found. Install it (https://docs.astral.sh/uv/), then run this again."
  exit 1
fi

# 2. Build Aseprite, CLI only.
if [[ -x $ASEPRITE_BIN ]]; then
  say "Aseprite already built: $ASEPRITE_BIN"
else
  if [[ ! -d $ASEPRITE_SRC/.git ]]; then
    say "Cloning Aseprite $ASEPRITE_TAG"
    git clone --depth 1 --branch "$ASEPRITE_TAG" --recurse-submodules --shallow-submodules \
      https://github.com/aseprite/aseprite.git "$ASEPRITE_SRC"
  fi
  say "Configuring a CLI-only build (flags from upstream CI's 'cli' variant)"
  cmake -S "$ASEPRITE_SRC" -B "$ASEPRITE_SRC/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DLAF_BACKEND=none -DENABLE_SCRIPTING=ON \
    -DENABLE_NEWS=OFF -DENABLE_UPDATER=OFF -DENABLE_WEBSOCKET=OFF -DENABLE_CCACHE=OFF
  say "Building (roughly 10-30 minutes, depending on cores)"
  cmake --build "$ASEPRITE_SRC/build" --target aseprite
fi

# 3. Smoke test: the two things the trial can't do, run a script and save.
say "Smoke test: Lua script + save"
tmp=$(mktemp -d)
printf 'local s = Sprite(8, 8)\ns:saveAs(app.params["out"])\nprint("saved")\n' >"$tmp/smoke.lua"
"$ASEPRITE_BIN" --batch --script-param out="$tmp/smoke.aseprite" --script "$tmp/smoke.lua"
if [[ ! -s $tmp/smoke.aseprite ]]; then
  echo "Smoke test failed: Aseprite did not save the test sprite."
  exit 1
fi
rm -rf "$tmp"
echo "OK: $("$ASEPRITE_BIN" --version)"

# 4. aseprite-mcp (Python 3.13; uv fetches it if needed).
if [[ ! -d $MCP_DIR/.git ]]; then
  say "Cloning aseprite-mcp"
  git clone https://github.com/diivi/aseprite-mcp "$MCP_DIR"
fi
say "Installing aseprite-mcp's environment"
uv --directory "$MCP_DIR" sync
printf 'ASEPRITE_PATH=%s\n' "$ASEPRITE_BIN" >"$MCP_DIR/.env"

# 5. Register with Claude Code at user scope (available in every project).
if command -v claude >/dev/null; then
  if claude mcp get aseprite >/dev/null 2>&1; then
    say "Claude Code already has an 'aseprite' server (remove it with: claude mcp remove aseprite --scope user)"
  else
    say "Registering the server with Claude Code"
    claude mcp add aseprite --scope user --env ASEPRITE_PATH="$ASEPRITE_BIN" \
      -- uv --directory "$MCP_DIR" run -m aseprite_mcp
  fi
else
  echo "Claude Code CLI not found. Register the server later with:"
  echo "  claude mcp add aseprite --scope user --env ASEPRITE_PATH=$ASEPRITE_BIN -- uv --directory $MCP_DIR run -m aseprite_mcp"
fi

say "Done"
cat <<EOF
Draw the badminton rally through the MCP:
  uv run badminton_rally.py mcp --mcp-dir $MCP_DIR --aseprite $ASEPRITE_BIN --out ~/badminton

Then open ~/badminton/badminton_rally.aseprite in the Aseprite trial to play it.
In Claude Code, /mcp should list 'aseprite' as connected.
EOF
